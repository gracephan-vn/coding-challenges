defmodule RideDispatch.Dispatch.LifecycleLoggingTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  import RideDispatch.OfferFixtures
  alias RideDispatch.Dispatch.Store

  setup do
    previous = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: previous) end)
    :ok
  end

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
        assert {:ok, %{status: :matching}} = Store.reject_offer(server, ride.id, "A")
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
    assert Enum.count(lines, &String.starts_with?(&1, "operation.replayed ")) == 3
    assert Enum.any?(lines, &(&1 =~ "operation.rejected" and &1 =~ "driverId=A"))

    assert Enum.any?(
             lines,
             &(&1 =~ "operation.replayed" and &1 =~ "operation=reject_offer" and
                 &1 =~ "offerId=#{first.id}")
           )

    assert Enum.any?(
             lines,
             &(&1 =~ "operation.replayed" and &1 =~ "operation=accept_offer" and
                 &1 =~ "offerId=#{second.id}")
           )

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

  test "real dispatcher correlation distinguishes retry, timeout reconciliation and no candidate" do
    {server, clock} = owner(drivers: [])
    listen(server)

    output =
      logs(fn ->
        {:ok, ride} = Store.create_ride(server, "async-log", body())
        [event] = Store.list_events(server)
        calls = :atomics.new(1, [])

        process = fn owner, id ->
          case :atomics.add_get(calls, 1, 1) do
            1 ->
              {:error, :retryable}

            2 ->
              assert {:ok, :processed} = Store.process_event(owner, id)
              exit({:timeout, :lost_reply})

            _ ->
              Store.process_event(owner, id)
          end
        end

        worker =
          start_supervised!(
            {RideDispatch.Dispatch.EventDispatcher,
             store: server, process: process, scan_interval_ms: 60_000}
          )

        event_id = event.eventId

        assert_receive {{:ride_dispatch, :event, :processed},
                        %{event_id: ^event_id, result: {:error, {:retry_at, 1000}}}},
                       1000

        assert Store.list_offers(server) == []
        :atomics.put(clock, 1, 1000)
        RideDispatch.Dispatch.EventDispatcher.wake(worker)

        assert_receive {{:ride_dispatch, :event, :processed},
                        %{event_id: ^event_id, result: {:ok, :already_processed}}},
                       1000

        dispatch_id = "dispatch-" <> ride.id

        assert_receive {{:ride_dispatch, :event, :processed},
                        %{event_id: ^dispatch_id, result: {:ok, :processed}}},
                       1000

        assert {:ok, %{outcome: :no_candidate, attempts: 1}} =
                 Store.get_event(server, dispatch_id)

        assert {:ok, %{attempts: 2}} = Store.get_event(server, event_id)
        assert {:ok, %{status: :matching}} = Store.get_ride(server, ride.id)
        assert Store.list_offers(server) == []
        send(self(), {:ids, ride.id, event_id, dispatch_id})
      end)

    assert_receive {:ids, ride_id, event_id, dispatch_id}
    assert output =~ "event.retry_scheduled"
    assert output =~ "event.timeout_reconciled"
    assert output =~ "dispatch.no_candidate"
    assert output =~ "rideId=#{ride_id}"
    assert output =~ "eventId=#{event_id}"
    assert output =~ "eventId=#{dispatch_id}"
    assert output =~ "attempts=1"
    refute output =~ "offer.reserved"
    assert length(Regex.scan(~r/^ride.matching_started /m, output)) == 1
  end

  test "competing creation replay has identity but never repeats committed creation" do
    {server, _} = owner()

    output =
      logs(fn ->
        [{:ok, ride}, {:ok, same}] =
          competing([
            fn -> Store.create_ride(server, "same", body()) end,
            fn -> Store.create_ride(server, "same", body()) end
          ])

        assert ride == same
        assert length(Store.list_events(server)) == 1
        send(self(), {:ride_id, ride.id})
      end)

    assert_receive {:ride_id, id}

    replay =
      Enum.find(String.split(output, "\n"), &String.starts_with?(&1, "operation.replayed "))

    assert replay =~ "rideId=#{id}"
    assert replay =~ "eventId="
    assert length(Regex.scan(~r/^ride.created /m, output)) == 1
    assert length(Regex.scan(~r/^event.enqueued /m, output)) == 1
  end

  test "scheduler retry carries Offer identity and is distinct from committed expiration" do
    {server, ride, offer, clock} = reserved()
    listen(server)
    :atomics.put(clock, 1, offer.expires_at_ms)
    calls = :atomics.new(1, [])

    output =
      logs(fn ->
        worker =
          start_supervised!(
            {RideDispatch.Dispatch.ExpirationScheduler,
             store: server,
             scan_interval_ms: 60_000,
             expire: fn owner, id ->
               if :atomics.add_get(calls, 1, 1) == 1,
                 do: {:error, :retryable},
                 else: Store.expire_offer(owner, id)
             end}
          )

        assert_receive {{:ride_dispatch, :expiration, :result}, %{result: {:error, :retryable}}},
                       1000

        assert_receive {{:ride_dispatch, :expiration, :idle}, %{scheduler: ^worker}}, 1000
        assert {:ok, %{status: :pending}} = Store.get_offer(server, offer.id)
        :atomics.put(clock, 1, offer.expires_at_ms + 1000)
        RideDispatch.Dispatch.ExpirationScheduler.wake(worker)
        assert_receive {{:ride_dispatch, :expiration, :result}, %{result: {:ok, :expired}}}, 1000
        assert {:ok, %{status: :expired}} = Store.get_offer(server, offer.id)
      end)

    retry =
      Enum.find(
        String.split(output, "\n"),
        &String.starts_with?(&1, "expiration.retry_scheduled ")
      )

    assert retry
    assert retry =~ "rideId=#{ride.id}"
    assert retry =~ "driverId=A"
    assert retry =~ "offerId=#{offer.id}"
    assert retry =~ "attempts=1"
    assert length(Regex.scan(~r/^offer.expired /m, output)) == 1
  end

  test "logging a rejected synthetic corrupt Ride never crashes the authoritative owner" do
    {server, ride, _, _} = reserved()
    snapshot = put_in(:sys.get_state(server).rides[ride.id], nil)
    fixture = start_supervised!({RideDispatch.OfferFixtures.CallbackOwner, snapshot})

    output =
      logs(fn ->
        assert {:error, :inconsistent_ownership} = Store.accept_offer(fixture, ride.id, "A")
        assert :sys.get_state(fixture) == snapshot
      end)

    assert output =~ "operation.failed"
    refute output =~ "offer.accepted"
  end

  test "invalid trusted time is a technical failure, never a business conflict or success" do
    {server, ride, _, clock} = reserved()
    :atomics.put(clock, 1, -999_999)
    before = :sys.get_state(server)

    output =
      logs(fn ->
        assert {:error, :invalid_clock} = Store.accept_offer(server, ride.id, "A")
        assert :sys.get_state(server) == before
      end)

    assert output =~ "operation.failed"
    assert output =~ "outcome=invalid_clock"
    refute output =~ "operation.rejected"
    refute output =~ "offer.accepted"
  end

  test "global clock diagnostic does not fabricate an Offer identity" do
    {server, _, _, clock} = reserved()
    listen(server)
    :atomics.put(clock, 1, -999_999)

    output =
      logs(fn ->
        worker =
          start_supervised!(
            {RideDispatch.Dispatch.ExpirationScheduler, store: server, scan_interval_ms: 60_000}
          )

        assert_receive {{:ride_dispatch, :expiration, :idle}, %{scheduler: ^worker}}, 1000
      end)

    assert output =~ "category=invalid_clock"
    refute output =~ "offerId="
  end
end
