defmodule RideDispatch.Dispatch.TerminalLifecycleTest do
  use ExUnit.Case, async: true
  import RideDispatch.OfferFixtures
  alias RideDispatch.Dispatch.Store

  test "terminal commands validate identities and reject non-completable states unchanged" do
    {server, _} = owner()
    {:ok, ride} = Store.create_ride(server, "new", body())
    before = :sys.get_state(server)

    for command <- [&Store.cancel_ride/2, &Store.complete_ride/2] do
      for id <- [nil, 0, "", <<255>>],
          do: assert(command.(server, id) == {:error, :invalid_request})

      assert command.(server, "missing") == :not_found
    end

    assert Store.complete_ride(server, ride.id) == {:error, :invalid_transition}
    assert :sys.get_state(server) == before
  end

  test "REQUESTED cancellation retains pending events and replays its exact original result" do
    {server, _} = owner()
    {:ok, ride} = Store.create_ride(server, "new", body())
    before = :sys.get_state(server)
    assert {:ok, result} = Store.cancel_ride(server, ride.id)
    state = :sys.get_state(server)

    assert result ==
             Map.merge(ride, %{status: :cancelled, assignedDriverId: nil, currentOfferId: nil})

    assert state.rides[ride.id] ==
             Map.put(result, :terminal_receipt, %{
               operation: :cancel,
               rideId: ride.id,
               source_status: :requested,
               offerId: nil,
               driverId: nil,
               original_result: result
             })

    assert state.drivers == before.drivers and state.offers == before.offers

    assert state.pending_events == before.pending_events and
             state.idempotency == before.idempotency

    assert Store.cancel_ride(server, ride.id) == {:ok, result}
    assert Store.complete_ride(server, ride.id) == {:error, :invalid_transition}
    assert :sys.get_state(server) == state
    assert Store.create_ride(server, "new", body()) == {:ok, ride}
  end

  test "MATCHING cancellation preserves closed rejection history and does not release unrelated drivers" do
    {server, ride, offer, _} = reserved()
    assert {:ok, _} = Store.reject_offer(server, ride.id, "A")
    before = :sys.get_state(server)
    assert {:ok, result} = Store.cancel_ride(server, ride.id)
    after_cancel = :sys.get_state(server)

    assert result.status == :cancelled and result.assignedDriverId == nil and
             result.currentOfferId == nil

    assert after_cancel.offers[offer.id] == before.offers[offer.id]
    assert after_cancel.drivers == before.drivers
    assert after_cancel.pending_events == before.pending_events
  end
end
