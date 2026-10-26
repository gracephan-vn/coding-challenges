defmodule RideDispatch.Dispatch.ExpirationScheduler do
  @moduledoc """
  One supervised deadline coordinator. Store owns all eligibility and mutations.
  A next-deadline timer plus bounded recovery scans discovers missed wake-ups.
  Owner PIDs pin every discovered command; local timers never restore lost state.
  """
  use GenServer
  require Logger
  alias RideDispatch.Dispatch.Store

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  def wake(server), do: send(server, :events_available)

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :scan_interval_ms, 1000)
    reminder = Keyword.get(opts, :diagnostic_reminder_ms, 60_000)

    cond do
      not (is_integer(interval) and interval in 1..60_000) ->
        {:stop, :invalid_scan_interval}

      not (is_integer(reminder) and reminder > 0) ->
        {:stop, :invalid_diagnostic_interval}

      true ->
        {:ok,
         %{
           store: Keyword.fetch!(opts, :store),
           interval: interval,
           subscribe?: Keyword.get(opts, :subscribe?, true),
           expire: Keyword.get(opts, :expire, &Store.expire_offer/2),
           reminder: reminder,
           diagnostics: %{},
           last_now: nil,
           owner: nil,
           monitor: nil,
           timer: nil,
           tick: nil,
           immediate?: false
         }, {:continue, :start}}
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
    {:noreply, schedule(clear_owner(state), state.interval)}
  end

  def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}

  defp scan(state) do
    try do
      state = connect(state)

      case Store.expiration_schedule(state.owner) do
        {:ok, snapshot} ->
          state = %{
            state
            | last_now: snapshot.now_ms,
              diagnostics: Map.delete(state.diagnostics, :global_clock)
          }

          scan_snapshot(state, snapshot)

        {:error, :invalid_clock} ->
          state = diagnose(state, :global_clock, :invalid_clock, nil, state.last_now || 0)
          idle(state, state.interval)
      end
    catch
      :exit, _unavailable_or_timeout -> schedule(state, state.interval)
    end
  end

  defp scan_snapshot(state, snapshot) do
    present = MapSet.new(Enum.map(snapshot.pending ++ snapshot.invalid_offers, & &1.offer_id))

    state = %{
      state
      | diagnostics: Map.filter(state.diagnostics, fn {id, _} -> MapSet.member?(present, id) end)
    }

    state =
      Enum.reduce(snapshot.invalid_offers, state, fn invalid, acc ->
        diagnose(acc, invalid.offer_id, invalid.reason, invalid.fingerprint, snapshot.now_ms)
      end)

    candidates = Enum.filter(snapshot.pending, &eligible?(state, &1, snapshot.now_ms))

    case Enum.find(candidates, &(&1.expires_at_ms <= snapshot.now_ms)) do
      nil ->
        delay =
          candidates
          |> Enum.map(&max(1, &1.expires_at_ms - snapshot.now_ms))
          |> Enum.min(fn -> state.interval end)
          |> min(state.interval)

        idle(state, delay)

      candidate ->
        result = state.expire.(state.owner, candidate.offer_id)

        :telemetry.execute([:ride_dispatch, :expiration, :result], %{}, %{
          server: state.store,
          owner: state.owner,
          scheduler: self(),
          offer_id: candidate.offer_id,
          result: result
        })

        case result do
          {:error, :inconsistent_ownership} ->
            state
            |> diagnose(
              candidate.offer_id,
              :inconsistent_ownership,
              candidate.fingerprint,
              snapshot.now_ms
            )
            |> schedule(0)

          {:error, :invalid_clock} ->
            state
            |> diagnose(:global_clock, :invalid_clock, nil, snapshot.now_ms)
            |> idle(state.interval)

          _ ->
            delay =
              if match?({:ok, _}, result) or result == :not_found, do: 0, else: state.interval

            schedule(state, delay)
        end
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
      %{clear_owner(state) | owner: owner, monitor: Process.monitor(owner)}
    end
  end

  defp clear_owner(state),
    do: %{state | owner: nil, monitor: nil, diagnostics: %{}, last_now: nil}

  defp eligible?(state, candidate, now) do
    case Map.get(state.diagnostics, candidate.offer_id) do
      %{reason: :inconsistent_ownership, fingerprint: fp, at: at}
      when fp == candidate.fingerprint ->
        now >= at + state.reminder

      _ ->
        true
    end
  end

  defp diagnose(state, id, reason, fingerprint, now) do
    previous = Map.get(state.diagnostics, id)

    if is_nil(previous) or previous.reason != reason or previous.fingerprint != fingerprint or
         now >= previous.at + state.reminder do
      Logger.warning("offer_expiration offer_id=#{inspect(id)} category=#{reason}",
        offer_id: id,
        error_category: reason
      )

      entry = %{reason: reason, fingerprint: fingerprint, at: now}
      %{state | diagnostics: Map.put(state.diagnostics, id, entry)}
    else
      state
    end
  end

  defp idle(state, delay) do
    :telemetry.execute([:ride_dispatch, :expiration, :idle], %{}, %{
      server: state.store,
      owner: state.owner,
      scheduler: self(),
      delay_ms: delay
    })

    schedule(state, delay)
  end

  defp schedule(state, delay) do
    if state.timer, do: Process.cancel_timer(state.timer)
    tick = make_ref()
    timer = Process.send_after(self(), {:scan, tick}, delay)
    %{state | timer: timer, tick: tick, immediate?: delay == 0}
  end
end
