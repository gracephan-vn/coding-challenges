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

  defp body do
    %{
      "passengerId" => "P001",
      "pickup" => %{"latitude" => 0, "longitude" => 0},
      "destination" => %{"latitude" => 1, "longitude" => 1}
    }
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
