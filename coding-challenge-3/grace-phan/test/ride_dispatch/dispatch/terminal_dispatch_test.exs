defmodule RideDispatch.Dispatch.TerminalDispatchTest do
  use ExUnit.Case, async: true
  import RideDispatch.OfferFixtures
  alias RideDispatch.Dispatch.{EventDispatcher, ExpirationScheduler, StateServer, Store}

  for phase <- [:created, :dispatch, :retry] do
    test "real dispatcher safely consumes #{phase} work after cancellation" do
      {server, clock} = owner()
      listen(server)
      {:ok, ride} = Store.create_ride(server, "pending", body())
      [created] = Store.list_events(server)
      phase = unquote(phase)

      id =
        if phase?(phase, :created) do
          created.eventId
        else
          assert Store.process_event(server, created.eventId) == {:ok, :processed}
          "dispatch-" <> ride.id
        end

      if phase?(phase, :retry),
        do:
          assert(
            Store.fail_event(server, id, 0, :processing_failed) == {:error, {:retry_at, 1000}}
          )

      parent = self()

      worker =
        start_supervised!(
          {EventDispatcher,
           store: server,
           scan_interval_ms: 60_000,
           process: fn owner, event_id ->
             send(parent, {:blocked, self(), event_id})

             receive do
               :go -> Store.process_event(owner, event_id)
             end
           end}
        )

      if phase?(phase, :retry) do
        assert_receive {{:ride_dispatch, :dispatcher, :idle}, %{dispatcher: ^worker}}, 1000
        :atomics.put(clock, 1, 1000)
        EventDispatcher.wake(worker)
      end

      assert_receive {:blocked, ^worker, ^id}, 1000
      {:ok, result} = Store.cancel_ride(server, ride.id)
      before = :sys.get_state(server)
      send(worker, :go)

      assert_receive {{:ride_dispatch, :event, :processed},
                      %{event_id: ^id, result: {:ok, :ignored}}},
                     1000

      after_process = :sys.get_state(server)
      assert after_process.rides == before.rides and after_process.drivers == before.drivers

      assert after_process.offers == %{} and
               map_size(after_process.pending_events) == map_size(before.pending_events)

      expected_attempts = if phase?(phase, :retry), do: 2, else: 1

      assert {:ok,
              %{
                status: :processed,
                outcome: :incompatible_ride_state,
                attempts: ^expected_attempts,
                next_attempt_at: nil
              }} = Store.get_event(server, id)

      assert Store.process_event(server, id) == {:ok, :already_processed}
      assert Store.cancel_ride(server, ride.id) == {:ok, result}
      assert :sys.get_state(server) == after_process
    end
  end

  test "synthetic terminal status without proof fails permanently instead of hiding corruption" do
    {server, _} = owner()
    {:ok, ride} = Store.create_ride(server, "bad", body())
    [event] = Store.list_events(server)
    state = put_in(:sys.get_state(server).rides[ride.id].status, :cancelled)

    assert {:reply, {:error, {:permanent, :inconsistent_ownership}}, final} =
             StateServer.handle_call({:process_event, event.eventId}, nil, state)

    assert final.rides == state.rides and final.drivers == state.drivers and
             final.offers == state.offers

    assert final.pending_events[event.eventId].status == :failed
  end

  test "scheduler retains valid closure but diagnoses malformed terminal evidence" do
    {server, ride, offer, clock} = reserved()
    listen(server)
    worker = start_supervised!({ExpirationScheduler, store: server, scan_interval_ms: 60_000})
    assert_receive {{:ride_dispatch, :expiration, :idle}, %{scheduler: ^worker}}, 1000
    old_tick = :sys.get_state(worker).tick
    assert {:ok, _} = Store.cancel_ride(server, ride.id)
    {other, event} = matching(server, "reuse")
    assert Store.process_event(server, event) == {:ok, :processed}
    assert {:ok, _} = Store.accept_offer(server, other.id, "A")
    :atomics.put(clock, 1, offer.expires_at_ms)
    before = :sys.get_state(server)
    send(worker, {:scan, old_tick})
    ExpirationScheduler.wake(worker)
    assert_receive {{:ride_dispatch, :expiration, :idle}, %{scheduler: ^worker}}, 1000
    assert :sys.get_state(server) == before
    assert {:ok, %{pending: [], invalid_offers: []}} = Store.expiration_schedule(server)
    input = update_in(before.rides[ride.id], &Map.delete(&1, :terminal_receipt))

    assert {:reply, {:ok, %{invalid_offers: [%{offer_id: id, reason: :invalid_evidence}]}},
            ^input} =
             StateServer.handle_call(:expiration_schedule, nil, input)

    assert id == offer.id

    assert {:reply, {:error, :inconsistent_ownership}, ^input} =
             StateServer.handle_call({:expire_offer, offer.id}, nil, input)
  end

  defp phase?(actual, expected), do: actual == expected
end
