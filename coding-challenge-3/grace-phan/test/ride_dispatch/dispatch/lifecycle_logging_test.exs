defmodule RideDispatch.Dispatch.LifecycleLoggingTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import RideDispatch.OfferFixtures
  alias RideDispatch.Dispatch.Store

  @metadata [
    :rideId,
    :driverId,
    :eventId,
    :offerId,
    :outcome,
    :operation,
    :attempts,
    :causedByEventId
  ]

  defp logs(fun) do
    capture_log([level: :info, format: "$message $metadata\n", metadata: @metadata], fun)
  end

  test "committed lifecycle logs correlate history and separate replays from rejection" do
    {server, _} = owner()
    {:ok, _} = Store.set_driver_availability(server, "B", true)
    parent = self()

    output =
      logs(fn ->
        {ride, dispatch} = matching(server, "logs")
        assert {:ok, :processed} = Store.process_event(server, dispatch)
        [first] = Store.list_offers(server)
        assert {:ok, _} = Store.reject_offer(server, ride.id, "A")
        redispatch = "redispatch-" <> first.id
        assert {:ok, :processed} = Store.process_event(server, redispatch)
        assert {:ok, accepted} = Store.accept_offer(server, ride.id, "B")
        assert {:error, :invalid_transition} = Store.accept_offer(server, ride.id, "A")
        assert {:ok, completed} = Store.complete_ride(server, ride.id)
        before = :sys.get_state(server)
        assert Store.complete_ride(server, ride.id) == {:ok, completed}
        assert Store.accept_offer(server, ride.id, "B") == {:ok, accepted}
        assert :sys.get_state(server) == before
        send(parent, {:history, ride, dispatch, redispatch, first, before})
      end)

    assert_receive {:history, ride, dispatch, redispatch, first, final}
    second = final.offers[final.rides[ride.id].terminal_receipt.offerId]
    assert final.drivers["B"].status == :available
    assert second.status == :completed
    assert first.id != second.id

    for name <- [
          "ride.created",
          "event.enqueued",
          "ride.matching_started",
          "dispatch.requested",
          "dispatch.processed",
          "offer.reserved",
          "offer.rejected",
          "offer.accepted",
          "ride.completed"
        ] do
      assert output =~ name
    end

    lines = String.split(output, "\n", trim: true)
    assert Enum.all?(lines, &String.contains?(&1, "rideId=#{ride.id}"))
    assert Enum.count(lines, &String.starts_with?(&1, "offer.reserved ")) == 2
    assert Enum.count(lines, &String.starts_with?(&1, "offer.accepted ")) == 1
    assert Enum.count(lines, &String.starts_with?(&1, "ride.completed ")) == 1
    assert Enum.count(lines, &String.starts_with?(&1, "operation.replayed ")) == 2
    assert Enum.any?(lines, &(&1 =~ "operation.rejected" and &1 =~ "driverId=A"))

    assert Enum.any?(
             lines,
             &(&1 =~ "offer.reserved" and &1 =~ "eventId=#{dispatch}" and
                 &1 =~ "offerId=#{first.id}" and &1 =~ "driverId=A")
           )

    assert Enum.any?(
             lines,
             &(&1 =~ "offer.reserved" and &1 =~ "eventId=#{redispatch}" and
                 &1 =~ "offerId=#{second.id}" and &1 =~ "driverId=B")
           )

    assert Enum.any?(lines, &(&1 =~ "offer.rejected" and &1 =~ "eventId=#{redispatch}"))
  end

  test "expiration, cancellation and failed acceptance never invent successful transitions" do
    {server, ride, offer, clock} = reserved()

    output =
      logs(fn ->
        :atomics.put(clock, 1, offer.expires_at_ms)
        assert {:error, :offer_expired} = Store.accept_offer(server, ride.id, "A")
        assert {:ok, :expired} = Store.expire_offer(server, offer.id)
        assert {:ok, :already_expired} = Store.expire_offer(server, offer.id)
        assert {:ok, _} = Store.cancel_ride(server, ride.id)
        Store.get_ride(server, ride.id)
      end)

    assert output =~ "offer.expired"
    assert output =~ "eventId=redispatch-expired-#{offer.id}"
    assert output =~ "ride.cancelled"
    assert output =~ "operation.replayed"
    assert output =~ "operation.rejected"
    refute output =~ "offer.accepted"
    assert length(Regex.scan(~r/^offer.expired /m, output)) == 1
  end
end
