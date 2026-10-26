defmodule RideDispatch.Dispatch.EventDispatcherTest do
  use ExUnit.Case, async: true
  alias RideDispatch.Dispatch.{EventDispatcher, StateServer, Store}

  setup do
    clock = :atomics.new(1, [])

    server =
      start_supervised!(
        {StateServer, passengers: [%{id: "P001"}], clock: fn -> :atomics.get(clock, 1) end}
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

  defp create(server, key \\ "key") do
    body = %{
      "passengerId" => "P001",
      "pickup" => %{"latitude" => 0, "longitude" => 0},
      "destination" => %{"latitude" => 1, "longitude" => 1}
    }

    {:ok, ride} = Store.create_ride(server, key, body)

    event =
      Enum.find(Store.list_events(server), &(&1.rideId == ride.id and &1.type == :ride_created))

    {ride, event.eventId, body}
  end

  defp dispatcher(server, opts \\ []) do
    start_supervised!(
      {EventDispatcher, Keyword.merge([store: server, scan_interval_ms: 20], opts)}
    )
  end

  test "application supervises one named dispatcher after its authoritative owner" do
    assert is_pid(Process.whereis(EventDispatcher))
    children = Supervisor.which_children(RideDispatch.Supervisor)
    assert Enum.count(children, fn {id, _, _, _} -> id == EventDispatcher end) == 1
    assert :sys.get_state(EventDispatcher).store == StateServer
  end

  test "startup consumes both event types independently of HTTP and preserves original replay",
       %{server: server} do
    {ride, id, body} = create(server)
    worker = dispatcher(server)
    assert_receive {:result, ^id, {:ok, :processed}, ^worker}, 1000
    dispatch_id = "dispatch-" <> ride.id
    assert_receive {:result, ^dispatch_id, {:ok, :processed}, ^worker}, 1000
    assert {:ok, %{status: :matching}} = Store.get_ride(server, ride.id)
    assert Store.create_ride(server, "key", body) == {:ok, ride}

    assert [%{type: :dispatch_requested, status: :processed, outcome: :no_candidate}] =
             Enum.filter(Store.list_events(server), &(&1.type == :dispatch_requested))

    EventDispatcher.wake(worker)
    :sys.get_state(worker)
    assert length(Store.list_events(server)) == 2
  end

  test "wake hints process new work without waiting for the recovery interval", %{server: server} do
    worker = dispatcher(server, scan_interval_ms: 60_000)
    assert_receive {:idle, ^worker}, 1000
    {_ride, id, _} = create(server)
    assert_receive {:result, ^id, {:ok, :processed}, ^worker}, 1000
  end

  test "bounded recovery scans discover work when notification hints are unavailable", %{
    server: server
  } do
    worker = dispatcher(server, subscribe?: false)
    assert_receive {:idle, ^worker}, 1000
    assert :sys.get_state(server).event_subscribers == %{}
    {_ride, id, _} = create(server)
    assert_receive {:result, ^id, {:ok, :processed}, ^worker}, 1000
  end

  test "supervisor restarts dispatcher with pending work surviving a crash before processing", %{
    server: server
  } do
    parent = self()

    process = fn owner, id ->
      send(parent, {:entered, self(), id})

      receive do
        :continue -> Store.process_event(owner, id)
      end
    end

    {_ride, id, _} = create(server)
    worker = dispatcher(server, process: process)
    assert_receive {:entered, ^worker, ^id}, 1000
    ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    assert_receive {:entered, restarted, ^id}, 1000
    refute restarted == worker
    assert {:ok, %{status: :pending}} = Store.get_event(server, id)
    send(restarted, :continue)
    assert_receive {:result, ^id, {:ok, :processed}, ^restarted}, 1000
    assert Process.alive?(server)
    assert length(Store.list_events(server)) == 2
  end

  test "worker crash after commit cannot repeat the transition or successor emission", %{
    server: server
  } do
    parent = self()

    process = fn owner, id ->
      result = Store.process_event(owner, id)
      {:ok, event} = Store.get_event(owner, id)

      if event.type == :ride_created do
        send(parent, {:committed, self(), result})

        receive do
          :continue -> :ok
        end
      end

      result
    end

    {_ride, id, _} = create(server)
    worker = dispatcher(server, process: process, scan_interval_ms: 60_000)
    assert_receive {:committed, ^worker, {:ok, :processed}}, 1000
    ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    assert_receive {:idle, restarted}, 1000
    refute restarted == worker
    assert {:ok, %{status: :processed, attempts: 1}} = Store.get_event(server, id)
    assert length(Store.list_events(server)) == 2
    assert Process.read_timer(:sys.get_state(restarted).timer) > 0
  end

  test "registered owner replacement is rediscovered and old volatile work is lost" do
    name = {:global, make_ref()}
    opts = [name: name, passengers: [%{id: "P001"}]]
    owner = start_supervised!(Supervisor.child_spec({StateServer, opts}, id: :replaceable_owner))
    parent = self()
    handler = make_ref()

    :telemetry.attach(
      handler,
      [:ride_dispatch, :event, :processed],
      fn _, _, metadata, _ ->
        if metadata.server == name, do: send(parent, {:replacement_result, metadata.event_id})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    worker =
      start_supervised!(
        Supervisor.child_spec({EventDispatcher, store: name, scan_interval_ms: 20},
          id: :replacement_worker
        )
      )

    {old, id, _} = create(name)
    assert_receive {:replacement_result, ^id}, 1000
    stop_supervised!(:replaceable_owner)

    replacement =
      start_supervised!(Supervisor.child_spec({StateServer, opts}, id: :replaceable_owner))

    refute replacement == owner
    assert Store.get_ride(name, old.id) == :not_found
    {_new, new_id, _} = create(name, "new")
    assert_receive {:replacement_result, ^new_id}, 1000
    assert Process.alive?(worker)
  end

  test "retryable processing failures wait for fake-time eligibility and then succeed", %{
    server: server,
    clock: clock
  } do
    calls = :atomics.new(1, [])

    process = fn owner, id ->
      case :atomics.add_get(calls, 1, 1) do
        1 -> raise "controlled worker failure outside state owner"
        2 -> {:error, :retryable}
        _ -> Store.process_event(owner, id)
      end
    end

    {_ride, id, _} = create(server)
    worker = dispatcher(server, process: process, scan_interval_ms: 60_000)
    assert_receive {:result, ^id, {:error, {:retry_at, 1000}}, ^worker}, 1000
    EventDispatcher.wake(worker)
    :sys.get_state(worker)
    assert :atomics.get(calls, 1) == 1
    :atomics.put(clock, 1, 1000)
    EventDispatcher.wake(worker)
    assert_receive {:result, ^id, {:error, {:retry_at, 3000}}, ^worker}, 1000
    :atomics.put(clock, 1, 3000)
    EventDispatcher.wake(worker)
    assert_receive {:result, ^id, {:ok, :processed}, ^worker}, 1000
    assert {:ok, %{attempts: 3, status: :processed}} = Store.get_event(server, id)
  end

  test "timeout after a committed command is resolved by authoritative reread without failure accounting",
       %{server: server} do
    process = fn owner, id ->
      Store.process_event(owner, id)
      exit({:timeout, {:test, id}})
    end

    {_ride, id, _} = create(server)
    worker = dispatcher(server, process: process)
    assert_receive {:result, ^id, {:ok, :already_processed}, ^worker}, 1000
    assert {:ok, %{attempts: 1, status: :processed}} = Store.get_event(server, id)
    assert length(Store.list_events(server)) == 2
  end

  test "uncommitted uncertain outcome is reread and retried without recording a definite failure",
       %{server: server} do
    calls = :atomics.new(1, [])

    process = fn owner, id ->
      if :atomics.add_get(calls, 1, 1) == 1,
        do: exit({:timeout, {:test, id}}),
        else: Store.process_event(owner, id)
    end

    {_ride, id, _} = create(server)
    worker = dispatcher(server, process: process, scan_interval_ms: 60_000)
    assert_receive {:result, ^id, {:error, :uncertain}, ^worker}, 1000
    assert {:ok, %{status: :pending} = event} = Store.get_event(server, id)
    assert Map.get(event, :attempts, 0) == 0
    EventDispatcher.wake(worker)
    assert_receive {:result, ^id, {:ok, :processed}, ^worker}, 1000
  end
end
