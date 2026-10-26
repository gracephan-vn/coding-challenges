defmodule RideDispatch.Dispatch.AcceptanceTest do
  use ExUnit.Case, async: true

  alias RideDispatch.Dispatch.{StateServer, Store}

  test "acceptance atomically changes the exact reserved Ride, Driver and Offer" do
    {server, ride, offer, _clock} = reserved()
    before = :sys.get_state(server)
    assert {:ok, accepted} = Store.accept_offer(server, ride.id, "D001")
    assert accepted == %{before.rides[ride.id] | status: :driver_accepted}
    assert Store.get_ride(server, ride.id) == {:ok, accepted}
    assert {:ok, %{status: :busy, label: "keep"}} = Store.get_driver(server, "D001")
    assert {:ok, completed} = Store.get_offer(server, offer.id)

    assert completed ==
             Map.merge(offer, %{status: :accepted, accepted_at_ms: 0, acceptance_result: accepted})

    after_acceptance = :sys.get_state(server)
    assert after_acceptance.pending_events == before.pending_events
    assert after_acceptance.idempotency == before.idempotency
    assert Map.keys(after_acceptance.offers) == [offer.id]
    assert Store.create_ride(server, "ride", body()) == {:ok, ride}
  end

  test "invalid identifiers, unknown resources and wrong Driver leave all state unchanged" do
    {server, ride, _offer, _clock} = reserved()
    before = :sys.get_state(server)

    for invalid <- [nil, 0, [], <<255>>, ""] do
      assert Store.accept_offer(server, invalid, "D001") == {:error, :invalid_request}
      assert Store.accept_offer(server, ride.id, invalid) == {:error, :invalid_request}
    end

    assert Store.accept_offer(server, "missing", "D001") == :not_found
    assert Store.accept_offer(server, ride.id, "missing") == :not_found
    assert Store.accept_offer(server, ride.id, "D002") == {:error, :wrong_driver}
    assert :sys.get_state(server) == before
    {unassigned, _} = matching(server, "no-offer")
    before = :sys.get_state(server)
    assert Store.accept_offer(server, unassigned.id, "D001") == :not_found
    assert :sys.get_state(server) == before
  end

  test "synthetic ownership contradictions fail without installing any partial transition" do
    {server, ride, offer, _} = reserved()
    state = :sys.get_state(server)
    duplicate_ride = %{state.rides[ride.id] | id: "other"}
    duplicate_offer = %{offer | id: "other", rideId: "other"}

    variants = [
      put_in(state.rides[ride.id].id, "wrong"),
      put_in(state.drivers["D001"].id, "wrong"),
      put_in(state.rides[ride.id].assignedDriverId, "D002"),
      put_in(state.rides[ride.id].currentOfferId, nil),
      put_in(state.rides[ride.id].currentOfferId, "missing"),
      put_in(state.offers[offer.id].id, "wrong"),
      put_in(state.offers[offer.id].rideId, "wrong"),
      put_in(state.offers[offer.id].driverId, "D002"),
      put_in(state.offers[offer.id], %{}),
      put_in(state.drivers["D001"].status, :available),
      %{state | rides: Map.put(state.rides, "other", duplicate_ride)},
      %{state | offers: Map.put(state.offers, "other", %{duplicate_offer | status: :accepted})}
    ]

    for input <- variants do
      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
    end
  end

  defp body do
    %{
      "passengerId" => "P001",
      "pickup" => %{"latitude" => 0, "longitude" => 0},
      "destination" => %{"latitude" => 1, "longitude" => 1}
    }
  end

  test "first acceptance before the deadline succeeds and equality/later keeps reservation held" do
    {server, ride, offer, clock} = reserved()
    :atomics.put(clock, 1, offer.expires_at_ms - 1)
    assert {:ok, _} = Store.accept_offer(server, ride.id, "D001")
    assert {:ok, %{accepted_at_ms: accepted_at}} = Store.get_offer(server, offer.id)
    assert accepted_at == offer.expires_at_ms - 1

    for offset <- [0, 1] do
      {server, ride, offer, clock} = reserved()
      :atomics.put(clock, 1, offer.expires_at_ms + offset)
      before = :sys.get_state(server)
      assert Store.accept_offer(server, ride.id, "D001") == {:error, :offer_expired}
      assert :sys.get_state(server) == before
      assert {:ok, %{status: :offered}} = Store.get_driver(server, "D001")
      assert Store.get_offer(server, offer.id) == {:ok, offer}
    end
  end

  test "synthetic malformed deadlines and invalid processing clocks cannot partially accept" do
    {server, ride, offer, _} = reserved()
    state = :sys.get_state(server)

    for broken <- [
          Map.delete(offer, :expires_at_ms),
          %{offer | expires_at_ms: nil},
          %{offer | expires_at_ms: "30000"},
          %{offer | created_at_ms: 1.5},
          %{offer | created_at_ms: offer.expires_at_ms}
        ] do
      input = put_in(state.offers[offer.id], broken)

      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
    end

    for clock <- [fn -> nil end, fn -> 1.0 end, fn -> raise "clock" end, fn -> -1 end] do
      input = %{state | clock: clock}

      assert {:reply, {:error, :invalid_clock}, ^input} =
               StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
    end
  end

  defp owner(clock) do
    start_supervised!(
      Supervisor.child_spec(
        {StateServer,
         passengers: [%{id: "P001"}],
         drivers: [
           %{id: "D001", status: :available, latitude: 0, longitude: 0, label: "keep"},
           %{id: "D002", status: :offline, latitude: 0, longitude: 0}
         ],
         clock: clock},
        id: make_ref()
      )
    )
  end

  defp matching(server, key) do
    {:ok, ride} = Store.create_ride(server, key, body())

    event =
      Enum.find(Store.list_events(server), &(&1.rideId == ride.id and &1.type == :ride_created))

    assert Store.process_event(server, event.eventId) == {:ok, :processed}
    {ride, "dispatch-" <> ride.id}
  end

  defp reserved do
    clock = :atomics.new(1, [])
    server = owner(fn -> :atomics.get(clock, 1) end)
    {ride, id} = matching(server, "ride")
    assert Store.process_event(server, id) == {:ok, :processed}
    [offer] = Store.list_offers(server)
    {server, ride, offer, clock}
  end
end
