defmodule RideDispatch.Dispatch.ReservationDispatcherTest do
  use ExUnit.Case, async: true
  alias RideDispatch.Dispatch.{EventDispatcher, StateServer, Store}

  setup do
    clock = :atomics.new(1, [])

    server =
      start_supervised!(
        {StateServer,
         passengers: [%{id: "P001"}],
         drivers: [%{id: "D001", status: :available, latitude: 0, longitude: 0}],
         clock: fn -> :atomics.get(clock, 1) end}
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
    %{server: server, clock: clock}
  end

  test "historical #10A pending DispatchRequested is discovered without reopening RideCreated", %{
    server: server
  } do
    {ride, dispatch} = pending(server, "historical")
    created = Enum.find(Store.list_events(server), &(&1.type == :ride_created))
    assert created.status == :processed
    assert Store.list_actionable_events(server) == [dispatch]
    worker = dispatcher(server)
    assert_receive {:result, id, {:ok, :processed}, ^worker}, 1000
    assert id == dispatch.eventId
    assert_assignment(server, ride.id)
    assert Store.get_event(server, created.eventId) == {:ok, created}
    assert Store.list_actionable_events(server) == []
    EventDispatcher.wake(worker)
    assert_receive {:idle, ^worker}, 1000
    assert length(Store.list_offers(server)) == 1
  end

  test "new Ride creation reaches reservation asynchronously via the same authoritative owner", %{
    server: server
  } do
    worker = dispatcher(server, scan_interval_ms: 60_000)
    assert_receive {:idle, ^worker}, 1000
    {:ok, original} = Store.create_ride(server, "new", body())
    id = "dispatch-" <> original.id
    assert_receive {:result, ^id, {:ok, :processed}, ^worker}, 1000
    assert_assignment(server, original.id)
    assert Store.create_ride(server, "new", body()) == {:ok, original}
  end

  test "recovery scanning reserves work even when wake-up hints are unavailable", %{
    server: server
  } do
    worker = dispatcher(server, subscribe?: false)
    assert_receive {:idle, ^worker}, 1000
    {:ok, ride} = Store.create_ride(server, "missed", body())
    id = "dispatch-" <> ride.id
    assert_receive {:result, ^id, {:ok, :processed}, ^worker}, 1000
    assert_assignment(server, ride.id)
    assert :sys.get_state(server).event_subscribers == %{}
  end

  test "real dispatcher and barrier-released Store caller compete for one Driver", %{
    server: server
  } do
    pairs = [pending(server, "A"), pending(server, "B")]
    parent = self()
    calls = :atomics.new(1, [])

    process = fn owner, id ->
      if :atomics.add_get(calls, 1, 1) == 1 do
        send(parent, {:entered, self(), id})

        receive do
          :go -> :ok
        end
      end

      Store.process_event(owner, id)
    end

    worker = dispatcher(server, process: process)
    assert_receive {:entered, ^worker, worker_event}, 1000
    {_ride, other} = Enum.find(pairs, fn {_, event} -> event.eventId != worker_event end)

    task =
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go -> Store.process_event(server, other.eventId)
        end
      end)

    assert_receive {:ready, pid} when pid == task.pid
    send(worker, :go)
    send(task.pid, :go)
    assert Task.await(task) == {:ok, :processed}
    assert_receive {:result, ^worker_event, {:ok, :processed}, ^worker}, 1000
    assert_receive {:idle, ^worker}, 1000
    assert [offer] = Store.list_offers(server)
    assert offer.driverId == "D001" and offer.status == :pending
    assert {:ok, %{status: :offered}} = Store.get_driver(server, "D001")
    state = :sys.get_state(server)
    assert Enum.count(state.rides, fn {_, r} -> r.status == :driver_assigned end) == 1

    for {ride, event} <- pairs do
      current = state.rides[ride.id]
      done = state.pending_events[event.eventId]
      assert done.status == :processed

      if ride.id == offer.rideId do
        assert current.status == :driver_assigned and current.assignedDriverId == "D001"
        assert current.currentOfferId == offer.id
        assert done.outcome == :offer_created
      else
        assert current.status == :matching and current.assignedDriverId == nil
        assert Map.get(current, :currentOfferId) == nil
        assert done.outcome == :no_candidate
      end
    end

    assert map_size(state.pending_events) == 4
  end

  defp body do
    %{
      "passengerId" => "P001",
      "pickup" => %{"latitude" => 0, "longitude" => 0},
      "destination" => %{"latitude" => 1, "longitude" => 1}
    }
  end

  defp pending(server, key) do
    {:ok, ride} = Store.create_ride(server, key, body())

    created =
      Enum.find(Store.list_events(server), &(&1.rideId == ride.id and &1.type == :ride_created))

    assert Store.process_event(server, created.eventId) == {:ok, :processed}

    event =
      Enum.find(
        Store.list_events(server),
        &(&1.rideId == ride.id and &1.type == :dispatch_requested)
      )

    {ride, event}
  end

  defp dispatcher(server, opts \\ []) do
    start_supervised!(
      {EventDispatcher, Keyword.merge([store: server, scan_interval_ms: 20], opts)}
    )
  end

  defp assert_assignment(server, ride_id) do
    assert {:ok, %{status: :driver_assigned, assignedDriverId: "D001", currentOfferId: id}} =
             Store.get_ride(server, ride_id)

    assert [offer] = Store.list_offers(server)
    assert offer.id == id and offer.rideId == ride_id and offer.driverId == "D001"
    assert offer.status == :pending
    assert {:ok, %{status: :offered}} = Store.get_driver(server, "D001")

    assert {:ok, %{status: :processed, outcome: :offer_created}} =
             Store.get_event(server, "dispatch-" <> ride_id)

    assert length(Store.list_events(server)) == 2
    assert Store.list_actionable_events(server) == []
  end
end
