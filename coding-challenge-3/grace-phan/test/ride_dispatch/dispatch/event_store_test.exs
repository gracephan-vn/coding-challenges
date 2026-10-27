defmodule RideDispatch.Dispatch.EventStoreTest do
  use ExUnit.Case, async: true
  alias RideDispatch.Dispatch.{StateServer, Store}

  defp created(opts \\ []) do
    {:ok, state} = StateServer.init(Keyword.merge([passengers: [%{id: "P001"}]], opts))

    body = %{
      "passengerId" => "P001",
      "pickup" => %{"latitude" => 0, "longitude" => 0},
      "destination" => %{"latitude" => 1, "longitude" => 1}
    }

    {:reply, {:ok, ride}, state} =
      StateServer.handle_call({:create_ride, "key", body}, nil, state)

    {ride, state.idempotency["key"].event_id, state}
  end

  test "one callback starts matching, acknowledges and emits exactly one successor" do
    {ride, id, state} = created()

    assert {:reply, {:ok, :processed}, updated} =
             StateServer.handle_call({:process_event, id}, nil, state)

    assert updated.rides[ride.id] == %{ride | status: :matching}
    assert updated.pending_events[id].status == :processed

    assert [%{rideId: ride_id, status: :pending, type: :dispatch_requested}] =
             Enum.filter(Map.values(updated.pending_events), &(&1.type == :dispatch_requested))

    assert ride_id == ride.id
    assert updated.idempotency == state.idempotency

    assert {:reply, {:ok, :already_processed}, ^updated} =
             StateServer.handle_call({:process_event, id}, nil, updated)

    duplicate_id = "duplicate"

    duplicate = %{
      updated
      | pending_events:
          Map.put(updated.pending_events, duplicate_id, %{
            state.pending_events[id]
            | eventId: duplicate_id
          })
    }

    assert {:reply, {:ok, :ignored}, duplicate_done} =
             StateServer.handle_call({:process_event, duplicate_id}, nil, duplicate)

    assert Enum.count(
             Map.values(duplicate_done.pending_events),
             &(&1.type == :dispatch_requested)
           ) == 1
  end

  test "unsupported pending work is unchanged and does not block supported discovery" do
    {_ride, id, state} = created()

    unsupported = %{
      eventId: "aaa",
      rideId: "missing",
      type: :future_event,
      status: :pending
    }

    state = %{state | pending_events: Map.put(state.pending_events, "aaa", unsupported)}

    assert {:reply, {:error, :unsupported_event}, ^state} =
             StateServer.handle_call({:process_event, "aaa"}, nil, state)

    assert {:reply, [event], ^state} =
             StateServer.handle_call(:list_actionable_events, nil, state)

    assert event.eventId == id

    assert {:reply, :not_found, ^state} =
             StateServer.handle_call({:get_event, "missing"}, nil, state)
  end

  test "missing and invalid rides fail permanently; known later states are ignored" do
    {ride, id, state} = created()

    for {rides, reason} <- [
          {%{}, :ride_not_found},
          {%{ride.id => %{ride | status: :unknown}}, :invalid_state}
        ] do
      fixture = %{state | rides: rides}

      assert {:reply, {:error, {:permanent, ^reason}}, updated} =
               StateServer.handle_call({:process_event, id}, nil, fixture)

      assert updated.rides == rides
      assert updated.pending_events[id].status == :failed

      assert {:reply, [], ^updated} =
               StateServer.handle_call(:list_actionable_events, nil, updated)
    end

    for status <- [:matching, :driver_assigned, :driver_accepted] do
      fixture = %{state | rides: %{ride.id => %{ride | status: status}}}

      assert {:reply, {:ok, :ignored}, updated} =
               StateServer.handle_call({:process_event, id}, nil, fixture)

      assert updated.rides == fixture.rides
      assert map_size(updated.pending_events) == 1
    end
  end

  test "cancelled callback result is ignored without resurrection; a status alone fails" do
    {ride, id, state} = created()

    assert {:reply, {:ok, _}, input} =
             StateServer.handle_call({:terminal_ride, :cancel, ride.id}, nil, state)

    assert {:reply, {:ok, :ignored}, final} =
             StateServer.handle_call({:process_event, id}, nil, input)

    assert final.rides == input.rides and map_size(final.pending_events) == 1
    assert final.pending_events[id].outcome == :incompatible_ride_state

    for status <- [:cancelled, :completed] do
      broken = put_in(state.rides[ride.id].status, status)

      assert {:reply, {:error, {:permanent, :inconsistent_ownership}}, failed} =
               StateServer.handle_call({:process_event, id}, nil, broken)

      assert failed.rides == broken.rides
    end
  end

  test "retry failures are bounded, fenced by attempt version, and respect exact fake-time boundaries" do
    clock = :atomics.new(1, [])
    now = fn -> :atomics.get(clock, 1) end
    {_ride, id, state} = created(clock: now)

    assert {:reply, {:error, {:retry_at, 1000}}, retrying} =
             StateServer.handle_call({:fail_event, id, 0, :processing_failed}, nil, state)

    assert {:reply, [], ^retrying} =
             StateServer.handle_call(:list_actionable_events, nil, retrying)

    assert {:reply, {:error, :stale_attempt}, ^retrying} =
             StateServer.handle_call({:fail_event, id, 0, :processing_failed}, nil, retrying)

    assert {:reply, {:error, {:retry_at, 1000}}, ^retrying} =
             StateServer.handle_call({:process_event, id}, nil, retrying)

    :atomics.put(clock, 1, 999)

    assert {:reply, [], ^retrying} =
             StateServer.handle_call(:list_actionable_events, nil, retrying)

    :atomics.put(clock, 1, 1000)

    assert {:reply, [_], ^retrying} =
             StateServer.handle_call(:list_actionable_events, nil, retrying)

    assert {:reply, {:error, {:retry_at, 3000}}, twice} =
             StateServer.handle_call({:fail_event, id, 1, :processing_failed}, nil, retrying)

    :atomics.put(clock, 1, 3000)

    assert {:reply, {:error, :failed}, failed} =
             StateServer.handle_call({:fail_event, id, 2, :processing_failed}, nil, twice)

    assert failed.pending_events[id].attempts == 3
    assert failed.pending_events[id].status == :failed
    assert failed.rides == state.rides
    assert {:reply, [], ^failed} = StateServer.handle_call(:list_actionable_events, nil, failed)
  end

  test "malformed failure versions cannot crash the authoritative owner" do
    {_ride, id, state} = created()

    for version <- [0.0, -1, nil, "0"] do
      assert {:reply, {:error, :invalid_attempt}, ^state} =
               StateServer.handle_call({:fail_event, id, version, :processing_failed}, nil, state)
    end
  end

  test "competing RideCreated calls emit one discoverable pending successor" do
    server = start_supervised!({StateServer, passengers: [%{id: "P001"}]})

    body = %{
      "passengerId" => "P001",
      "pickup" => %{"latitude" => 0, "longitude" => 0},
      "destination" => %{"latitude" => 1, "longitude" => 1}
    }

    {:ok, ride} = Store.create_ride(server, "key", body)
    [event] = Store.list_actionable_events(server)
    parent = self()

    tasks =
      for _ <- 1..10,
          do:
            Task.async(fn ->
              send(parent, {:ready, self()})

              receive do
                :go -> Store.process_event(server, event.eventId)
              end
            end)

    for _ <- tasks, do: assert_receive({:ready, _})
    for task <- tasks, do: send(task.pid, :go)
    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &(&1 == {:ok, :processed})) == 1
    assert Enum.count(results, &(&1 == {:ok, :already_processed})) == 9
    assert {:ok, %{status: :matching}} = Store.get_ride(server, ride.id)
    assert [%{type: :dispatch_requested, status: :pending}] = Store.list_actionable_events(server)
    events = Store.list_events(server)
    assert length(events) == 2
    assert Enum.count(events, &(&1.type == :dispatch_requested and &1.status == :pending)) == 1
    assert {:ok, _} = Store.get_event(server, event.eventId)
  end
end
