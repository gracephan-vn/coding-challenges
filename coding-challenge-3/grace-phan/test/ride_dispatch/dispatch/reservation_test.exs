defmodule RideDispatch.Dispatch.ReservationTest do
  use ExUnit.Case, async: true

  alias RideDispatch.Dispatch.{StateServer, Store}

  test "Offer queries are read-only and isolated" do
    server = owner()
    assert Store.list_offers(server) == []
    assert Store.get_offer(server, "missing") == :not_found
    assert Store.list_offers(owner()) == []
  end

  test "matching policy defaults and explicit values are validated at startup" do
    assert {:ok, state} = StateServer.init([])
    assert state.matching_radius_km == 2.0
    assert state.offer_timeout_ms == 30_000

    assert {:ok, custom} = StateServer.init(matching_radius_km: 0, offer_timeout_ms: 1)
    assert custom.matching_radius_km == 0
    assert custom.offer_timeout_ms == 1

    for radius <- [-1, "2", nil, :infinity] do
      assert StateServer.init(matching_radius_km: radius) == {:stop, :invalid_matching_radius}
    end

    for timeout <- [0, -1, 1.5, "30000", nil] do
      assert StateServer.init(offer_timeout_ms: timeout) == {:stop, :invalid_offer_timeout}
    end
  end

  test "startup rejects invalid clocks and accepts negative monotonic milliseconds" do
    for clock <- [nil, fn _ -> 0 end, fn -> 0.0 end, fn -> nil end, fn -> raise "clock" end] do
      assert StateServer.init(clock: clock) == {:stop, :invalid_clock}
    end

    assert {:ok, _state} = StateServer.init(clock: fn -> -1_000_000 end)
  end

  test "one Store command reserves and acknowledges against current authoritative state" do
    driver = driver("D001", 0.001)
    server = owner(drivers: [driver])
    {ride, event} = matching(server, "reserve")
    original = :sys.get_state(server).idempotency

    assert Store.process_event(server, event.eventId) == {:ok, :processed}
    assert {:ok, assigned} = Store.get_ride(server, ride.id)
    assert assigned.status == :driver_assigned
    assert assigned.assignedDriverId == driver.id
    assert {:ok, reserved} = Store.get_driver(server, driver.id)
    assert reserved == %{driver | status: :offered}
    assert [offer] = Store.list_offers(server)
    assert assigned.currentOfferId == offer.id

    assert offer == %{
             id: offer.id,
             rideId: ride.id,
             driverId: driver.id,
             status: :pending,
             created_at_ms: 0,
             expires_at_ms: 30_000
           }

    refute offer.id in [ride.id, driver.id, event.eventId]
    assert Store.get_offer(server, offer.id) == {:ok, offer}

    assert {:ok, %{status: :processed, outcome: :offer_created}} =
             Store.get_event(server, event.eventId)

    assert :sys.get_state(server).idempotency == original
    assert Store.create_ride(server, "reserve", body()) == {:ok, ride}
    assert Store.list_offers(owner()) == []
  end

  test "matching reads the latest stored location" do
    server = owner(drivers: [driver("D001", 0.001), driver("D002", 0.01)])
    {ride, event} = matching(server, "latest")
    assert {:ok, _} = Store.update_driver_location(server, "D001", %{latitude: 0, longitude: 1})
    assert Store.process_event(server, event.eventId) == {:ok, :processed}
    assert {:ok, %{assignedDriverId: "D002"}} = Store.get_ride(server, ride.id)
    assert {:ok, %{status: :available, longitude: 1}} = Store.get_driver(server, "D001")
  end

  test "availability updates completed before reservation determine eligibility" do
    server = owner(drivers: [driver("D001", 0.001), driver("D002", 0.01, :offline)])
    {ride, event} = matching(server, "availability")
    assert {:ok, _} = Store.set_driver_availability(server, "D001", false)
    assert {:ok, _} = Store.set_driver_availability(server, "D002", true)
    assert Store.process_event(server, event.eventId) == {:ok, :processed}
    assert {:ok, %{assignedDriverId: "D002"}} = Store.get_ride(server, ride.id)
    assert {:ok, %{status: :offline}} = Store.get_driver(server, "D001")
  end

  test "no candidate is processed once without a retry or new work" do
    for drivers <- [[], [driver("outside", 0.018)], [driver("offline", 0, :offline)]] do
      server = owner(drivers: drivers)
      {ride, event} = matching(server, "none")
      assert Store.process_event(server, event.eventId) == {:ok, :processed}
      assert {:ok, current} = Store.get_ride(server, ride.id)
      assert current.status == :matching
      assert current.assignedDriverId == nil
      assert Map.get(current, :currentOfferId) == nil
      assert Store.list_offers(server) == []

      assert {:ok,
              %{status: :processed, outcome: :no_candidate, attempts: 1, next_attempt_at: nil} =
                done} =
               Store.get_event(server, event.eventId)

      refute Map.has_key?(done, :last_error)
      assert Store.list_actionable_events(server) == []
      assert Store.next_event_delay(server) == nil
      assert length(Store.list_events(server)) == 2
    end
  end

  test "synthetic callback history excludes rejected/expired Drivers only for that Ride" do
    server = owner(drivers: [driver("D001", 0.001), driver("D002", 0.002), driver("D003", 0.003)])
    {ride, event} = matching(server, "history")
    {other, other_event} = matching(server, "other")
    state = :sys.get_state(server)

    history = %{
      "rejected" => %{id: "rejected", rideId: ride.id, driverId: "D001", status: :rejected},
      "expired" => %{id: "expired", rideId: ride.id, driverId: "D002", status: :expired}
    }

    fixture = %{state | offers: history}

    assert {:reply, {:ok, :processed}, updated} =
             StateServer.handle_call({:process_event, event.eventId}, nil, fixture)

    assert updated.rides[ride.id].assignedDriverId == "D003"
    assert Map.take(updated.offers, Map.keys(history)) == history

    assert {:reply, {:ok, :processed}, final} =
             StateServer.handle_call({:process_event, other_event.eventId}, nil, updated)

    assert final.rides[other.id].assignedDriverId == "D001"

    exhausted = %{fixture | drivers: Map.take(fixture.drivers, ["D001", "D002"])}

    assert {:reply, {:ok, :processed}, none} =
             StateServer.handle_call({:process_event, event.eventId}, nil, exhausted)

    assert none.rides[ride.id].status == :matching
    assert none.offers == history
    assert none.pending_events[event.eventId].outcome == :no_candidate
  end

  test "configured inclusive radius and lexicographic ties reuse Matcher semantics" do
    for drivers <- [
          [driver("D2", 0.01), driver("D10", 0.01)],
          [driver("D10", 0.01), driver("D2", 0.01)]
        ] do
      radius = RideDispatch.Location.distance_km(%{latitude: 0, longitude: 0}, hd(drivers))

      server =
        owner(drivers: [driver("outside", 0.010000001) | drivers], matching_radius_km: radius)

      {ride, event} = matching(server, "boundary")
      assert Store.process_event(server, event.eventId) == {:ok, :processed}
      assert {:ok, %{assignedDriverId: "D10"}} = Store.get_ride(server, ride.id)
    end

    server = owner(drivers: [driver("D001", 0.025)], matching_radius_km: 3.0)
    {ride, event} = matching(server, "custom")
    assert Store.process_event(server, event.eventId) == {:ok, :processed}
    assert {:ok, %{assignedDriverId: "D001"}} = Store.get_ride(server, ride.id)
  end

  defp body do
    %{
      "passengerId" => "P001",
      "pickup" => %{"latitude" => 0, "longitude" => 0},
      "destination" => %{"latitude" => 1, "longitude" => 1}
    }
  end

  test "synthetic callback rejects invalid events and Rides without partial business mutation" do
    {ride, event, state} = fixture()

    variants = [
      {%{state | rides: %{}}, :ride_not_found},
      {put_in(state.rides[ride.id].status, :unknown), :invalid_state},
      {put_in(state.rides[ride.id].status, :requested), :invalid_state},
      {put_in(state.rides[ride.id].pickup, %{latitude: 91, longitude: 0}), :invalid_pickup},
      {put_in(state.rides[ride.id], Map.delete(state.rides[ride.id], :pickup)), :invalid_pickup},
      {put_in(state.pending_events[event.eventId], Map.delete(event, :rideId)), :invalid_event}
    ]

    for {input, reason} <- variants do
      assert {:reply, {:error, {:permanent, ^reason}}, final} =
               StateServer.handle_call({:process_event, event.eventId}, nil, input)

      assert business(final) == business(input)
      assert final.pending_events[event.eventId].status == :failed
      assert final.pending_events[event.eventId].last_error == reason
    end
  end

  test "synthetic terminal Ride events are ignored without resurrection" do
    {ride, event, state} = fixture()

    for status <- [:cancelled, :completed] do
      input = put_in(state.rides[ride.id].status, status)

      assert {:reply, {:ok, :ignored}, final} =
               StateServer.handle_call({:process_event, event.eventId}, nil, input)

      assert business(final) == business(input)
      assert final.pending_events[event.eventId].status == :processed
    end
  end

  test "synthetic contradictory ownership fails closed even when Driver is AVAILABLE" do
    {ride, event, state} = fixture()
    pending = %{id: "existing", rideId: "other", driverId: "D001", status: :pending}

    other =
      Map.merge(state.rides[ride.id], %{
        id: "other",
        status: :driver_assigned,
        assignedDriverId: "D001",
        currentOfferId: "existing"
      })

    variants = [
      put_in(state.rides[ride.id].assignedDriverId, "D001"),
      put_in(state.rides[ride.id], Map.put(state.rides[ride.id], :currentOfferId, "dangling")),
      %{state | offers: %{"existing" => %{pending | rideId: ride.id}}},
      %{state | offers: %{"existing" => pending}},
      %{state | offers: %{"existing" => %{pending | status: :accepted}}},
      %{state | rides: Map.put(state.rides, "other", other)},
      %{state | rides: Map.put(state.rides, "other", %{other | status: :driver_accepted})}
    ]

    for input <- variants do
      assert {:reply, {:error, {:permanent, :inconsistent_ownership}}, final} =
               StateServer.handle_call({:process_event, event.eventId}, nil, input)

      assert business(final) == business(input)
      assert final.pending_events[event.eventId].status == :failed
    end
  end

  test "replaying the acknowledged reservation leaves every authoritative record unchanged" do
    server = owner(drivers: [driver("D001", 0)])
    {_ride, event} = matching(server, "duplicate")
    assert Store.process_event(server, event.eventId) == {:ok, :processed}
    before = :sys.get_state(server)
    assert Store.process_event(server, event.eventId) == {:ok, :already_processed}
    assert :sys.get_state(server) == before
  end

  defp fixture do
    server = owner(drivers: [driver("D001", 0)])
    {ride, event} = matching(server, "fixture")
    {ride, event, :sys.get_state(server)}
  end

  defp business(state), do: Map.take(state, [:rides, :drivers, :offers, :idempotency])

  defp driver(id, longitude, status \\ :available) do
    %{id: id, status: status, latitude: 0.0, longitude: longitude, label: "preserve"}
  end

  defp matching(server, key) do
    {:ok, ride} = Store.create_ride(server, key, body())

    event =
      Enum.find(Store.list_events(server), &(&1.rideId == ride.id and &1.type == :ride_created))

    assert Store.process_event(server, event.eventId) == {:ok, :processed}

    dispatch =
      Enum.find(
        Store.list_events(server),
        &(&1.rideId == ride.id and &1.type == :dispatch_requested)
      )

    {ride, dispatch}
  end

  defp owner(opts \\ []) do
    opts = Keyword.merge([passengers: [%{id: "P001"}], clock: fn -> 0 end], opts)
    start_supervised!(Supervisor.child_spec({StateServer, opts}, id: make_ref()))
  end
end
