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

  defp body do
    %{
      "passengerId" => "P001",
      "pickup" => %{"latitude" => 0, "longitude" => 0},
      "destination" => %{"latitude" => 1, "longitude" => 1}
    }
  end

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
