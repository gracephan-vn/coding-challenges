defmodule RideDispatch.Dispatch.EventDispatcher do
  @moduledoc """
  One supervised asynchronous consumer. Store owns every business mutation.
  Notifications are hints; startup and bounded recovery scans find missed work.
  RideCreated and DispatchRequested are actionable; other event types stay pending.

  `store` accepts a PID or registered name. `scan_interval_ms` defaults to 1000.
  Tests may supply a processing function (outside the state owner) and disable
  subscriptions with an explicit PID to exercise missed-notification recovery.
  No claim, lease, separate acknowledgement, or durable delivery is provided.
  """
  use GenServer
  alias RideDispatch.Dispatch.{Store, LifecycleLog}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def wake(dispatcher), do: send(dispatcher, :events_available)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :scan_interval_ms, 1000)
    true = is_integer(interval) and interval > 0

    state = %{
      store: Keyword.fetch!(opts, :store),
      interval: interval,
      process: Keyword.get(opts, :process, &Store.process_event/2),
      subscribe?: Keyword.get(opts, :subscribe?, true),
      owner: nil,
      monitor: nil,
      timer: nil,
      tick: nil,
      immediate?: false
    }

    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: {:noreply, schedule(state, 0)}

  @impl true
  def handle_info(:events_available, %{immediate?: true} = state), do: {:noreply, state}
  def handle_info(:events_available, state), do: {:noreply, schedule(state, 0)}

  def handle_info({:scan, tick}, %{tick: tick} = state) do
    state = %{state | timer: nil, tick: nil, immediate?: false}
    {:noreply, scan(state)}
  end

  def handle_info({:scan, _obsolete}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    {:noreply, schedule(%{state | owner: nil, monitor: nil}, state.interval)}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  defp scan(state) do
    try do
      scan_connected(connect(state))
    catch
      :exit, _unavailable_or_timeout -> schedule(state, state.interval)
    end
  end

  defp scan_connected(state) do
    try do
      case Store.list_actionable_events(state.store) do
        [event | _rest] ->
          result = process(state, event)

          :telemetry.execute([:ride_dispatch, :event, :processed], %{}, %{
            server: state.store,
            event_id: event.eventId,
            result: result,
            dispatcher: self()
          })

          delay =
            if result in [{:error, :uncertain}, {:error, :owner_unavailable}],
              do: state.interval,
              else: 0

          schedule(state, delay)

        [] ->
          delay = Store.next_event_delay(state.store)

          :telemetry.execute([:ride_dispatch, :dispatcher, :idle], %{}, %{
            server: state.store,
            dispatcher: self()
          })

          schedule(state, if(is_nil(delay), do: state.interval, else: min(delay, state.interval)))
      end
    catch
      :exit, _unavailable_or_timeout -> schedule(state, state.interval)
    end
  end

  defp connect(state) do
    owner =
      if state.subscribe? do
        {:ok, pid} = Store.subscribe_events(state.store)
        pid
      else
        true = is_pid(state.store)
        state.store
      end

    if owner == state.owner do
      state
    else
      if state.monitor, do: Process.demonitor(state.monitor, [:flush])
      %{state | owner: owner, monitor: Process.monitor(owner)}
    end
  end

  defp process(state, event) do
    # Recheck before any retry: an earlier timed-out command may have committed.
    case Store.get_event(state.store, event.eventId) do
      {:ok, %{status: :processed}} -> {:ok, :already_processed}
      {:ok, %{status: :failed}} -> {:error, :failed}
      {:ok, current} -> invoke(state, current)
      :not_found -> :not_found
    end
  end

  defp invoke(state, event) do
    try do
      case state.process.(state.store, event.eventId) do
        {:error, :retryable} -> record_failure(state, event)
        result -> result
      end
    rescue
      _worker_exception -> record_failure(state, event)
    catch
      :exit, {:timeout, _call} -> resolve_timeout(state, event)
      :exit, _owner_failure -> {:error, :owner_unavailable}
    end
  end

  defp resolve_timeout(state, event) do
    result =
      case Store.get_event(state.store, event.eventId) do
        {:ok, %{status: :processed}} -> {:ok, :already_processed}
        {:ok, %{status: :failed}} -> {:error, :failed}
        _pending_or_missing -> {:error, :uncertain}
      end

    LifecycleLog.emit(
      "event.timeout_reconciled",
      %{
        eventId: event.eventId,
        rideId: event.rideId,
        outcome: elem(result, 1)
      },
      :warning
    )

    result
  end

  defp record_failure(state, event),
    do:
      Store.fail_event(
        state.store,
        event.eventId,
        Map.get(event, :attempts, 0),
        :processing_failed
      )

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    tick = make_ref()
    timer = Process.send_after(self(), {:scan, tick}, delay)
    %{state | timer: timer, tick: tick, immediate?: delay == 0}
  end
end
