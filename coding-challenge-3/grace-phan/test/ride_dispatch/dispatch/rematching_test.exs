defmodule RideDispatch.Dispatch.RematchingTest do
  use ExUnit.Case, async: true
  alias RideDispatch.Dispatch.{EventDispatcher, StateServer, Store}

  test "a rejection wake-up drives A to B asynchronously and preserves original history" do
    {server, ride, old, _} = reserved()
    history = Store.list_events(server)
    worker = dispatcher(server, scan_interval_ms: 60_000)
    assert_receive {:idle, ^worker}, 1000
    assert {:ok, matching} = Store.reject_offer(server, ride.id, "A")
    id = "redispatch-" <> old.id
    assert_receive {:result, ^id, {:ok, :processed}, ^worker}, 1000
    assert {:ok, current} = Store.get_ride(server, ride.id)
    assert current.status == :driver_assigned and current.assignedDriverId == "B"
    assert {:ok, %{status: :offered}} = Store.get_driver(server, "B")
    assert {:ok, %{status: :available}} = Store.get_driver(server, "A")

    assert {:ok, %{status: :pending, driverId: "B"}} =
             Store.get_offer(server, current.currentOfferId)

    assert {:ok, %{status: :processed, outcome: :offer_created}} = Store.get_event(server, id)

    assert {:ok, %{status: :rejected, rejection_receipt: %{original_result: ^matching}}} =
             Store.get_offer(server, old.id)

    assert length(Store.list_offers(server)) == 2
    for event <- history, do: assert(Store.get_event(server, event.eventId) == {:ok, event})
    assert {:ok, accepted} = Store.accept_offer(server, ride.id, "B")
    before = :sys.get_state(server)
    assert Store.reject_offer(server, ride.id, "A") == {:ok, matching}
    assert :sys.get_state(server) == before
    assert before.offers[accepted.currentOfferId].acceptance_result == accepted
  end

  test "blocked processing rechecks current availability, coordinates, nearest candidate and reservation time" do
    for change <- [:offline, :outside, :nearer] do
      {server, ride, old, clock} = reserved()
      parent = self()

      process = fn owner, id ->
        send(parent, {:entered, self(), id})

        receive do
          :go -> Store.process_event(owner, id)
        end
      end

      worker = dispatcher(server, process: process)
      assert_receive {:idle, ^worker}, 1000
      assert {:ok, _} = Store.reject_offer(server, ride.id, "A")
      id = "redispatch-" <> old.id
      assert_receive {:entered, ^worker, ^id}, 1000

      case change do
        :offline ->
          assert {:ok, _} = Store.set_driver_availability(server, "B", false)

        :outside ->
          assert {:ok, _} =
                   Store.update_driver_location(server, "B", %{latitude: 5, longitude: 5})

        :nearer ->
          assert {:ok, _} =
                   Store.update_driver_location(server, "C", %{latitude: 0, longitude: 0})
      end

      :atomics.put(clock, 1, 80_000)
      send(worker, :go)
      assert_receive {:result, ^id, {:ok, :processed}, ^worker}, 1000

      assert {:ok, %{assignedDriverId: "C", currentOfferId: current_id}} =
               Store.get_ride(server, ride.id)

      assert {:ok, %{created_at_ms: 80_000, expires_at_ms: 110_000}} =
               Store.get_offer(server, current_id)
    end
  end

  test "real successive rejections exhaust a Ride, while A remains eligible for another Ride" do
    {server, ride, old, _} = reserved()
    worker = dispatcher(server)

    for driver <- ["A", "B", "C"] do
      assert {:ok, %{currentOfferId: offer_id, assignedDriverId: ^driver}} =
               Store.get_ride(server, ride.id)

      assert {:ok, _} = Store.reject_offer(server, ride.id, driver)
      id = "redispatch-" <> offer_id
      assert_receive {:result, ^id, {:ok, :processed}, ^worker}, 1000
    end

    assert {:ok, %{status: :matching, assignedDriverId: nil, currentOfferId: nil}} =
             Store.get_ride(server, ride.id)

    assert length(Store.list_offers(server)) == 3
    assert Enum.all?(Store.list_offers(server), &(&1.status == :rejected))
    assert Enum.sort(Enum.map(Store.list_offers(server), & &1.driverId)) == ["A", "B", "C"]

    assert [%{status: :processed, outcome: :no_candidate, attempts: 1}] =
             Enum.filter(Store.list_events(server), &(Map.get(&1, :outcome) == :no_candidate))

    assert Store.list_actionable_events(server) == []
    {:ok, other} = Store.create_ride(server, "other", body())
    id = "dispatch-" <> other.id
    assert_receive {:result, ^id, {:ok, :processed}, ^worker}, 1000
    assert {:ok, %{assignedDriverId: "A"}} = Store.get_ride(server, other.id)
    before = :sys.get_state(server)
    assert {:ok, _} = Store.reject_offer(server, ride.id, "A")
    assert :sys.get_state(server) == before
    assert Enum.count(Store.list_events(server), &(&1.eventId == "redispatch-" <> old.id)) == 1
  end

  test "competing duplicate redispatch calls create exactly one replacement" do
    {server, ride, old, _} = reserved()
    assert {:ok, _} = Store.reject_offer(server, ride.id, "A")
    id = "redispatch-" <> old.id
    results = competing(List.duplicate(fn -> Store.process_event(server, id) end, 10))
    assert Enum.count(results, &(&1 == {:ok, :processed})) == 1
    assert Enum.count(results, &(&1 == {:ok, :already_processed})) == 9
    state = :sys.get_state(server)
    assert map_size(state.offers) == 2
    assert state.rides[ride.id].assignedDriverId == "B"
    assert state.drivers["A"].status == :available
    assert state.drivers["B"].status == :offered
    assert state.offers[old.id].status == :rejected
    assert state.pending_events[id].attempts == 1
  end

  test "two unrelated Rides genuinely compete for a released Driver without reviving its old Offer" do
    {server, original, old, _} = reserved()
    assert {:ok, _} = Store.reject_offer(server, original.id, "A")

    for driver <- ["B", "C"],
        do: assert({:ok, _} = Store.set_driver_availability(server, driver, false))

    pairs = for key <- ["R2", "R3"], do: matching(server, key)

    results =
      competing(Enum.map(pairs, fn {_, id} -> fn -> Store.process_event(server, id) end end))

    assert results == [{:ok, :processed}, {:ok, :processed}]
    state = :sys.get_state(server)
    rides = Enum.map(pairs, fn {ride, _} -> state.rides[ride.id] end)
    assert [winner] = Enum.filter(rides, &(&1.status == :driver_assigned))
    assert [loser] = Enum.filter(rides, &(&1.status == :matching))
    assert winner.assignedDriverId == "A"
    assert loser.assignedDriverId == nil and Map.get(loser, :currentOfferId) == nil
    assert state.drivers["A"].status == :offered
    assert state.rides[original.id].status == :matching
    assert state.offers[old.id].status == :rejected
    assert map_size(state.offers) == 2

    assert Enum.count(Map.values(state.offers), &(&1.driverId == "A" and &1.status == :pending)) ==
             1

    for {_, id} <- pairs, do: assert(state.pending_events[id].status == :processed)
    assert state.pending_events["redispatch-" <> old.id].status == :pending
    assert {:ok, _} = Store.accept_offer(server, winner.id, "A")
    before = :sys.get_state(server)
    assert {:ok, _} = Store.reject_offer(server, original.id, "A")
    assert :sys.get_state(server) == before
    assert before.drivers["A"].status == :busy
  end

  test "a missed rejection hint is recovered by scanning" do
    {server, ride, old, _} = reserved()
    worker = dispatcher(server, subscribe?: false, scan_interval_ms: 20)
    assert_receive {:idle, ^worker}, 1000
    assert {:ok, _} = Store.reject_offer(server, ride.id, "A")
    id = "redispatch-" <> old.id
    assert_receive {:result, ^id, {:ok, :processed}, ^worker}, 1000
    assert {:ok, %{assignedDriverId: "B"}} = Store.get_ride(server, ride.id)
    assert :sys.get_state(server).event_subscribers == %{}
  end

  test "dispatcher restart before or after replacement commit never duplicates ownership" do
    for commit? <- [false, true] do
      {server, ride, old, _} = reserved()
      assert {:ok, _} = Store.reject_offer(server, ride.id, "A")
      id = "redispatch-" <> old.id
      parent = self()
      calls = :atomics.new(1, [])

      process = fn owner, event_id ->
        if :atomics.add_get(calls, 1, 1) == 1 do
          if commit?, do: Store.process_event(owner, event_id)
          send(parent, {:blocked, self()})

          receive do
            :never -> :ok
          end
        end

        Store.process_event(owner, event_id)
      end

      worker = dispatcher(server, process: process)
      assert_receive {:blocked, ^worker}, 1000
      ref = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1000
      assert_receive {:idle, restarted}, 1000
      refute restarted == worker
      assert {:ok, %{status: :processed, attempts: 1}} = Store.get_event(server, id)
      assert {:ok, %{assignedDriverId: "B"}} = Store.get_ride(server, ride.id)
      assert length(Store.list_offers(server)) == 2
      assert {:ok, %{status: :rejected}} = Store.get_offer(server, old.id)
    end
  end

  test "technical failures back off and exhaust; failure does not authorize another rejection event" do
    {server, ride, old, clock} = reserved()
    assert {:ok, original} = Store.reject_offer(server, ride.id, "A")
    id = "redispatch-" <> old.id
    worker = dispatcher(server, process: fn _, _ -> {:error, :retryable} end)

    for {now, attempts, status} <- [{0, 1, :pending}, {1000, 2, :pending}, {3000, 3, :failed}] do
      :atomics.put(clock, 1, now)
      EventDispatcher.wake(worker)
      assert_receive {:result, ^id, _, ^worker}, 1000
      assert {:ok, event} = Store.get_event(server, id)
      assert event.status == status and event.attempts == attempts
      assert event.last_error == :processing_failed
      if status == :pending, do: assert(event.next_attempt_at > now)
      assert {:ok, %{status: :matching, assignedDriverId: nil}} = Store.get_ride(server, ride.id)
      assert length(Store.list_offers(server)) == 1
      # Synchronize at idle before advancing injected time; no arbitrary sleeps.
      assert_receive {:idle, ^worker}, 1000
    end

    before = :sys.get_state(server)
    assert Store.reject_offer(server, ride.id, "A") == {:ok, original}
    assert :sys.get_state(server) == before
    assert Store.list_actionable_events(server) == []
    assert before.offers[old.id].status == :rejected
    assert before.pending_events[id].status == :failed
    assert Enum.count(Store.list_events(server), &(&1.eventId == id)) == 1
  end

  test "a retryable replacement failure later succeeds rather than being reported as no candidate" do
    {server, ride, old, clock} = reserved()
    assert {:ok, _} = Store.reject_offer(server, ride.id, "A")
    calls = :atomics.new(1, [])

    worker =
      dispatcher(server,
        process: fn owner, id ->
          if :atomics.add_get(calls, 1, 1) == 1,
            do: {:error, :retryable},
            else: Store.process_event(owner, id)
        end
      )

    id = "redispatch-" <> old.id
    assert_receive {:result, ^id, _, ^worker}, 1000
    assert_receive {:idle, ^worker}, 1000
    assert {:ok, failed_attempt} = Store.get_event(server, id)
    assert failed_attempt.status == :pending and failed_attempt.attempts == 1
    refute Map.has_key?(failed_attempt, :outcome)
    :atomics.put(clock, 1, 1000)
    EventDispatcher.wake(worker)
    assert_receive {:result, ^id, {:ok, :processed}, ^worker}, 1000

    assert {:ok, %{status: :processed, outcome: :offer_created, attempts: 2}} =
             Store.get_event(server, id)

    assert {:ok, %{assignedDriverId: "B"}} = Store.get_ride(server, ride.id)
    assert length(Store.list_offers(server)) == 2
  end

  test "uncertain timeout before or after replacement commit rereads state without charging failures" do
    for commit? <- [false, true] do
      {server, ride, old, _} = reserved()
      assert {:ok, _} = Store.reject_offer(server, ride.id, "A")
      calls = :atomics.new(1, [])

      worker =
        dispatcher(server,
          scan_interval_ms: 60_000,
          process: fn owner, id ->
            if :atomics.add_get(calls, 1, 1) == 1 do
              if commit?, do: Store.process_event(owner, id)
              # Controlled Store timeout signal, not an elapsed network-timeout test.
              exit({:timeout, :controlled_call})
            end

            Store.process_event(owner, id)
          end
        )

      id = "redispatch-" <> old.id
      expected = if commit?, do: {:ok, :already_processed}, else: {:error, :uncertain}
      assert_receive {:result, ^id, ^expected, ^worker}, 1000

      if not commit? do
        assert {:ok, event} = Store.get_event(server, id)
        assert event.status == :pending and Map.get(event, :attempts, 0) == 0
        EventDispatcher.wake(worker)
        assert_receive {:result, ^id, {:ok, :processed}, ^worker}, 1000
      end

      assert {:ok, %{status: :processed, attempts: 1}} = Store.get_event(server, id)
      assert {:ok, %{assignedDriverId: "B"}} = Store.get_ride(server, ride.id)
      assert length(Store.list_offers(server)) == 2
    end
  end

  defp reserved do
    clock = :atomics.new(1, [])

    server =
      start_supervised!(
        Supervisor.child_spec(
          {StateServer,
           passengers: [%{id: "P"}],
           drivers:
             for(
               {id, lat} <- [{"A", 0}, {"B", 0.001}, {"C", 0.002}],
               do: %{id: id, status: :available, latitude: lat, longitude: 0}
             ),
           clock: fn -> :atomics.get(clock, 1) end},
          id: make_ref()
        )
      )

    parent = self()
    handler = make_ref()

    :telemetry.attach_many(
      handler,
      [[:ride_dispatch, :event, :processed], [:ride_dispatch, :dispatcher, :idle]],
      fn event, _, metadata, _ ->
        if metadata.server == server do
          case event do
            [:ride_dispatch, :event, :processed] ->
              send(parent, {:result, metadata.event_id, metadata.result, metadata.dispatcher})

            [:ride_dispatch, :dispatcher, :idle] ->
              send(parent, {:idle, metadata.dispatcher})
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    {ride, id} = matching(server, "original")
    assert {:ok, :processed} = Store.process_event(server, id)
    [offer] = Store.list_offers(server)
    {server, ride, offer, clock}
  end

  defp matching(server, key) do
    {:ok, ride} = Store.create_ride(server, key, body())

    event =
      Enum.find(Store.list_events(server), &(&1.rideId == ride.id and &1.type == :ride_created))

    assert {:ok, :processed} = Store.process_event(server, event.eventId)
    {ride, "dispatch-" <> ride.id}
  end

  defp dispatcher(server, opts \\ []) do
    start_supervised!(
      Supervisor.child_spec(
        {EventDispatcher, Keyword.merge([store: server, scan_interval_ms: 60_000], opts)},
        id: make_ref()
      )
    )
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

    for _ <- tasks, do: assert_receive({:ready, _}, 1000)
    Enum.each(tasks, &send(&1.pid, :go))
    Enum.map(tasks, &Task.await/1)
  end

  defp body do
    %{
      "passengerId" => "P",
      "pickup" => %{"latitude" => 0, "longitude" => 0},
      "destination" => %{"latitude" => 1, "longitude" => 1}
    }
  end
end
