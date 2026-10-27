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

  test "synthetic invalid Offer identifiers and malformed accepted evidence remain controlled invariants" do
    {server, ride, offer, _} = reserved()
    state = :sys.get_state(server)

    for id <- [123, "", <<255>>] do
      input = %{state | offers: %{id => %{offer | id: id}}}
      input = put_in(input.rides[ride.id].currentOfferId, id)

      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:reject_offer, ride.id, "A"}, nil, input)
    end

    assert {:ok, _} = Store.accept_offer(server, ride.id, "A")
    state = :sys.get_state(server)

    for field <- [:acceptance_result, :accepted_at_ms] do
      input = put_in(state.offers[offer.id], Map.delete(state.offers[offer.id], field))

      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:reject_offer, ride.id, "A"}, nil, input)
    end
  end

  test "synthetic malformed ownership records cannot crash rejection or partially release a Driver" do
    {server, ride, _, _} = reserved()
    state = :sys.get_state(server)

    for input <- [put_in(state.offers["broken"], %{}), put_in(state.rides["broken"], %{})] do
      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:reject_offer, ride.id, "A"}, nil, input)
    end
  end

  @tag timeout: 10_000
  test "an actual Store call timeout does not cancel queued rejection; retry recovers its receipt" do
    {server, ride, offer, _} = reserved()
    :ok = :sys.suspend(server)

    try do
      # Deliberately keep the owner suspended through GenServer.call's actual
      # default timeout. This tests uncertainty, without a sleep-based assertion.
      task =
        Task.async(fn ->
          try do
            Store.reject_offer(server, ride.id, "A")
          catch
            :exit, {:timeout, _} -> :uncertain
          end
        end)

      assert Task.await(task, 6000) == :uncertain
    after
      :sys.resume(server)
    end

    assert {:ok, %{status: :matching} = matching} = Store.get_ride(server, ride.id)
    before = :sys.get_state(server)
    assert Store.reject_offer(server, ride.id, "A") == {:ok, matching}
    assert :sys.get_state(server) == before
    assert before.drivers["A"].status == :available
    assert before.offers[offer.id].rejection_receipt.original_result == matching
    assert before.pending_events["redispatch-" <> offer.id].status == :pending
    assert map_size(before.pending_events) == 3
  end

  test "terminal callbacks retain replacement acceptance evidence for historical rejection replay" do
    {server, ride, offer, _} = reserved()
    assert {:ok, original} = Store.reject_offer(server, ride.id, "A")
    assert {:ok, _} = Store.set_driver_availability(server, "B", true)
    assert {:ok, :processed} = Store.process_event(server, "redispatch-" <> offer.id)
    assert {:ok, accepted} = Store.accept_offer(server, ride.id, "B")
    state = :sys.get_state(server)

    for {operation, status} <- [complete: :completed, cancel: :cancelled] do
      assert {:reply, {:ok, %{status: ^status}}, input} =
               StateServer.handle_call({:terminal_ride, operation, ride.id}, nil, state)

      assert {:reply, {:ok, ^original}, ^input} =
               StateServer.handle_call({:reject_offer, ride.id, "A"}, nil, input)

      assert input.offers[accepted.currentOfferId].acceptance_result == accepted
    end
  end

  test "lost-result and concurrent retries return the immutable matching receipt exactly once" do
    {server, ride, offer, clock} = reserved()
    :atomics.put(clock, 1, 7)
    # Completed call, discarded response: retry must consult authoritative evidence.
    assert Task.await(
             Task.async(fn ->
               Store.reject_offer(server, ride.id, "A")
               :lost
             end)
           ) == :lost

    state = :sys.get_state(server)
    result = state.offers[offer.id].rejection_receipt.original_result
    :atomics.put(clock, 1, 100_000)

    assert competing(List.duplicate(fn -> Store.reject_offer(server, ride.id, "A") end, 8)) ==
             List.duplicate({:ok, result}, 8)

    assert :sys.get_state(server) == state
    assert Enum.count(Store.list_events(server), &(&1.eventId == "redispatch-" <> offer.id)) == 1
  end

  test "old rejection replay never changes replacement acceptance or released Driver reuse" do
    {server, ride, offer, _} = reserved()
    assert {:ok, original} = Store.reject_offer(server, ride.id, "A")
    assert {:ok, _} = Store.set_driver_availability(server, "B", true)
    assert {:ok, :processed} = Store.process_event(server, "redispatch-" <> offer.id)
    assert {:ok, %{assignedDriverId: "B"}} = Store.accept_offer(server, ride.id, "B")
    {:ok, other} = Store.create_ride(server, "other", body())
    created = Enum.find(Store.list_events(server), &(&1.rideId == other.id))
    assert {:ok, :processed} = Store.process_event(server, created.eventId)
    assert {:ok, :processed} = Store.process_event(server, "dispatch-" <> other.id)
    assert {:ok, %{assignedDriverId: "A"}} = Store.accept_offer(server, other.id, "A")
    state = :sys.get_state(server)
    assert Store.reject_offer(server, ride.id, "A") == {:ok, original}
    assert :sys.get_state(server) == state
    assert state.drivers["A"].status == :busy
    assert state.drivers["B"].status == :busy
  end

  test "synthetic receipt and linked-event corruption cannot authorize replay" do
    {server, ride, offer, _} = reserved()
    assert {:ok, original} = Store.reject_offer(server, ride.id, "A")
    state = :sys.get_state(server)
    event_id = "redispatch-" <> offer.id
    rejected = state.offers[offer.id]
    receipt = rejected.rejection_receipt

    broken_receipts = [
      nil,
      %{},
      %{receipt | offerId: "wrong"},
      %{receipt | rideId: "wrong"},
      %{receipt | driverId: "wrong"},
      %{receipt | rejected_at_ms: -1},
      %{receipt | redispatch_event_id: "wrong"},
      %{receipt | original_result: %{original | status: :driver_assigned}},
      %{receipt | original_result: Map.delete(original, :currentOfferId)},
      %{receipt | original_result: %{original | pickup: %{latitude: 1, longitude: 1}}}
    ]

    variants =
      Enum.map(broken_receipts, &put_in(state.offers[offer.id].rejection_receipt, &1)) ++
        [
          put_in(state.offers[offer.id].id, "wrong"),
          put_in(state.offers[offer.id].status, :pending),
          put_in(state.offers[offer.id], Map.put(rejected, :accepted_at_ms, 0)),
          put_in(state.offers[offer.id], Map.delete(rejected, :rejection_receipt)),
          %{state | pending_events: Map.delete(state.pending_events, event_id)},
          put_in(state.pending_events[event_id].eventId, "wrong"),
          put_in(state.pending_events[event_id].rideId, "wrong"),
          put_in(state.pending_events[event_id].type, :ride_created),
          put_in(state.pending_events[event_id].status, :unknown)
        ]

    for input <- variants do
      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:reject_offer, ride.id, "A"}, nil, input)
    end

    for status <- [:pending, :processed, :failed] do
      input = put_in(state.pending_events[event_id].status, status)
      input = %{input | clock: fn -> raise "replay must not read time" end}

      assert {:reply, {:ok, ^original}, ^input} =
               StateServer.handle_call({:reject_offer, ride.id, "A"}, nil, input)
    end
  end

  test "live terminal replay preserves rejection evidence; ambiguous same-pair history still fails" do
    for status <- [:cancelled, :completed] do
      {server, ride, offer, _} = reserved()
      assert {:ok, original} = Store.reject_offer(server, ride.id, "A")

      if status == :completed do
        assert {:ok, _} = Store.set_driver_availability(server, "B", true)
        assert {:ok, :processed} = Store.process_event(server, "redispatch-" <> offer.id)
        assert {:ok, _} = Store.accept_offer(server, ride.id, "B")
        assert {:ok, _} = Store.complete_ride(server, ride.id)
      else
        assert {:ok, _} = Store.cancel_ride(server, ride.id)
      end

      before = :sys.get_state(server)
      assert Store.reject_offer(server, ride.id, "A") == {:ok, original}
      assert :sys.get_state(server) == before
      input = put_in(before.offers["another"], %{before.offers[offer.id] | id: "another"})

      assert {:reply, {:error, :ambiguous_offer}, ^input} =
               StateServer.handle_call({:reject_offer, ride.id, "A"}, nil, input)
    end
  end

  test "stale Accept after replacement acceptance is a conflict, not invariant corruption" do
    {server, ride, offer, _} = reserved()
    assert {:ok, _} = Store.reject_offer(server, ride.id, "A")
    assert {:ok, _} = Store.set_driver_availability(server, "B", true)
    assert {:ok, :processed} = Store.process_event(server, "redispatch-" <> offer.id)
    assert {:ok, accepted} = Store.accept_offer(server, ride.id, "B")
    before = :sys.get_state(server)
    assert Store.accept_offer(server, ride.id, "A") == {:error, :invalid_transition}
    assert :sys.get_state(server) == before
    assert before.drivers["B"].status == :busy
    assert before.offers[accepted.currentOfferId].acceptance_result == accepted
    # Still distinguish real broken evidence on the old Offer from a stale request.
    broken = put_in(before.offers[offer.id], Map.put(before.offers[offer.id], :accepted_at_ms, 0))

    assert {:reply, {:error, :inconsistent_ownership}, ^broken} =
             StateServer.handle_call({:accept_offer, ride.id, "A"}, nil, broken)
  end

  test "first-time competing Rejects perform exactly one transition and event insertion" do
    {server, ride, offer, _} = reserved()
    before = :sys.get_state(server)
    results = competing(List.duplicate(fn -> Store.reject_offer(server, ride.id, "A") end, 10))
    assert [{:ok, result}] = Enum.uniq(results)
    after_reject = :sys.get_state(server)
    assert after_reject.rides[ride.id] == result
    assert after_reject.drivers["A"].status == :available
    assert after_reject.offers[offer.id].status == :rejected
    assert map_size(after_reject.offers) == 1

    assert Map.keys(after_reject.pending_events) -- Map.keys(before.pending_events) == [
             "redispatch-" <> offer.id
           ]

    assert after_reject.offers[offer.id].rejection_receipt.original_result == result
  end

  test "ordered Accept/Reject outcomes and barrier-released competing callers preserve all records" do
    for order <- [:accept_first, :reject_first, :competing] do
      for _ <- 1..8 do
        {server, ride, offer, _} = reserved()
        before = :sys.get_state(server)
        accept = fn -> Store.accept_offer(server, ride.id, "A") end
        reject = fn -> Store.reject_offer(server, ride.id, "A") end

        results =
          case order do
            :accept_first ->
              [accept.(), reject.()]

            :reject_first ->
              rejected = reject.()
              [accept.(), rejected]

            :competing ->
              competing([accept, reject])
          end

        after_race = :sys.get_state(server)

        case results do
          [{:ok, accepted}, {:error, :invalid_transition}] ->
            assert after_race.rides[ride.id] == accepted
            assert accepted.status == :driver_accepted
            assert after_race.drivers["A"].status == :busy
            assert after_race.offers[offer.id].status == :accepted
            assert after_race.offers[offer.id].acceptance_result == accepted
            refute Map.has_key?(after_race.offers[offer.id], :rejection_receipt)
            assert after_race.pending_events == before.pending_events

          [{:error, :invalid_transition}, {:ok, matching}] ->
            assert after_race.rides[ride.id] == matching
            assert matching.status == :matching
            assert matching.assignedDriverId == nil and matching.currentOfferId == nil
            assert after_race.drivers["A"].status == :available
            assert after_race.offers[offer.id].status == :rejected
            refute Map.has_key?(after_race.offers[offer.id], :acceptance_result)
            assert after_race.pending_events["redispatch-" <> offer.id].status == :pending
            assert map_size(after_race.pending_events) == map_size(before.pending_events) + 1
        end

        assert map_size(after_race.offers) == 1
        assert after_race.idempotency == before.idempotency
      end
    end
  end

  defp competing(functions) do
    parent = self()

    tasks =
      Enum.map(functions, fn fun ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> fun.()
          end
        end)
      end)

    for _ <- tasks do
      assert_receive {:ready, _}, 1000
    end

    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await/1)
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
