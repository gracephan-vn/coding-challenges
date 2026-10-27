defmodule RideDispatch.Dispatch.ExpirationScheduler do
  @moduledoc """
  One supervised deadline coordinator. Store owns all eligibility and mutations.
  A next-deadline timer plus bounded recovery scans discovers missed wake-ups.
  Owner PIDs pin every discovered command; local timers never restore lost state.
  """
  use GenServer
  require Logger
  alias RideDispatch.Dispatch.{Store, LifecycleLog}

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
           retries: %{},
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
              diagnostics: state.diagnostics
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
      | diagnostics:
          Map.filter(state.diagnostics, fn {id, _} ->
            id == :global_clock or MapSet.member?(present, id)
          end),
        retries: Map.filter(state.retries, fn {id, _} -> MapSet.member?(present, id) end)
    }

    state =
      Enum.reduce(snapshot.invalid_offers, state, fn invalid, acc ->
        diagnose(acc, invalid.offer_id, invalid.reason, invalid.fingerprint, snapshot.now_ms)
      end)

    case Enum.find(
           snapshot.pending,
           &(candidate_at(state, &1, snapshot.now_ms) <= snapshot.now_ms)
         ) do
      nil ->
        delay =
          snapshot.pending
          |> Enum.map(&max(1, candidate_at(state, &1, snapshot.now_ms) - snapshot.now_ms))
          |> Enum.min(fn -> state.interval end)
          |> min(state.interval)

        idle(state, delay)

      candidate ->
        LifecycleLog.emit(
          "scheduler.expiration_check",
          %{offerId: candidate.offer_id, outcome: :checking},
          :debug
        )

        result = invoke(state, candidate.offer_id)

        :telemetry.execute([:ride_dispatch, :expiration, :result], %{}, %{
          server: state.store,
          owner: state.owner,
          scheduler: self(),
          offer_id: candidate.offer_id,
          result: result
        })

        case result do
          {:error, reason} when reason in [:inconsistent_ownership, :invalid_request] ->
            state
            |> diagnose(
              candidate.offer_id,
              reason,
              candidate.fingerprint,
              snapshot.now_ms
            )
            |> schedule(0)

          {:error, :invalid_clock} ->
            state
            |> diagnose(:global_clock, :invalid_clock, nil, snapshot.now_ms)
            |> idle(state.interval)

          {:ok, _} ->
            schedule(%{state | retries: Map.delete(state.retries, candidate.offer_id)}, 0)

          :not_found ->
            schedule(%{state | retries: Map.delete(state.retries, candidate.offer_id)}, 0)

          {:error, {:not_due, deadline}} when is_integer(deadline) ->
            state |> defer(candidate, snapshot.now_ms, deadline) |> schedule(0)

          {:error, reason} when reason in [:uncertain, :owner_unavailable] ->
            state
            |> defer(candidate, snapshot.now_ms, snapshot.now_ms + state.interval)
            |> schedule(0)

          _unexpected_or_retryable ->
            state |> retry_failure(candidate, snapshot.now_ms) |> schedule(0)
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
    do: %{state | owner: nil, monitor: nil, diagnostics: %{}, retries: %{}, last_now: nil}

  defp candidate_at(state, candidate, now) do
    blocked_until =
      case Map.get(state.diagnostics, candidate.offer_id) do
        %{reason: reason, fingerprint: fp, at: at}
        when reason in [:inconsistent_ownership, :invalid_request] and fp == candidate.fingerprint ->
          at + state.reminder

        _ ->
          now
      end

    retry_at =
      case Map.get(state.retries, candidate.offer_id) do
        %{fingerprint: fp, next_at: at} when fp == candidate.fingerprint -> at
        _ -> now
      end

    max(candidate.expires_at_ms, max(blocked_until, retry_at))
  end

  defp invoke(state, id) do
    try do
      state.expire.(state.owner, id)
    rescue
      _technical_failure -> {:error, :retryable}
    catch
      :exit, {:timeout, _call} ->
        # Timeout does not cancel a command. Reconcile against this same owner.
        result =
          try do
            case Store.get_offer(state.owner, id) do
              {:ok, %{status: :pending}} -> {:error, :uncertain}
              {:ok, _closed} -> Store.expire_offer(state.owner, id)
              :not_found -> :not_found
            end
          catch
            :exit, _ -> {:error, :uncertain}
          end

        outcome = if is_tuple(result), do: elem(result, 1), else: result

        LifecycleLog.emit(
          "expiration.timeout_reconciled",
          Map.put(offer_context(state, id), :outcome, outcome),
          :warning
        )

        result

      :exit, _owner_unavailable ->
        {:error, :owner_unavailable}
    end
  end

  defp defer(state, candidate, _now, at) do
    previous = Map.get(state.retries, candidate.offer_id, %{})

    entry = %{
      fingerprint: candidate.fingerprint,
      attempts: Map.get(previous, :attempts, 0),
      next_at: at
    }

    %{state | retries: Map.put(state.retries, candidate.offer_id, entry)}
  end

  defp retry_failure(state, candidate, now) do
    previous = Map.get(state.retries, candidate.offer_id, %{})

    count =
      if Map.get(previous, :fingerprint) == candidate.fingerprint and
           Map.get(previous, :attempts, 0) < 3, do: Map.get(previous, :attempts, 0), else: 0

    attempts = count + 1
    delay = if attempts >= 3, do: state.reminder, else: 1000 * Integer.pow(2, attempts - 1)

    state =
      if attempts >= 3,
        do: diagnose(state, candidate.offer_id, :retry_exhausted, candidate.fingerprint, now),
        else: state

    LifecycleLog.emit(
      "expiration.retry_scheduled",
      Map.merge(
        offer_context(state, candidate.offer_id),
        %{attempts: attempts, retryAtMs: now + delay, outcome: :technical_failure}
      ),
      :warning
    )

    entry = %{fingerprint: candidate.fingerprint, attempts: attempts, next_at: now + delay}
    %{state | retries: Map.put(state.retries, candidate.offer_id, entry)}
  end

  defp diagnose(state, id, reason, fingerprint, now) do
    previous = Map.get(state.diagnostics, id)

    if is_nil(previous) or previous.reason != reason or previous.fingerprint != fingerprint or
         now >= previous.at + state.reminder do
      Logger.warning(
        "offer_expiration offer_id=#{inspect(id)} category=#{reason}",
        [offer_id: id, error_category: reason] ++ Map.to_list(offer_context(state, id))
      )

      entry = %{reason: reason, fingerprint: fingerprint, at: now}
      %{state | diagnostics: Map.put(state.diagnostics, id, entry)}
    else
      state
    end
  end

  # Diagnostic-only read, pinned to the observed owner. Missing/malformed records
  # cannot invent a Ride/Driver identity or interfere with scheduler recovery.
  defp offer_context(_state, :global_clock), do: %{}

  defp offer_context(state, id) do
    case Store.get_offer(state.owner, id) do
      {:ok, %{rideId: ride_id, driverId: driver_id}} ->
        %{offerId: id, rideId: ride_id, driverId: driver_id}

      _ ->
        %{offerId: id}
    end
  catch
    :exit, _ -> %{offerId: id}
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
