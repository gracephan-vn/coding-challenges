defmodule RideDispatch.Dispatch.RejectionTest do
  use ExUnit.Case, async: true
  alias RideDispatch.Dispatch.{StateServer, Store}

  test "rejection atomically releases ownership, retains a receipt and enqueues one redispatch" do
    {server, ride, offer, clock} = reserved()
    before = :sys.get_state(server)
    :atomics.put(clock, 1, 123)
    assert {:ok, matching} = Store.reject_offer(server, ride.id, "A")

    assert matching == %{
             before.rides[ride.id]
             | status: :matching,
               assignedDriverId: nil,
               currentOfferId: nil
           }

    after_reject = :sys.get_state(server)
    assert after_reject.rides[ride.id] == matching
    assert after_reject.drivers["A"] == %{before.drivers["A"] | status: :available}
    event_id = "redispatch-" <> offer.id

    receipt = %{
      offerId: offer.id,
      rideId: ride.id,
      driverId: "A",
      rejected_at_ms: 123,
      redispatch_event_id: event_id,
      original_result: matching
    }

    assert after_reject.offers == %{
             offer.id => Map.merge(offer, %{status: :rejected, rejection_receipt: receipt})
           }

    assert after_reject.pending_events ==
             Map.put(before.pending_events, event_id, %{
               eventId: event_id,
               rideId: ride.id,
               type: :dispatch_requested,
               status: :pending
             })

    assert after_reject.idempotency == before.idempotency
    assert after_reject.passengers == before.passengers
    assert Store.create_ride(server, "original", body()) == {:ok, ride}
  end

  test "invalid identifiers, unknown resources and wrong holder never mutate state" do
    {server, ride, _, _} = reserved()
    before = :sys.get_state(server)

    for invalid <- [nil, 0, [], "", <<255>>] do
      assert Store.reject_offer(server, invalid, "A") == {:error, :invalid_request}
      assert Store.reject_offer(server, ride.id, invalid) == {:error, :invalid_request}
    end

    assert Store.reject_offer(server, "missing", "A") == :not_found
    assert Store.reject_offer(server, ride.id, "missing") == :not_found
    assert Store.reject_offer(server, ride.id, "B") == {:error, :wrong_driver}
    assert :sys.get_state(server) == before
  end

  test "synthetic contradictory ownership, evidence and event collisions are rejected atomically" do
    {server, ride, offer, _} = reserved()
    state = :sys.get_state(server)

    variants = [
      put_in(state.rides[ride.id].id, "wrong"),
      put_in(state.drivers["A"].id, "wrong"),
      put_in(state.rides[ride.id].currentOfferId, nil),
      put_in(state.rides[ride.id].currentOfferId, "missing"),
      put_in(state.offers[offer.id].id, "wrong"),
      put_in(state.offers[offer.id].rideId, "wrong"),
      put_in(state.offers[offer.id].driverId, "B"),
      put_in(state.offers[offer.id].status, :rejected),
      put_in(state.offers[offer.id].expires_at_ms, nil),
      put_in(state.drivers["A"].status, :busy),
      put_in(state.offers[offer.id], Map.put(offer, :accepted_at_ms, 0)),
      put_in(state.offers[offer.id], Map.put(offer, :acceptance_result, %{})),
      put_in(state.offers[offer.id], Map.put(offer, :rejection_receipt, %{})),
      put_in(state.pending_events["redispatch-" <> offer.id], %{eventId: "collision"}),
      put_in(state.offers["other"], %{offer | id: "other", driverId: "B", status: :accepted}),
      put_in(state.rides["other"], %{state.rides[ride.id] | id: "other"})
    ]

    for input <- variants do
      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:reject_offer, ride.id, "A"}, nil, input)
    end
  end

  test "late rejection explicitly releases a still pending reservation; invalid time cannot" do
    for offset <- [0, 1] do
      {server, ride, offer, clock} = reserved()
      :atomics.put(clock, 1, offer.expires_at_ms + offset)
      assert {:ok, %{status: :matching}} = Store.reject_offer(server, ride.id, "A")
      assert {:ok, %{status: :available}} = Store.get_driver(server, "A")
    end

    {server, ride, _, _} = reserved()
    state = :sys.get_state(server)

    for clock <- [fn -> nil end, fn -> raise "clock" end, fn -> -1 end] do
      input = %{state | clock: clock}

      assert {:reply, {:error, :invalid_clock}, ^input} =
               StateServer.handle_call({:reject_offer, ride.id, "A"}, nil, input)
    end
  end

  test "accepted Offers conflict rather than release BUSY ownership" do
    {server, ride, _, _} = reserved()
    assert {:ok, _} = Store.accept_offer(server, ride.id, "A")
    state = :sys.get_state(server)
    assert Store.reject_offer(server, ride.id, "A") == {:error, :invalid_transition}
    assert :sys.get_state(server) == state
  end

  defp reserved do
    clock = :atomics.new(1, [])

    server =
      start_supervised!(
        Supervisor.child_spec(
          {StateServer,
           passengers: [%{id: "P"}],
           drivers: [
             %{id: "A", status: :available, latitude: 0, longitude: 0, label: "keep"},
             %{id: "B", status: :offline, latitude: 0, longitude: 0}
           ],
           clock: fn -> :atomics.get(clock, 1) end},
          id: make_ref()
        )
      )

    {:ok, ride} = Store.create_ride(server, "original", body())
    created = Enum.find(Store.list_events(server), &(&1.rideId == ride.id))
    {:ok, :processed} = Store.process_event(server, created.eventId)
    {:ok, :processed} = Store.process_event(server, "dispatch-" <> ride.id)
    [offer] = Store.list_offers(server)
    {server, ride, offer, clock}
  end

  defp body do
    %{
      "passengerId" => "P",
      "pickup" => %{"latitude" => 0, "longitude" => 0},
      "destination" => %{"latitude" => 1, "longitude" => 1}
    }
  end
end
