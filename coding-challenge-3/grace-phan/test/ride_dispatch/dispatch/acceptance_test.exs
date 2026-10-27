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

  test "invalid identifiers, unknown resources and wrong Driver leave all state unchanged" do
    {server, ride, _offer, _clock} = reserved()
    before = :sys.get_state(server)

    for invalid <- [nil, 0, [], <<255>>, ""] do
      assert Store.accept_offer(server, invalid, "D001") == {:error, :invalid_request}
      assert Store.accept_offer(server, ride.id, invalid) == {:error, :invalid_request}
    end

    assert Store.accept_offer(server, "missing", "D001") == :not_found
    assert Store.accept_offer(server, ride.id, "missing") == :not_found
    assert Store.accept_offer(server, ride.id, "D002") == {:error, :wrong_driver}
    assert :sys.get_state(server) == before
    {unassigned, _} = matching(server, "no-offer")
    before = :sys.get_state(server)
    assert Store.accept_offer(server, unassigned.id, "D001") == :not_found
    assert :sys.get_state(server) == before
  end

  test "synthetic pending Offer with rejection evidence cannot accept or mutate any state" do
    {server, ride, offer, _clock} = reserved()
    {_unrelated_ride, _event} = matching(server, "unrelated")
    state = :sys.get_state(server)

    # Obtain real rejection evidence, but attach it only to synthetic snapshots
    # of the still-pending reservation. No public workflow produces this state.
    assert {:reply, {:ok, _matching}, rejected} =
             StateServer.handle_call({:reject_offer, ride.id, "D001"}, nil, state)

    for evidence <- [rejected.offers[offer.id].rejection_receipt, %{invalid: true}, nil] do
      input = put_in(state.offers[offer.id], Map.put(offer, :rejection_receipt, evidence))

      assert input.rides[ride.id].status == :driver_assigned
      assert input.drivers["D001"].status == :offered
      assert input.offers[offer.id].status == :pending

      assert {:reply, result, after_attempt} =
               StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)

      assert result == {:error, :inconsistent_ownership}
      # Exact snapshot equality covers every Ride, Driver, Offer, Event,
      # idempotency record and receipt, including unrelated records.
      assert after_attempt === input
    end
  end

  test "synthetic ownership contradictions fail without installing any partial transition" do
    {server, ride, offer, _} = reserved()
    state = :sys.get_state(server)
    duplicate_ride = %{state.rides[ride.id] | id: "other"}
    duplicate_offer = %{offer | id: "other", rideId: "other"}

    variants = [
      put_in(state.rides[ride.id].id, "wrong"),
      put_in(state.drivers["D001"].id, "wrong"),
      put_in(state.rides[ride.id].assignedDriverId, "D002"),
      put_in(state.rides[ride.id].currentOfferId, nil),
      put_in(state.rides[ride.id].currentOfferId, "missing"),
      put_in(state.offers[offer.id].id, "wrong"),
      put_in(state.offers[offer.id].rideId, "wrong"),
      put_in(state.offers[offer.id].driverId, "D002"),
      put_in(state.offers[offer.id].status, :rejected),
      put_in(state.offers[offer.id], %{}),
      put_in(state.drivers["D001"].status, :available),
      %{state | rides: Map.put(state.rides, "other", duplicate_ride)},
      %{state | offers: Map.put(state.offers, "other", %{duplicate_offer | status: :accepted})}
    ]

    for input <- variants do
      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
    end
  end

  defp body do
    %{
      "passengerId" => "P001",
      "pickup" => %{"latitude" => 0, "longitude" => 0},
      "destination" => %{"latitude" => 1, "longitude" => 1}
    }
  end

  test "first acceptance before the deadline succeeds and equality/later keeps reservation held" do
    {server, ride, offer, clock} = reserved()
    :atomics.put(clock, 1, offer.expires_at_ms - 1)
    assert {:ok, _} = Store.accept_offer(server, ride.id, "D001")
    assert {:ok, %{accepted_at_ms: accepted_at}} = Store.get_offer(server, offer.id)
    assert accepted_at == offer.expires_at_ms - 1

    for offset <- [0, 1] do
      {server, ride, offer, clock} = reserved()
      :atomics.put(clock, 1, offer.expires_at_ms + offset)
      before = :sys.get_state(server)
      assert Store.accept_offer(server, ride.id, "D001") == {:error, :offer_expired}
      assert :sys.get_state(server) == before
      assert {:ok, %{status: :offered}} = Store.get_driver(server, "D001")
      assert Store.get_offer(server, offer.id) == {:ok, offer}
    end
  end

  test "synthetic malformed deadlines and invalid processing clocks cannot partially accept" do
    {server, ride, offer, _} = reserved()
    state = :sys.get_state(server)

    for broken <- [
          Map.delete(offer, :expires_at_ms),
          %{offer | expires_at_ms: nil},
          %{offer | expires_at_ms: "30000"},
          %{offer | created_at_ms: 1.5},
          %{offer | created_at_ms: offer.expires_at_ms}
        ] do
      input = put_in(state.offers[offer.id], broken)

      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
    end

    for clock <- [fn -> nil end, fn -> 1.0 end, fn -> raise "clock" end, fn -> -1 end] do
      input = %{state | clock: clock}

      assert {:reply, {:error, :invalid_clock}, ^input} =
               StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
    end
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

  test "immediate replay and a discarded-result retry preserve the original acceptance evidence" do
    {server, ride, offer, clock} = reserved()
    :atomics.put(clock, 1, 123)
    # The caller discards the result as if its response were lost.
    task =
      Task.async(fn ->
        Store.accept_offer(server, ride.id, "D001")
        :response_lost
      end)

    assert Task.await(task) == :response_lost
    before = :sys.get_state(server)
    accepted = before.offers[offer.id].acceptance_result
    assert before.offers[offer.id].accepted_at_ms == 123
    assert Store.accept_offer(server, ride.id, "D001") == {:ok, accepted}
    :atomics.put(clock, 1, offer.expires_at_ms + 10_000)
    assert Store.accept_offer(server, ride.id, "D001") == {:ok, accepted}
    assert :sys.get_state(server) == before
    # Proven replay does not read a new-attempt clock at all.
    fixture = %{before | clock: fn -> raise "must not read on replay" end}

    assert {:reply, {:ok, ^accepted}, ^fixture} =
             StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, fixture)
  end

  test "synthetic accepted statuses without valid receipt identity are not replay evidence" do
    {server, ride, offer, _} = reserved()
    assert {:ok, accepted} = Store.accept_offer(server, ride.id, "D001")
    state = :sys.get_state(server)
    receipt = state.offers[offer.id]

    variants = [
      Map.delete(receipt, :acceptance_result),
      Map.delete(receipt, :accepted_at_ms),
      %{receipt | accepted_at_ms: -1},
      %{receipt | accepted_at_ms: offer.expires_at_ms},
      %{receipt | acceptance_result: %{accepted | id: "other"}},
      %{receipt | acceptance_result: %{accepted | currentOfferId: "other"}},
      %{receipt | acceptance_result: %{accepted | assignedDriverId: "D002"}},
      %{receipt | acceptance_result: %{accepted | status: :driver_assigned}},
      %{receipt | acceptance_result: Map.delete(accepted, :pickup)},
      %{receipt | acceptance_result: %{accepted | passengerId: "other"}}
    ]

    for broken <- variants do
      input = put_in(state.offers[offer.id], broken)

      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
    end

    input = put_in(state.drivers["D001"].status, :available)

    assert {:reply, {:error, :inconsistent_ownership}, ^input} =
             StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
  end

  defp matching(server, key) do
    {:ok, ride} = Store.create_ride(server, key, body())

    event =
      Enum.find(Store.list_events(server), &(&1.rideId == ride.id and &1.type == :ride_created))

    assert Store.process_event(server, event.eventId) == {:ok, :processed}
    {ride, "dispatch-" <> ride.id}
  end

  test "barrier-released identical acceptance calls return one immutable result" do
    {server, ride, offer, clock} = reserved()
    :atomics.put(clock, 1, 99)
    before = :sys.get_state(server)
    results = compete(for _ <- 1..10, do: fn -> Store.accept_offer(server, ride.id, "D001") end)
    assert [{:ok, accepted}] = Enum.uniq(results)
    assert {:ok, %{status: :busy}} = Store.get_driver(server, "D001")
    assert Store.get_ride(server, ride.id) == {:ok, accepted}
    assert [receipt] = Store.list_offers(server)
    assert receipt.id == offer.id and receipt.status == :accepted
    assert receipt.accepted_at_ms == 99 and receipt.acceptance_result == accepted
    assert accepted.currentOfferId == offer.id and accepted.assignedDriverId == "D001"
    assert accepted.status == :driver_accepted
    after_acceptance = :sys.get_state(server)
    assert after_acceptance.pending_events == before.pending_events
    assert after_acceptance.idempotency == before.idempotency
    assert after_acceptance.drivers["D002"] == before.drivers["D002"]
    assert Store.accept_offer(server, ride.id, "D001") == {:ok, accepted}
    assert :sys.get_state(server) == after_acceptance
  end

  defp compete(functions) do
    parent = self()

    tasks =
      for function <- functions do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> function.()
          end
        end)
      end

    for task <- tasks, do: assert_receive({:ready, pid} when pid == task.pid)
    for task <- tasks, do: send(task.pid, :go)
    Enum.map(tasks, &Task.await/1)
  end

  test "synthetic same-pair history is ambiguous before acceptance and after prior success" do
    {server, ride, offer, _} = reserved()

    for phase <- [:before, :after] do
      if phase == :after, do: assert({:ok, _} = Store.accept_offer(server, ride.id, "D001"))
      state = :sys.get_state(server)
      older = %{offer | id: "older", status: :expired}
      input = %{state | offers: Map.put(state.offers, older.id, older)}

      assert {:reply, {:error, :ambiguous_offer}, ^input} =
               StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
    end
  end

  test "synthetic history for another Driver does not make the current Offer ambiguous" do
    {server, ride, offer, _} = reserved()
    state = :sys.get_state(server)
    older = %{offer | id: "older", driverId: "D002", status: :rejected}
    input = %{state | offers: Map.put(state.offers, older.id, older)}

    assert {:reply, {:ok, accepted}, final} =
             StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)

    assert accepted.currentOfferId == offer.id
    assert final.offers[older.id] == older
  end

  test "synthetic rejected expired and superseded attempts never become current acceptance" do
    {server, ride, offer, _} = reserved()
    state = :sys.get_state(server)

    for status <- [:rejected, :expired, :cancelled] do
      next_status = if status == :cancelled, do: :cancelled, else: :matching

      input =
        state
        |> put_in([:offers, offer.id, :status], status)
        |> put_in([:rides, ride.id, :status], next_status)
        |> put_in([:rides, ride.id, :currentOfferId], nil)
        |> put_in([:rides, ride.id, :assignedDriverId], nil)
        |> put_in([:drivers, "D001", :status], :available)

      assert {:reply, {:error, :invalid_transition}, ^input} =
               StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
    end

    replacement = %{offer | id: "replacement", driverId: "D002"}

    input =
      state
      |> put_in([:offers, offer.id, :status], :rejected)
      |> put_in([:offers, replacement.id], replacement)
      |> put_in([:rides, ride.id, :currentOfferId], replacement.id)
      |> put_in([:rides, ride.id, :assignedDriverId], "D002")
      |> put_in([:drivers, "D001", :status], :available)
      |> put_in([:drivers, "D002", :status], :offered)

    assert {:reply, {:error, :invalid_transition}, ^input} =
             StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
  end

  test "synthetic pending Offer with acceptance evidence is rejected instead of overwritten" do
    {server, ride, offer, _} = reserved()
    state = :sys.get_state(server)

    for field <- [:accepted_at_ms, :acceptance_result] do
      input = put_in(state.offers[offer.id], Map.put(offer, field, nil))

      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
    end
  end

  defp reserved do
    clock = :atomics.new(1, [])
    server = owner(fn -> :atomics.get(clock, 1) end)
    {ride, id} = matching(server, "ride")
    assert Store.process_event(server, id) == {:ok, :processed}
    [offer] = Store.list_offers(server)
    {server, ride, offer, clock}
  end

  test "terminal callback results preserve replay with proven closure and cleared identity" do
    {server, ride, offer, _} = reserved()
    assert {:ok, accepted} = Store.accept_offer(server, ride.id, "D001")
    state = :sys.get_state(server)

    for status <- [:completed, :cancelled] do
      input = terminal_fixture(state, ride.id, status)
      input = %{input | clock: fn -> raise "replay must not check current time" end}

      assert {:reply, {:ok, ^accepted}, ^input} =
               StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)

      broken = update_in(input.offers[offer.id], &Map.delete(&1, :accepted_at_ms))

      assert {:reply, {:error, :inconsistent_ownership}, ^broken} =
               StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, broken)
    end
  end

  test "terminal callback replay does not interfere with Driver accepted ownership on another Ride" do
    {server, ride, _offer, _} = reserved()
    assert {:ok, accepted} = Store.accept_offer(server, ride.id, "D001")

    input =
      terminal_fixture(:sys.get_state(server), ride.id, :completed)

    # Callback-level compatibility; live reuse is covered in TerminalLifecycleTest.
    assert {:reply, {:ok, other}, input} =
             StateServer.handle_call({:create_ride, "other", body()}, nil, input)

    created =
      Enum.find(
        Map.values(input.pending_events),
        &(&1.rideId == other.id and &1.type == :ride_created)
      )

    assert {:reply, {:ok, :processed}, input} =
             StateServer.handle_call({:process_event, created.eventId}, nil, input)

    assert {:reply, {:ok, :processed}, input} =
             StateServer.handle_call({:process_event, "dispatch-" <> other.id}, nil, input)

    assert {:reply, {:ok, other_accepted}, input} =
             StateServer.handle_call({:accept_offer, other.id, "D001"}, nil, input)

    assert input.drivers["D001"].status == :busy

    assert {:reply, {:ok, ^accepted}, ^input} =
             StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)

    assert input.rides[other.id] == other_accepted
  end

  defp terminal_fixture(state, ride_id, status) do
    operation = Map.fetch!(%{completed: :complete, cancelled: :cancel}, status)

    assert {:reply, {:ok, _result}, terminal} =
             StateServer.handle_call({:terminal_ride, operation, ride_id}, nil, state)

    terminal
  end

  test "AC-09 live competing Rides retain exclusive ownership after acceptance" do
    for _ <- 1..10 do
      clock = :atomics.new(1, [])
      server = owner(fn -> :atomics.get(clock, 1) end)
      pairs = [matching(server, "A"), matching(server, "B")]

      assert compete(for {_, id} <- pairs, do: fn -> Store.process_event(server, id) end) ==
               [{:ok, :processed}, {:ok, :processed}]

      assert [pending] = Store.list_offers(server)
      assert pending.status == :pending and pending.driverId == "D001"
      {loser, loser_event} = Enum.find(pairs, fn {ride, _} -> ride.id != pending.rideId end)
      assert {:ok, accepted} = Store.accept_offer(server, pending.rideId, "D001")
      before_replay = :sys.get_state(server)
      assert Store.accept_offer(server, pending.rideId, "D001") == {:ok, accepted}
      assert :sys.get_state(server) == before_replay
      assert {:ok, %{status: :busy}} = Store.get_driver(server, "D001")
      assert Store.get_ride(server, pending.rideId) == {:ok, accepted}
      assert {:ok, waiting} = Store.get_ride(server, loser.id)
      assert waiting.status == :matching and waiting.assignedDriverId == nil
      assert Map.get(waiting, :currentOfferId) == nil

      for {ride, event} <- pairs do
        assert {:ok, %{status: :processed, outcome: outcome}} = Store.get_event(server, event)
        assert outcome == if(ride.id == pending.rideId, do: :offer_created, else: :no_candidate)
      end

      {new_ride, new_event} = matching(server, "busy")
      assert Store.process_event(server, new_event) == {:ok, :processed}

      assert {:ok, %{status: :matching, assignedDriverId: nil}} =
               Store.get_ride(server, new_ride.id)

      assert [receipt] = Store.list_offers(server)
      assert receipt.id == pending.id and receipt.status == :accepted
      assert receipt.acceptance_result == accepted

      assert {:ok, %{outcome: :no_candidate, status: :processed}} =
               Store.get_event(server, new_event)

      # Replaying an acknowledged event is NOT another matching attempt.
      assert Store.process_event(server, loser_event) == {:ok, :already_processed}
      state = :sys.get_state(server)
      assert map_size(state.rides) == 3 and map_size(state.pending_events) == 6
      # Synthetic new event: public redispatch is deliberately not implemented.
      event = %{
        eventId: "later-attempt",
        rideId: loser.id,
        type: :dispatch_requested,
        status: :pending
      }

      input = put_in(state.pending_events[event.eventId], event)

      assert {:reply, {:ok, :processed}, final} =
               StateServer.handle_call({:process_event, event.eventId}, nil, input)

      assert Map.take(final, [:rides, :drivers, :offers, :idempotency]) ==
               Map.take(input, [:rides, :drivers, :offers, :idempotency])

      assert final.pending_events[event.eventId].outcome == :no_candidate
    end
  end

  test "synthetic malformed receipt status and Ride state return controlled invariant failures" do
    {server, ride, offer, _} = reserved()
    pending_state = :sys.get_state(server)

    for input <- [
          update_in(pending_state.rides[ride.id], &Map.delete(&1, :status)),
          update_in(pending_state.drivers["D001"], &Map.delete(&1, :status))
        ] do
      {_, result, final} = StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
      assert result == {:error, :inconsistent_ownership}
      assert final == input
    end

    assert {:ok, _} = Store.accept_offer(server, ride.id, "D001")
    state = :sys.get_state(server)

    for input <- [
          update_in(state.offers[offer.id], &Map.delete(&1, :status)),
          update_in(state.rides[ride.id], &Map.delete(&1, :status))
        ] do
      {_, result, final} = StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
      assert result == {:error, :inconsistent_ownership}
      assert final == input
    end
  end

  test "acceptance and another Ride dispatch compete without creating overlapping ownership" do
    {server, ride, offer, _} = reserved()
    {other, dispatch} = matching(server, "competing-dispatch")

    results =
      compete([
        fn -> Store.accept_offer(server, ride.id, "D001") end,
        fn -> Store.process_event(server, dispatch) end
      ])

    assert [{:ok, accepted}, {:ok, :processed}] = results
    assert accepted.status == :driver_accepted and accepted.currentOfferId == offer.id
    assert accepted.assignedDriverId == "D001"
    assert Store.get_ride(server, ride.id) == {:ok, accepted}
    assert {:ok, waiting} = Store.get_ride(server, other.id)
    assert waiting.status == :matching and waiting.assignedDriverId == nil
    assert Map.get(waiting, :currentOfferId) == nil
    assert {:ok, %{status: :busy}} = Store.get_driver(server, "D001")
    assert [receipt] = Store.list_offers(server)
    assert receipt.id == offer.id and receipt.status == :accepted
    assert receipt.acceptance_result == accepted

    assert {:ok, %{status: :processed, outcome: :no_candidate}} =
             Store.get_event(server, dispatch)

    state = :sys.get_state(server)
    assert map_size(state.pending_events) == 4 and map_size(state.offers) == 1
    assert Store.accept_offer(server, ride.id, "D001") == {:ok, accepted}
    assert :sys.get_state(server) == state
  end

  test "synthetic successful history for another Driver cannot support a second Ride acceptance" do
    {server, ride, offer, _} = reserved()
    state = :sys.get_state(server)

    other_result =
      Map.merge(state.rides[ride.id], %{
        status: :driver_accepted,
        assignedDriverId: "D002",
        currentOfferId: "older"
      })

    older =
      Map.merge(offer, %{
        id: "older",
        driverId: "D002",
        status: :completed,
        accepted_at_ms: 0,
        acceptance_result: other_result
      })

    input = put_in(state.offers[older.id], older)
    {_, result, final} = StateServer.handle_call({:accept_offer, ride.id, "D001"}, nil, input)
    assert result == {:error, :inconsistent_ownership}
    assert final == input
  end
end
