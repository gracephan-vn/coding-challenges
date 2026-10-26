defmodule RideDispatch.Dispatch.ExpirationScheduler do
  @moduledoc """
  One supervised deadline coordinator. Store owns all eligibility and mutations.
  A next-deadline timer plus bounded recovery scans discovers missed wake-ups.
  Owner PIDs pin every discovered command; local timers never restore lost state.
  """
  use GenServer
  alias RideDispatch.Dispatch.Store

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def wake(server), do: send(server, :events_available)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :scan_interval_ms, 1000)

    if is_integer(interval) and interval in 1..60_000 do
      {:ok,
       %{
         store: Keyword.fetch!(opts, :store),
         interval: interval,
         subscribe?: Keyword.get(opts, :subscribe?, true),
         expire: Keyword.get(opts, :expire, &Store.expire_offer/2),
         owner: nil,
         monitor: nil,
         timer: nil,
         tick: nil,
         immediate?: false
       }, {:continue, :start}}
    else
      {:stop, :invalid_scan_interval}
    end
  end

  @impl true
  def handle_continue(:start, state), do: {:noreply, schedule(state, 0)}

  @impl true
  def handle_info(:events_available, %{immediate?: true} = state), do: {:noreply, state}
  def handle_info(:events_available, state), do: {:noreply, schedule(state, 0)}

  def handle_info({:scan, tick}, %{tick: tick} = state) do
    {:noreply, scan(%{state | timer: nil, tick: nil, immediate?: false})}
  end

  def handle_info({:scan, _obsolete}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state) do
    {:noreply, schedule(%{state | owner: nil, monitor: nil}, state.interval)}
  end

  def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}

  defp scan(state) do
    try do
      state = connect(state)

      case Store.expiration_schedule(state.owner) do
        {:ok, snapshot} -> scan_snapshot(state, snapshot)
        {:error, :invalid_clock} -> schedule(state, state.interval)
      end
    catch
      :exit, _unavailable_or_timeout -> schedule(state, state.interval)
    end
  end

  defp scan_snapshot(state, snapshot) do
    case Enum.find(snapshot.pending, &(&1.expires_at_ms <= snapshot.now_ms)) do
      nil ->
        delay =
          snapshot.pending
          |> Enum.map(&max(1, &1.expires_at_ms - snapshot.now_ms))
          |> Enum.min(fn -> state.interval end)
          |> min(state.interval)

        :telemetry.execute([:ride_dispatch, :expiration, :idle], %{}, %{
          server: state.store,
          owner: state.owner,
          scheduler: self(),
          delay_ms: delay
        })

        schedule(state, delay)

      candidate ->
        result = state.expire.(state.owner, candidate.offer_id)

        :telemetry.execute([:ride_dispatch, :expiration, :result], %{}, %{
          server: state.store,
          owner: state.owner,
          scheduler: self(),
          offer_id: candidate.offer_id,
          result: result
        })

        delay = if match?({:ok, _}, result) or result == :not_found, do: 0, else: state.interval
        schedule(state, delay)
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

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    tick = make_ref()
    timer = Process.send_after(self(), {:scan, tick}, delay)
    %{state | timer: timer, tick: tick, immediate?: delay == 0}
  end
end
