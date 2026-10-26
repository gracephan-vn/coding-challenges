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
