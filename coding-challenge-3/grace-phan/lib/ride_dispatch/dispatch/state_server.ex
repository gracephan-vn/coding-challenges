defmodule RideDispatch.Dispatch.StateServer do
  @moduledoc false
  use GenServer

  alias RideDispatch.Rides.StateMachine, as: RideStateMachine
  alias RideDispatch.Rides.Request
  alias RideDispatch.Location
  alias RideDispatch.Drivers.StateMachine
  alias RideDispatch.Dispatch.Matcher
  alias RideDispatch.Dispatch.Offer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)
    radius = Keyword.get(opts, :matching_radius_km, 2.0)
    timeout = Keyword.get(opts, :offer_timeout_ms, 30_000)

    with :ok <- validate_policy(radius, timeout),
         {:ok, _now} <- read_clock(clock),
         {:ok, drivers} <- seed_drivers(Keyword.get(opts, :drivers, [])),
         {:ok, passengers} <- seed_passengers(Keyword.get(opts, :passengers, [])) do
      {:ok,
       %{
         drivers: drivers,
         passengers: passengers,
         rides: %{},
         offers: %{},
         idempotency: %{},
         pending_events: %{},
         clock: clock,
         matching_radius_km: radius,
         offer_timeout_ms: timeout,
         event_subscribers: %{}
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue({:observe, command, result, previous}, state) do
    # OTP has installed state before invoking this continuation. Logging cannot
    # roll back or repeat the business command, and uses no external publisher.
    try do
      RideDispatch.Dispatch.LifecycleLog.committed(command, result, previous, state)
    rescue
      _logging_failure ->
        # Observability must never turn a completed command into owner/state loss.
        RideDispatch.Dispatch.LifecycleLog.emit(
          "observability.failed",
          %{outcome: :log_projection_failed},
          :error
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:observed, command}, from, state) do
    {:reply, result, updated} = handle_call(command, from, state)
    {:reply, result, updated, {:continue, {:observe, command, result, state}}}
  end

  def handle_call(:expiration_schedule, _from, state) do
    result =
      with {:ok, now} <- read_clock(state.clock) do
        {pending, invalid} =
          Enum.reduce(state.offers, {[], []}, fn {id, offer}, {pending, invalid} ->
            fingerprint = :erlang.phash2(offer)

            case scheduling_offer(offer, id, state) do
              :ok ->
                if offer.status == :pending,
                  do:
                    {[
                       %{
                         offer_id: id,
                         expires_at_ms: offer.expires_at_ms,
                         fingerprint: fingerprint
                       }
                       | pending
                     ], invalid},
                  else: {pending, invalid}

              {:error, reason} ->
                {pending, [%{offer_id: id, reason: reason, fingerprint: fingerprint} | invalid]}
            end
          end)

        {:ok,
         %{
           now_ms: now,
           pending: Enum.sort_by(pending, &{&1.expires_at_ms, &1.offer_id}),
           invalid_offers: Enum.sort_by(invalid, & &1.offer_id)
         }}
      end

    {:reply, result, state}
  end

  def handle_call({:expire_offer, id}, _from, state) do
    with :ok <- acceptance_identifiers(id, id),
         {:ok, offer} <- Map.fetch(state.offers, id),
         :ok <- record_identity(offer, id),
         {:ok, ride} <- expiration_record(state.rides, Map.get(offer, :rideId)),
         {:ok, driver} <- expiration_record(state.drivers, Map.get(offer, :driverId)),
         :ok <- expiration_eligibility(ride, driver, offer, state),
         :ok <- offer_deadline(offer),
         {:ok, now} <- rejection_time(offer, state.clock) do
      if Offer.expired?(offer, now),
        do: expire_pending(ride, driver, offer, now, state),
        else: {:reply, {:error, {:not_due, offer.expires_at_ms}}, state}
    else
      {:done, outcome} -> {:reply, {:ok, outcome}, state}
      :error -> {:reply, :not_found, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:terminal_ride, operation, id}, _from, state) do
    with :ok <- acceptance_identifiers(id, id),
         {:ok, ride} <- Map.fetch(state.rides, id),
         :ok <- record_identity(ride, id),
         true <-
           ride.status in [
             :requested,
             :matching,
             :driver_assigned,
             :driver_accepted,
             :cancelled,
             :completed
           ],
         true <-
           ride.status in [:cancelled, :completed] or not Map.has_key?(ride, :terminal_receipt) do
      cond do
        ride.status in [:cancelled, :completed] ->
          if terminal_valid?(ride, state) do
            receipt = ride.terminal_receipt

            result =
              if receipt.operation == operation,
                do: {:ok, receipt.original_result},
                else: {:error, :invalid_transition}

            {:reply, result, state}
          else
            {:reply, {:error, :inconsistent_ownership}, state}
          end

        operation == :cancel and ride.status in [:requested, :matching] ->
          if is_nil(Map.get(ride, :assignedDriverId)) and is_nil(Map.get(ride, :currentOfferId)) and
               not Enum.any?(active_offers(state), &(Map.get(&1, :rideId) == id)) and
               retained_history_valid?(ride, nil, state) do
            install_terminal(ride, nil, nil, operation, state)
          else
            {:reply, {:error, :inconsistent_ownership}, state}
          end

        (operation == :cancel and ride.status in [:driver_assigned, :driver_accepted]) or
            (operation == :complete and ride.status == :driver_accepted) ->
          with {:ok, offer} <- expiration_record(state.offers, Map.get(ride, :currentOfferId)),
               {:ok, driver} <- expiration_record(state.drivers, Map.get(ride, :assignedDriverId)),
               true <- consistent_assignment?(ride, state),
               true <- expiration_unique?(ride, driver, offer, state),
               :ok <- offer_deadline(offer),
               :ok <- exclusive_acceptance_history(ride, offer, state),
               true <- terminal_source_evidence?(ride.status, offer, ride),
               true <- retained_history_valid?(ride, offer.id, state) do
            install_terminal(ride, driver, offer, operation, state)
          else
            _ -> {:reply, {:error, :inconsistent_ownership}, state}
          end

        true ->
          {:reply, {:error, :invalid_transition}, state}
      end
    else
      :error -> {:reply, :not_found, state}
      false -> {:reply, {:error, :inconsistent_ownership}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:reject_offer, ride_id, driver_id}, _from, state) do
    with :ok <- acceptance_identifiers(ride_id, driver_id),
         {:ok, ride} <- Map.fetch(state.rides, ride_id),
         {:ok, driver} <- Map.fetch(state.drivers, driver_id),
         :ok <- record_identity(ride, ride_id),
         :ok <- record_identity(driver, driver_id),
         :ok <- rejection_ownership_records(state),
         {:ok, offer} <- resolve_rejection_offer(ride, driver, state) do
      reject_pending(ride, driver, offer, state)
    else
      {:replay, result} -> {:reply, {:ok, result}, state}
      :error -> {:reply, :not_found, state}
      :not_found -> {:reply, :not_found, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call({:accept_offer, ride_id, driver_id}, _from, state) do
    with :ok <- acceptance_identifiers(ride_id, driver_id),
         {:ok, ride} <- Map.fetch(state.rides, ride_id),
         {:ok, driver} <- Map.fetch(state.drivers, driver_id),
         :ok <- record_identity(ride, ride_id),
         :ok <- record_identity(driver, driver_id),
         {:ok, offer} <- resolve_acceptance_offer(ride, driver, state) do
      accept_pending(ride, driver, offer, state)
    else
      {:replay, result} -> {:reply, {:ok, result}, state}
      :error -> {:reply, :not_found, state}
      :not_found -> {:reply, :not_found, state}
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  def handle_call(:list_offers, _from, state) do
    {:reply, state.offers |> Map.values() |> Enum.sort_by(& &1.id), state}
  end

  def handle_call({:get_offer, id}, _from, state) do
    {:reply, Map.fetch(state.offers, id) |> event_result(), state}
  end

  def handle_call({:get_driver, id}, _from, state) do
    result =
      case Map.fetch(state.drivers, id) do
        {:ok, driver} -> {:ok, driver}
        :error -> :not_found
      end

    {:reply, result, state}
  end

  def handle_call(:list_available_drivers, _from, state) do
    drivers =
      state.drivers
      |> Map.values()
      |> Enum.filter(&(&1.status == :available))
      |> Enum.sort_by(& &1.id)

    {:reply, drivers, state}
  end

  def handle_call({:update_driver_location, id, location}, _from, state) do
    case Map.fetch(state.drivers, id) do
      :error ->
        {:reply, :not_found, state}

      {:ok, driver} ->
        if Location.valid?(location) do
          updated = %{driver | latitude: location.latitude, longitude: location.longitude}
          new_state = %{state | drivers: Map.put(state.drivers, id, updated)}
          {:reply, {:ok, updated}, new_state}
        else
          {:reply, {:error, :invalid_coordinates}, state}
        end
    end
  end

  def handle_call({:set_driver_availability, id, available?}, _from, state) do
    case Map.fetch(state.drivers, id) do
      :error ->
        {:reply, :not_found, state}

      {:ok, driver} when is_boolean(available?) ->
        action = if available?, do: :enable_availability, else: :disable_availability

        case StateMachine.transition(driver, action) do
          {:ok, updated} ->
            new_state = %{state | drivers: Map.put(state.drivers, id, updated)}
            {:reply, {:ok, updated}, new_state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end

      {:ok, _driver} ->
        {:reply, {:error, :invalid_availability}, state}
    end
  end

  def handle_call({:get_ride, id}, _from, state) do
    {:reply, Map.get(state.rides, id, :not_found) |> ride_result(), state}
  end

  def handle_call({:create_ride, key, body}, _from, state) do
    with true <- Request.valid_key?(key),
         {:ok, canonical} <- Request.normalize(body) do
      case Map.fetch(state.idempotency, key) do
        {:ok, %{canonical_request: ^canonical, original_result: result}} ->
          {:reply, result, state}

        {:ok, _different} ->
          {:reply, {:error, :idempotency_conflict}, state}

        :error ->
          create_ride(state, key, canonical)
      end
    else
      false -> {:reply, {:error, :invalid_idempotency_key}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call(:list_events, _from, state) do
    {:reply, state.pending_events |> Map.values() |> Enum.sort_by(& &1.eventId), state}
  end

  def handle_call({:get_event, id}, _from, state) do
    {:reply, Map.fetch(state.pending_events, id) |> event_result(), state}
  end

  def handle_call(:list_actionable_events, _from, state) do
    events =
      case read_clock(state.clock) do
        {:ok, now} ->
          state.pending_events
          |> Map.values()
          |> Enum.filter(&(supported_pending?(&1) and eligible?(&1, now)))
          |> Enum.sort_by(& &1.eventId)

        {:error, :invalid_clock} ->
          []
      end

    {:reply, events, state}
  end

  def handle_call(:next_event_delay, _from, state) do
    delay =
      case read_clock(state.clock) do
        {:ok, now} ->
          state.pending_events
          |> Map.values()
          |> Enum.filter(&supported_pending?/1)
          |> Enum.map(&max(0, (Map.get(&1, :next_attempt_at) || now) - now))
          |> Enum.min(fn -> nil end)

        {:error, :invalid_clock} ->
          nil
      end

    {:reply, delay, state}
  end

  def handle_call(:subscribe_events, {pid, _tag}, state) do
    subscribers =
      if Map.has_key?(state.event_subscribers, pid),
        do: state.event_subscribers,
        else: Map.put(state.event_subscribers, pid, Process.monitor(pid))

    {:reply, {:ok, self()}, %{state | event_subscribers: subscribers}}
  end

  def handle_call({:process_event, id}, _from, state) do
    case Map.fetch(state.pending_events, id) do
      :error ->
        {:reply, :not_found, state}

      {:ok, %{status: :processed}} ->
        {:reply, {:ok, :already_processed}, state}

      {:ok, %{status: :failed}} ->
        {:reply, {:error, :failed}, state}

      {:ok, event} ->
        cond do
          not supported_pending?(event) ->
            {:reply, {:error, :unsupported_event}, state}

          not valid_event?(event, id) ->
            permanent_failure(state, Map.put(event, :eventId, id), :invalid_event)

          true ->
            with {:ok, now} <- read_clock(state.clock) do
              if eligible?(event, now) do
                case event.type do
                  :ride_created -> process_ride_created(event, state)
                  :dispatch_requested -> process_dispatch_requested(event, state)
                end
              else
                {:reply, {:error, {:retry_at, event.next_attempt_at}}, state}
              end
            else
              {:error, :invalid_clock} = error -> {:reply, error, state}
            end
        end
    end
  end

  def handle_call({:fail_event, _id, version, :processing_failed}, _from, state)
      when not is_integer(version) or version < 0 do
    {:reply, {:error, :invalid_attempt}, state}
  end

  def handle_call({:fail_event, id, version, :processing_failed}, _from, state) do
    with {:ok, now} <- read_clock(state.clock) do
      case Map.fetch(state.pending_events, id) do
        :error ->
          {:reply, :not_found, state}

        {:ok, event} ->
          cond do
            not supported_pending?(event) ->
              {:reply, {:error, :not_actionable}, state}

            Map.get(event, :attempts, 0) != version ->
              {:reply, {:error, :stale_attempt}, state}

            not eligible?(event, now) ->
              {:reply, {:error, {:retry_at, event.next_attempt_at}}, state}

            true ->
              attempts = version + 1
              failed = attempts >= 3
              at = now + 1000 * Integer.pow(2, attempts - 1)

              updated =
                Map.merge(event, %{
                  attempts: attempts,
                  status: if(failed, do: :failed, else: :pending),
                  next_attempt_at: if(failed, do: nil, else: at),
                  last_error: :processing_failed
                })

              result = if failed, do: {:error, :failed}, else: {:error, {:retry_at, at}}
              {:reply, result, put_event(state, updated)}
          end
      end
    else
      {:error, :invalid_clock} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_cast(:notify_events, state) do
    for pid <- Map.keys(state.event_subscribers), do: send(pid, :events_available)
    {:noreply, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    subscribers =
      if state.event_subscribers[pid] == ref,
        do: Map.delete(state.event_subscribers, pid),
        else: state.event_subscribers

    {:noreply, %{state | event_subscribers: subscribers}}
  end

  defp acceptance_identifiers(ride_id, driver_id) do
    if Enum.all?([ride_id, driver_id], &(is_binary(&1) and &1 != "" and String.valid?(&1))),
      do: :ok,
      else: {:error, :invalid_request}
  end

  # Receipt predicates never depend on a historical Driver remaining AVAILABLE.
  defp terminal_shape?(ride, state) do
    case Map.get(ride, :terminal_receipt) do
      %{
        operation: operation,
        rideId: id,
        source_status: source,
        offerId: offer_id,
        driverId: driver_id,
        original_result: result
      } ->
        target = %{cancel: :cancelled, complete: :completed}[operation]

        eligible =
          (operation == :cancel and
             source in [:requested, :matching, :driver_assigned, :driver_accepted]) or
            (operation == :complete and source == :driver_accepted)

        id == ride.id and Map.get(state.rides, id) == ride and eligible and ride.status == target and
          Map.fetch(ride, :assignedDriverId) == {:ok, nil} and
          Map.fetch(ride, :currentOfferId) == {:ok, nil} and
          is_map(result) and result == Map.delete(ride, :terminal_receipt) and
          terminal_history?(ride, source, offer_id, driver_id, state)

      _ ->
        false
    end
  end

  defp terminal_valid?(ride, state) do
    terminal_shape?(ride, state) and terminal_unreferenced?(ride, state) and
      retained_history_valid?(ride, ride.terminal_receipt.offerId, state) and
      not Enum.any?(active_offers(state), &(Map.get(&1, :rideId) == ride.id)) and
      released_driver_consistent?(ride.terminal_receipt.driverId, state)
  end

  defp retained_history_valid?(ride, current_id, state) do
    Enum.all?(state.offers, fn {key, offer} ->
      if is_map(offer) and Map.get(offer, :rideId) == ride.id and key != current_id do
        record_identity(offer, key) == :ok and
          case Map.get(offer, :status) do
            :rejected -> rejection_receipt?(offer, ride, state)
            :expired -> expiration_receipt?(offer, state)
            _ -> false
          end
      else
        true
      end
    end)
  end

  defp terminal_unreferenced?(ride, state) do
    id = ride.terminal_receipt.offerId

    Enum.all?(state.rides, fn {key, other} ->
      key == ride.id or is_nil(id) or
        (is_map(other) and Map.get(other, :currentOfferId) != id and
           not match?(%{terminal_receipt: %{offerId: ^id}}, other))
    end)
  end

  defp released_driver_consistent?(nil, _state), do: true

  defp released_driver_consistent?(id, state) do
    with {:ok, driver} <- expiration_record(state.drivers, id) do
      rides = Enum.filter(active_rides(state), &(Map.get(&1, :assignedDriverId) == id))
      offers = Enum.filter(active_offers(state), &(Map.get(&1, :driverId) == id))

      case {driver.status, rides, offers} do
        {status, [], []} when status in [:available, :offline] ->
          true

        {status, [ride], [offer]} when status in [:offered, :busy] ->
          record_identity(ride, Map.get(ride, :id)) == :ok and
            Map.get(state.rides, ride.id) == ride and
            Map.get(state.offers, Map.get(offer, :id)) == offer and
            consistent_assignment?(ride, state) and offer_deadline(offer) == :ok and
            terminal_source_evidence?(ride.status, offer, ride) and
            exclusive_acceptance_history(ride, offer, state) == :ok

        _ ->
          false
      end
    else
      _ -> false
    end
  end

  # Nonrecursive linkage proof for ownership scans. A terminal status alone never
  # releases a known ownership reference; full replay adds exclusivity checks.
  defp terminal_offer_closed?(offer, state) do
    with %{id: id, rideId: ride_id} <- offer,
         {:ok, ride} <- expiration_record(state.rides, ride_id) do
      Map.get(state.offers, id) == offer and terminal_shape?(ride, state) and
        terminal_unreferenced?(ride, state) and ride.terminal_receipt.offerId == id and
        retained_history_valid?(ride, id, state)
    else
      _ -> false
    end
  end

  defp offer_active?(offer, state) do
    is_map(offer) and
      case Map.get(offer, :status) do
        status when status in [:rejected, :expired] -> false
        status when status in [:cancelled, :completed] -> not terminal_offer_closed?(offer, state)
        _ -> true
      end
  end

  defp ride_active?(ride, state) do
    is_map(ride) and
      case Map.get(ride, :status) do
        status when status in [:requested, :matching] -> false
        status when status in [:cancelled, :completed] -> not terminal_shape?(ride, state)
        _ -> true
      end
  end

  defp terminal_history?(_ride, source, nil, nil, _state) when source in [:requested, :matching],
    do: true

  defp terminal_history?(ride, source, offer_id, driver_id, state)
       when source in [:driver_assigned, :driver_accepted] do
    with {:ok, offer} <- expiration_record(state.offers, offer_id),
         {:ok, _driver} <- expiration_record(state.drivers, driver_id) do
      Map.get(offer, :rideId) == ride.id and Map.get(offer, :driverId) == driver_id and
        offer.status == ride.status and
        offer_deadline(offer) == :ok and terminal_source_evidence?(source, offer, ride)
    else
      _ -> false
    end
  end

  defp terminal_history?(_, _, _, _, _), do: false

  defp terminal_source_evidence?(:driver_accepted, offer, ride),
    do: acceptance_receipt?(offer, ride)

  defp terminal_source_evidence?(:driver_assigned, offer, _ride),
    do:
      not Enum.any?(
        [:accepted_at_ms, :acceptance_result, :rejection_receipt, :expiration_receipt],
        &Map.has_key?(offer, &1)
      )

  defp install_terminal(ride, driver, offer, operation, state) do
    action = if operation == :cancel, do: :cancel_ride, else: :complete_ride
    {:ok, terminal} = RideStateMachine.transition(ride, action)
    result = Map.merge(terminal, %{assignedDriverId: nil, currentOfferId: nil})

    receipt = %{
      operation: operation,
      rideId: ride.id,
      source_status: ride.status,
      offerId: if(offer, do: offer.id),
      driverId: if(driver, do: driver.id),
      original_result: result
    }

    stored = Map.put(result, :terminal_receipt, receipt)
    updated = %{state | rides: Map.put(state.rides, ride.id, stored)}

    updated =
      if driver do
        release =
          cond do
            operation == :complete -> :complete_ride
            ride.status == :driver_accepted -> :cancel_accepted_ride
            true -> :cancel_offer
          end

        {:ok, available} = StateMachine.transition(driver, release)

        %{
          updated
          | drivers: Map.put(state.drivers, driver.id, available),
            offers: Map.put(state.offers, offer.id, %{offer | status: result.status})
        }
      else
        updated
      end

    {:reply, {:ok, result}, updated}
  end

  defp reject_pending(ride, driver, offer, state) do
    with :ok <- offer_deadline(offer),
         {:ok, now} <- rejection_time(offer, state.clock),
         {:ok, matching} <- RideStateMachine.transition(ride, :reject_offer),
         {:ok, available} <- StateMachine.transition(driver, :reject_offer) do
      matching = Map.merge(matching, %{assignedDriverId: nil, currentOfferId: nil})
      event_id = "redispatch-" <> offer.id

      receipt = %{
        offerId: offer.id,
        rideId: ride.id,
        driverId: driver.id,
        rejected_at_ms: now,
        redispatch_event_id: event_id,
        original_result: matching
      }

      rejected = Map.merge(offer, %{status: :rejected, rejection_receipt: receipt})
      event = %{eventId: event_id, rideId: ride.id, type: :dispatch_requested, status: :pending}

      updated = %{
        state
        | rides: Map.put(state.rides, ride.id, matching),
          drivers: Map.put(state.drivers, driver.id, available),
          offers: Map.put(state.offers, offer.id, rejected),
          pending_events: Map.put(state.pending_events, event_id, event)
      }

      {:reply, {:ok, matching}, updated}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp expiration_record(records, id) do
    with {:ok, record} <- Map.fetch(records, id), :ok <- record_identity(record, id) do
      {:ok, record}
    else
      _ -> {:error, :inconsistent_ownership}
    end
  end

  defp scheduling_offer(offer, id, state) do
    if record_identity(offer, id) == :ok and
         Map.get(offer, :status) in [
           :pending,
           :accepted,
           :rejected,
           :expired,
           :cancelled,
           :completed
         ] and
         Enum.all?([:rideId, :driverId], fn field ->
           value = Map.get(offer, field)
           is_binary(value) and value != "" and String.valid?(value)
         end) do
      cond do
        offer_deadline(offer) != :ok -> {:error, :invalid_deadline}
        not scheduling_evidence?(offer, state) -> {:error, :invalid_evidence}
        true -> :ok
      end
    else
      {:error, :invalid_identity}
    end
  end

  defp scheduling_evidence?(%{status: :pending} = offer, _state),
    do:
      not Enum.any?(
        [:accepted_at_ms, :acceptance_result, :rejection_receipt, :expiration_receipt],
        &Map.has_key?(offer, &1)
      )

  defp scheduling_evidence?(%{status: :expired} = offer, state),
    do: expiration_receipt?(offer, state)

  defp scheduling_evidence?(%{status: status} = offer, state)
       when status in [:accepted, :rejected] do
    with {:ok, ride} <- expiration_record(state.rides, offer.rideId) do
      if status == :accepted,
        do: acceptance_receipt?(offer, ride),
        else: rejection_receipt?(offer, ride, state)
    else
      _ -> false
    end
  end

  # Closed terminal Offers require their Ride-bound receipt and exact history.
  defp scheduling_evidence?(terminal_offer, state),
    do:
      terminal_offer_closed?(terminal_offer, state) and
        terminal_valid?(state.rides[terminal_offer.rideId], state)

  defp expiration_pending(ride, driver, offer, state) do
    if ride.status == :driver_assigned and driver.status == :offered and offer.status == :pending and
         Map.get(ride, :currentOfferId) == offer.id and
         Map.get(ride, :assignedDriverId) == driver.id and
         not Enum.any?(
           [:accepted_at_ms, :acceptance_result, :rejection_receipt, :expiration_receipt],
           &Map.has_key?(offer, &1)
         ) and
         expiration_unique?(ride, driver, offer, state) and
         exclusive_acceptance_history(ride, offer, state) == :ok and
         not Map.has_key?(state.pending_events, "redispatch-expired-" <> offer.id),
       do: :ok,
       else: {:error, :inconsistent_ownership}
  end

  defp expiration_eligibility(ride, driver, %{status: :pending} = offer, state),
    do: expiration_pending(ride, driver, offer, state)

  defp expiration_eligibility(ride, _driver, offer, state) do
    valid_history? = expiration_ride_consistent?(ride, state)

    case offer.status do
      status when status in [:cancelled, :completed] ->
        if terminal_valid?(ride, state) and terminal_offer_closed?(offer, state),
          do: {:done, :ignored},
          else: {:error, :inconsistent_ownership}

      :expired ->
        if valid_history? and expiration_receipt?(offer, state) and
             expiration_unreferenced?(offer, state),
           do: {:done, :already_expired},
           else: {:error, :inconsistent_ownership}

      :accepted ->
        if valid_history? and acceptance_receipt?(offer, ride) and
             Map.get(ride, :currentOfferId) == offer.id and ride.status == :driver_accepted,
           do: {:done, :ignored},
           else: {:error, :inconsistent_ownership}

      :rejected ->
        if valid_history? and rejection_receipt?(offer, ride, state) and
             expiration_unreferenced?(offer, state),
           do: {:done, :ignored},
           else: {:error, :inconsistent_ownership}

      _ ->
        {:error, :inconsistent_ownership}
    end
  end

  defp expiration_receipt?(%{status: :expired, expiration_receipt: receipt} = offer, state)
       when is_map(receipt) do
    id = "redispatch-expired-" <> offer.id
    event = Map.get(state.pending_events, id)
    at = Map.get(receipt, :expired_at_ms)

    offer_deadline(offer) == :ok and is_integer(at) and at >= offer.expires_at_ms and
      not Enum.any?(
        [:accepted_at_ms, :acceptance_result, :rejection_receipt],
        &Map.has_key?(offer, &1)
      ) and
      Map.get(receipt, :offerId) == offer.id and Map.get(receipt, :rideId) == offer.rideId and
      Map.get(receipt, :driverId) == offer.driverId and
      Map.get(receipt, :redispatch_event_id) == id and
      is_map(event) and Map.get(event, :eventId) == id and Map.get(event, :rideId) == offer.rideId and
      Map.get(event, :type) == :dispatch_requested and
      Map.get(event, :status) in [:pending, :processed, :failed]
  end

  defp expiration_receipt?(_offer, _state), do: false

  defp expiration_unreferenced?(offer, state),
    do:
      not Enum.any?(state.rides, fn {_, ride} ->
        is_map(ride) and Map.get(ride, :currentOfferId) == offer.id
      end)

  defp expiration_ride_consistent?(%{status: status} = ride, state)
       when status in [:completed, :cancelled], do: terminal_valid?(ride, state)

  defp expiration_ride_consistent?(%{status: :matching} = ride, state) do
    is_nil(Map.get(ride, :currentOfferId)) and is_nil(Map.get(ride, :assignedDriverId)) and
      not Enum.any?(active_offers(state), &(Map.get(&1, :rideId) == ride.id))
  end

  defp expiration_ride_consistent?(%{status: status} = ride, state)
       when status in [:driver_assigned, :driver_accepted] do
    with :ok <- current_offer_link(ride, state),
         {:ok, offer} <- expiration_record(state.offers, Map.get(ride, :currentOfferId)),
         {:ok, driver} <- expiration_record(state.drivers, Map.get(ride, :assignedDriverId)) do
      case {status, driver.status, offer.status} do
        {:driver_assigned, :offered, :pending} ->
          expiration_pending(ride, driver, offer, state) == :ok

        {:driver_accepted, :busy, :accepted} ->
          acceptance_receipt?(offer, ride) and expiration_unique?(ride, driver, offer, state) and
            exclusive_acceptance_history(ride, offer, state) == :ok

        _ ->
          false
      end
    else
      _ -> false
    end
  end

  defp expiration_ride_consistent?(_ride, _state), do: false

  # Unrelated malformed records are diagnosed by scheduling discovery. Records
  # referencing this Ride/Driver must still prove exclusive ownership.
  defp expiration_unique?(ride, driver, offer, state) do
    Enum.all?(state.offers, fn {key, other} ->
      key == offer.id or
        not (offer_active?(other, state) and
               (Map.get(other, :rideId) == ride.id or Map.get(other, :driverId) == driver.id))
    end) and
      Enum.all?(state.rides, fn {key, other} ->
        key == ride.id or
          not (is_map(other) and
                 (Map.get(other, :currentOfferId) == offer.id or
                    (ride_active?(other, state) and Map.get(other, :assignedDriverId) == driver.id)))
      end)
  end

  defp expire_pending(ride, driver, offer, now, state) do
    with {:ok, matching} <- RideStateMachine.transition(ride, :expire_offer),
         {:ok, available} <- StateMachine.transition(driver, :expire_offer) do
      matching = Map.merge(matching, %{assignedDriverId: nil, currentOfferId: nil})
      id = "redispatch-expired-" <> offer.id

      receipt = %{
        offerId: offer.id,
        rideId: ride.id,
        driverId: driver.id,
        expired_at_ms: now,
        redispatch_event_id: id
      }

      expired = Map.merge(offer, %{status: :expired, expiration_receipt: receipt})
      event = %{eventId: id, rideId: ride.id, type: :dispatch_requested, status: :pending}

      updated = %{
        state
        | rides: Map.put(state.rides, ride.id, matching),
          drivers: Map.put(state.drivers, driver.id, available),
          offers: Map.put(state.offers, offer.id, expired),
          pending_events: Map.put(state.pending_events, id, event)
      }

      {:reply, {:ok, :expired}, updated}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp resolve_rejection_offer(ride, driver, state) do
    history =
      for {key, %{rideId: ride_id, driverId: driver_id} = offer} <- state.offers,
          ride_id == ride.id and driver_id == driver.id,
          do: {key, offer}

    case history do
      [_, _ | _] ->
        {:error, :ambiguous_offer}

      _ ->
        with :ok <- current_offer_link(ride, state) do
          case history do
            [] ->
              if is_nil(Map.get(ride, :currentOfferId)),
                do: :not_found,
                else: {:error, :wrong_driver}

            [{key, offer}] ->
              with :ok <- record_identity(offer, key) do
                cond do
                  offer.status == :rejected or Map.has_key?(offer, :rejection_receipt) ->
                    replay_rejection(ride, offer, state)

                  offer.id != Map.get(ride, :currentOfferId) ->
                    {:error, :invalid_transition}

                  offer.status == :accepted ->
                    if acceptance_receipt?(offer, ride) and consistent_assignment?(ride, state),
                      do: {:error, :invalid_transition},
                      else: {:error, :inconsistent_ownership}

                  offer.status != :pending or not consistent_assignment?(ride, state) ->
                    {:error, :inconsistent_ownership}

                  Map.has_key?(offer, :accepted_at_ms) or Map.has_key?(offer, :acceptance_result) or
                    Map.has_key?(offer, :expiration_receipt) or
                    Map.has_key?(offer, :rejection_receipt) or
                      Map.has_key?(state.pending_events, "redispatch-" <> offer.id) ->
                    {:error, :inconsistent_ownership}

                  true ->
                    with :ok <- exclusive_acceptance_history(ride, offer, state), do: {:ok, offer}
                end
              end
          end
        end
    end
  end

  defp rejection_ownership_records(state) do
    rides_valid? =
      Enum.all?(state.rides, fn {key, ride} ->
        record_identity(ride, key) == :ok and
          ride.status in [
            :requested,
            :matching,
            :driver_assigned,
            :driver_accepted,
            :cancelled,
            :completed
          ] and
          Map.has_key?(ride, :assignedDriverId)
      end)

    offers_valid? =
      Enum.all?(state.offers, fn {key, offer} ->
        record_identity(offer, key) == :ok and
          offer.status in [:pending, :accepted, :rejected, :expired, :cancelled, :completed] and
          Enum.all?([:rideId, :driverId], fn field ->
            id = Map.get(offer, field)
            is_binary(id) and id != "" and String.valid?(id)
          end)
      end)

    if rides_valid? and offers_valid?, do: :ok, else: {:error, :inconsistent_ownership}
  end

  defp rejection_time(offer, clock) do
    with {:ok, now} <- read_clock(clock) do
      if now >= offer.created_at_ms, do: {:ok, now}, else: {:error, :invalid_clock}
    end
  end

  defp replay_rejection(ride, offer, state) do
    valid_current? =
      case ride.status do
        status when status in [:driver_assigned, :driver_accepted] ->
          consistent_assignment?(ride, state)

        :matching ->
          is_nil(Map.get(ride, :assignedDriverId)) and is_nil(Map.get(ride, :currentOfferId)) and
            not Enum.any?(active_offers(state), &(Map.get(&1, :rideId) == ride.id))

        status when status in [:cancelled, :completed] ->
          terminal_valid?(ride, state)

        _ ->
          false
      end

    if valid_current? and rejection_receipt?(offer, ride, state),
      do: {:replay, offer.rejection_receipt.original_result},
      else: {:error, :inconsistent_ownership}
  end

  defp rejection_receipt?(%{status: :rejected, rejection_receipt: receipt} = offer, ride, state)
       when is_map(receipt) do
    event_id = "redispatch-" <> offer.id
    event = Map.get(state.pending_events, event_id)
    result = Map.get(receipt, :original_result)
    at = Map.get(receipt, :rejected_at_ms)

    offer_deadline(offer) == :ok and is_integer(at) and at >= offer.created_at_ms and
      not Map.has_key?(offer, :expiration_receipt) and
      not Map.has_key?(offer, :accepted_at_ms) and not Map.has_key?(offer, :acceptance_result) and
      Map.get(receipt, :offerId) == offer.id and Map.get(receipt, :rideId) == offer.rideId and
      Map.get(receipt, :driverId) == offer.driverId and
      Map.get(receipt, :redispatch_event_id) == event_id and
      is_map(event) and Map.get(event, :eventId) == event_id and
      Map.get(event, :rideId) == ride.id and Map.get(event, :type) == :dispatch_requested and
      Map.get(event, :status) in [:pending, :processed, :failed] and
      is_map(result) and Map.get(result, :status) == :matching and
      Map.fetch(result, :assignedDriverId) == {:ok, nil} and
      Map.fetch(result, :currentOfferId) == {:ok, nil} and
      Enum.all?(
        [:id, :passengerId, :pickup, :destination],
        &(Map.has_key?(result, &1) and Map.fetch(result, &1) == Map.fetch(ride, &1))
      )
  end

  defp rejection_receipt?(_offer, _ride, _state), do: false

  defp record_identity(%{id: id, status: _status}, id) when is_binary(id) and id != "" do
    if String.valid?(id), do: :ok, else: {:error, :inconsistent_ownership}
  end

  defp record_identity(_record, _id), do: {:error, :inconsistent_ownership}

  defp resolve_acceptance_offer(ride, driver, state) do
    history =
      for {key, %{rideId: ride_id, driverId: driver_id} = offer} <- state.offers,
          ride_id == ride.id and driver_id == driver.id,
          do: {key, offer}

    case history do
      [_, _ | _] ->
        {:error, :ambiguous_offer}

      _ ->
        with :ok <- current_offer_link(ride, state) do
          case history do
            [] ->
              if is_nil(Map.get(ride, :currentOfferId)),
                do: :not_found,
                else: {:error, :wrong_driver}

            [{key, offer}] ->
              with :ok <- record_identity(offer, key) do
                cond do
                  Map.has_key?(offer, :acceptance_result) or Map.has_key?(offer, :accepted_at_ms) ->
                    with :ok <- exclusive_acceptance_history(ride, offer, state),
                         do: replay_acceptance(ride, offer, state)

                  Map.get(offer, :status) in [:rejected, :expired, :cancelled, :completed] ->
                    if offer.id == Map.get(ride, :currentOfferId) and
                         Map.get(ride, :status) in [:driver_assigned, :driver_accepted],
                       do: {:error, :inconsistent_ownership},
                       else: {:error, :invalid_transition}

                  offer.id != Map.get(ride, :currentOfferId) ->
                    {:error, :invalid_transition}

                  true ->
                    with :ok <- exclusive_acceptance_history(ride, offer, state),
                         do: current_acceptance_offer(ride, driver, offer, state)
                end
              end
          end
        end
    end
  end

  defp current_offer_link(ride, state) do
    current_id = Map.get(ride, :currentOfferId)
    ride_id = ride.id
    driver_id = Map.get(ride, :assignedDriverId)

    case Map.fetch(state.offers, Map.get(ride, :currentOfferId)) do
      :error ->
        if Map.get(ride, :status) in [:driver_assigned, :driver_accepted] or
             not is_nil(current_id),
           do: {:error, :inconsistent_ownership},
           else: :ok

      {:ok, %{id: ^current_id, rideId: ^ride_id, driverId: ^driver_id}} ->
        :ok

      {:ok, _invalid} ->
        {:error, :inconsistent_ownership}
    end
  end

  defp current_acceptance_offer(ride, driver, %{status: status} = offer, state)
       when status == :pending do
    cond do
      offer.driverId != driver.id ->
        {:error, :wrong_driver}

      Map.has_key?(offer, :expiration_receipt) or Map.has_key?(offer, :rejection_receipt) or
          not consistent_assignment?(ride, state) ->
        {:error, :inconsistent_ownership}

      true ->
        {:ok, offer}
    end
  end

  defp current_acceptance_offer(_ride, _driver, _offer, _state),
    do: {:error, :inconsistent_ownership}

  defp exclusive_acceptance_history(ride, offer, state) do
    conflict? =
      Enum.any?(state.offers, fn
        {key, %{rideId: ride_id} = other} when ride_id == ride.id and key != offer.id ->
          Map.has_key?(other, :acceptance_result) or Map.has_key?(other, :accepted_at_ms)

        _ ->
          false
      end)

    if conflict?, do: {:error, :inconsistent_ownership}, else: :ok
  end

  defp replay_acceptance(ride, offer, state) do
    active? =
      Map.get(ride, :status) == :driver_accepted and Map.get(offer, :status) == :accepted and
        Map.get(ride, :currentOfferId) == offer.id and consistent_assignment?(ride, state)

    terminal? =
      Map.get(ride, :status) in [:completed, :cancelled] and terminal_valid?(ride, state) and
        Map.get(offer, :status) == ride.status and
        Map.get(ride, :currentOfferId) in [nil, offer.id] and
        Map.get(ride, :assignedDriverId) in [nil, offer.driverId] and
        not Enum.any?(active_offers(state), &(Map.get(&1, :rideId) == ride.id))

    if acceptance_receipt?(offer, ride) and (active? or terminal?),
      do: {:replay, offer.acceptance_result},
      else: {:error, :inconsistent_ownership}
  end

  defp accept_pending(ride, driver, offer, state) do
    with :ok <- offer_deadline(offer),
         {:ok, now} <- acceptance_time(offer, state.clock),
         {:ok, accepted} <- RideStateMachine.transition(ride, :accept_offer),
         {:ok, busy} <- StateMachine.transition(driver, :accept_offer) do
      receipt =
        Map.merge(offer, %{status: :accepted, accepted_at_ms: now, acceptance_result: accepted})

      updated = %{
        state
        | rides: Map.put(state.rides, ride.id, accepted),
          drivers: Map.put(state.drivers, driver.id, busy),
          offers: Map.put(state.offers, offer.id, receipt)
      }

      {:reply, {:ok, accepted}, updated}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  defp offer_deadline(%{created_at_ms: created, expires_at_ms: expires})
       when is_integer(created) and is_integer(expires) and created < expires, do: :ok

  defp offer_deadline(_offer), do: {:error, :inconsistent_ownership}

  defp acceptance_receipt?(%{accepted_at_ms: at, acceptance_result: result} = offer, ride)
       when is_integer(at) and is_map(result) do
    immutable_fields = [:id, :passengerId, :pickup, :destination]

    offer_deadline(offer) == :ok and at >= offer.created_at_ms and at < offer.expires_at_ms and
      not Map.has_key?(offer, :expiration_receipt) and not Map.has_key?(offer, :rejection_receipt) and
      Map.get(result, :id) == offer.rideId and Map.get(result, :status) == :driver_accepted and
      Map.get(result, :currentOfferId) == offer.id and
      Map.get(result, :assignedDriverId) == offer.driverId and
      Enum.all?(
        immutable_fields,
        &(Map.has_key?(result, &1) and Map.fetch(result, &1) == Map.fetch(ride, &1))
      )
  end

  defp acceptance_receipt?(_offer, _ride), do: false

  defp acceptance_time(offer, clock) do
    with {:ok, now} <- read_clock(clock) do
      cond do
        now < offer.created_at_ms -> {:error, :invalid_clock}
        Offer.expired?(offer, now) -> {:error, :offer_expired}
        true -> {:ok, now}
      end
    end
  end

  defp ignore_terminal_event(event, ride, state) do
    if record_identity(ride, event.rideId) == :ok and terminal_valid?(ride, state),
      do: {:reply, {:ok, :ignored}, put_event(state, processed(event, :incompatible_ride_state))},
      else: permanent_failure(state, event, :inconsistent_ownership)
  end

  defp process_ride_created(event, state) do
    case Map.fetch(state.rides, event.rideId) do
      :error ->
        permanent_failure(state, event, :ride_not_found)

      {:ok, %{status: :requested} = ride} ->
        {:ok, matching} = RideStateMachine.transition(ride, :start_matching)

        successor = %{
          eventId: "dispatch-" <> ride.id,
          rideId: ride.id,
          type: :dispatch_requested,
          status: :pending
        }

        updated = %{
          state
          | rides: Map.put(state.rides, ride.id, matching),
            pending_events: Map.put_new(state.pending_events, successor.eventId, successor)
        }

        {:reply, {:ok, :processed}, put_event(updated, processed(event, :matching_started))}

      {:ok, %{status: status} = ride} when status in [:cancelled, :completed] ->
        ignore_terminal_event(event, ride, state)

      {:ok, %{status: status}}
      when status in [:matching, :driver_assigned, :driver_accepted] ->
        {:reply, {:ok, :ignored}, put_event(state, processed(event, :incompatible_ride_state))}

      {:ok, _invalid} ->
        permanent_failure(state, event, :invalid_state)
    end
  end

  defp process_dispatch_requested(event, state) do
    case Map.fetch(state.rides, event.rideId) do
      :error ->
        permanent_failure(state, event, :ride_not_found)

      {:ok, %{id: id, status: :matching} = ride} when id == event.rideId ->
        if is_nil(Map.get(ride, :assignedDriverId)) and is_nil(Map.get(ride, :currentOfferId)) and
             not Enum.any?(active_offers(state), &(Map.get(&1, :rideId) == ride.id)) do
          match_driver(event, ride, state)
        else
          permanent_failure(state, event, :inconsistent_ownership)
        end

      {:ok, %{status: status} = ride} when status in [:driver_assigned, :driver_accepted] ->
        if consistent_assignment?(ride, state) do
          {:reply, {:ok, :ignored}, put_event(state, processed(event, :already_assigned))}
        else
          permanent_failure(state, event, :inconsistent_ownership)
        end

      {:ok, %{status: status} = ride} when status in [:cancelled, :completed] ->
        ignore_terminal_event(event, ride, state)

      {:ok, _invalid} ->
        permanent_failure(state, event, :invalid_state)
    end
  end

  defp match_driver(event, ride, state) do
    exclusions =
      for {_key, %{rideId: ride_id, driverId: driver_id, status: status}} <- state.offers,
          ride_id == ride.id and status in [:rejected, :expired],
          do: driver_id

    case Matcher.nearest(Map.get(ride, :pickup), Map.values(state.drivers),
           radius_km: state.matching_radius_km,
           excluded_driver_ids: exclusions
         ) do
      {:ok, driver} ->
        if Map.get(state.drivers, driver.id) != driver or
             Enum.any?(active_offers(state), &(Map.get(&1, :driverId) == driver.id)) or
             Enum.any?(active_rides(state), &(Map.get(&1, :assignedDriverId) == driver.id)) do
          permanent_failure(state, event, :inconsistent_ownership)
        else
          reserve(event, ride, driver, state)
        end

      :none ->
        {:reply, {:ok, :processed}, put_event(state, processed(event, :no_candidate))}

      {:error, reason} ->
        permanent_failure(state, event, reason)
    end
  end

  # Unknown/malformed statuses do not release a known ownership reference.
  # Unrelated malformed records are reported separately by expiration discovery.
  defp active_offers(state),
    do: state.offers |> Map.values() |> Enum.filter(&offer_active?(&1, state))

  defp active_rides(state),
    do: state.rides |> Map.values() |> Enum.filter(&ride_active?(&1, state))

  defp consistent_assignment?(ride, state) do
    offer = Map.get(state.offers, Map.get(ride, :currentOfferId))
    driver = Map.get(state.drivers, Map.get(ride, :assignedDriverId))

    case {ride.status, driver, offer} do
      {:driver_assigned, %{status: :offered, id: driver_id},
       %{id: offer_id, status: :pending, rideId: ride_id, driverId: driver_id}} ->
        unique_assignment?(ride, driver_id, offer_id, ride_id, state)

      {:driver_accepted, %{status: :busy, id: driver_id},
       %{id: offer_id, status: :accepted, rideId: ride_id, driverId: driver_id}} ->
        unique_assignment?(ride, driver_id, offer_id, ride_id, state)

      _inconsistent ->
        false
    end
  end

  defp unique_assignment?(ride, driver_id, offer_id, ride_id, state) do
    ride.id == ride_id and ride.assignedDriverId == driver_id and ride.currentOfferId == offer_id and
      Enum.count(
        active_offers(state),
        &(Map.get(&1, :rideId) == ride_id or Map.get(&1, :driverId) == driver_id)
      ) == 1 and
      Enum.count(active_rides(state), &(Map.get(&1, :assignedDriverId) == driver_id)) == 1
  end

  defp reserve(event, ride, driver, state) do
    with {:ok, offered} <- StateMachine.transition(driver, :reserve_for_offer),
         {:ok, assigned} <- RideStateMachine.transition(ride, :create_offer),
         {:ok, now} <- read_clock(state.clock) do
      id = "offer-" <> Integer.to_string(System.unique_integer([:positive, :monotonic]))

      offer = %{
        id: id,
        rideId: ride.id,
        driverId: driver.id,
        status: :pending,
        created_at_ms: now,
        expires_at_ms: now + state.offer_timeout_ms
      }

      assigned = Map.merge(assigned, %{assignedDriverId: driver.id, currentOfferId: id})

      updated = %{
        state
        | rides: Map.put(state.rides, ride.id, assigned),
          drivers: Map.put(state.drivers, driver.id, offered),
          offers: Map.put(state.offers, id, offer)
      }

      {:reply, {:ok, :processed}, put_event(updated, processed(event, :offer_created))}
    else
      {:error, :invalid_clock} = error -> {:reply, error, state}
      {:error, reason} -> permanent_failure(state, event, reason)
    end
  end

  defp permanent_failure(state, event, reason) do
    failed =
      Map.merge(event, %{
        status: :failed,
        attempts: event_attempts(event) + 1,
        last_error: reason,
        next_attempt_at: nil
      })

    {:reply, {:error, {:permanent, reason}}, put_event(state, failed)}
  end

  defp processed(event, outcome),
    do:
      Map.merge(event, %{
        status: :processed,
        attempts: Map.get(event, :attempts, 0) + 1,
        outcome: outcome,
        next_attempt_at: nil
      })

  defp put_event(state, event),
    do: %{state | pending_events: Map.put(state.pending_events, event.eventId, event)}

  defp supported_pending?(event),
    do: event.type in [:ride_created, :dispatch_requested] and event.status == :pending

  defp valid_event?(%{eventId: id, rideId: ride_id} = event, id) do
    attempts = Map.get(event, :attempts, 0)
    at = Map.get(event, :next_attempt_at)

    is_binary(ride_id) and ride_id != "" and is_integer(attempts) and attempts >= 0 and
      (is_nil(at) or is_integer(at))
  end

  defp valid_event?(_event, _id), do: false

  defp event_attempts(%{attempts: attempts}) when is_integer(attempts) and attempts >= 0,
    do: attempts

  defp event_attempts(_event), do: 0

  defp eligible?(event, now),
    do: is_nil(Map.get(event, :next_attempt_at)) or event.next_attempt_at <= now

  defp event_result({:ok, event}), do: {:ok, event}
  defp event_result(:error), do: :not_found

  defp ride_result(:not_found), do: :not_found
  defp ride_result(ride), do: {:ok, ride}

  defp create_ride(state, key, canonical) do
    if Map.has_key?(state.passengers, canonical.passengerId) do
      # VM-wide uniqueness, including owner restarts in the same VM. No durable
      # identity guarantee across VM restarts; all authoritative state is volatile.
      suffix = Integer.to_string(System.unique_integer([:positive, :monotonic]))
      ride_id = "ride-" <> suffix
      event_id = "event-" <> suffix
      ride = Map.merge(canonical, %{id: ride_id, status: :requested, assignedDriverId: nil})
      result = {:ok, ride}
      record = %{canonical_request: canonical, original_result: result, event_id: event_id}
      event = %{eventId: event_id, rideId: ride_id, type: :ride_created, status: :pending}

      updated = %{
        state
        | rides: Map.put(state.rides, ride_id, ride),
          idempotency: Map.put(state.idempotency, key, record),
          pending_events: Map.put(state.pending_events, event_id, event)
      }

      {:reply, result, updated}
    else
      {:reply, {:error, :passenger_not_found}, state}
    end
  end

  defp seed_passengers(seeds) when is_list(seeds) do
    Enum.reduce_while(seeds, {:ok, %{}}, fn
      %{id: id} = passenger, {:ok, passengers} when is_binary(id) and id != "" ->
        if Map.has_key?(passengers, id) do
          {:halt, {:error, {:duplicate_passenger_id, id}}}
        else
          {:cont, {:ok, Map.put(passengers, id, passenger)}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_passenger_seed}}
    end)
  end

  defp seed_passengers(_seeds), do: {:error, :invalid_passenger_seeds}

  defp seed_drivers(seeds) when is_list(seeds) do
    Enum.reduce_while(seeds, {:ok, %{}}, fn driver, {:ok, drivers} ->
      cond do
        not valid_seed?(driver) ->
          {:halt, {:error, :invalid_driver_seed}}

        Map.has_key?(drivers, driver.id) ->
          {:halt, {:error, {:duplicate_driver_id, driver.id}}}

        true ->
          {:cont, {:ok, Map.put(drivers, driver.id, driver)}}
      end
    end)
  end

  defp seed_drivers(_seeds), do: {:error, :invalid_driver_seeds}

  defp valid_seed?(%{id: id, status: status} = driver)
       when is_binary(id) and id != "" and status in [:offline, :available],
       do: Location.valid?(driver)

  defp valid_seed?(_driver), do: false

  defp validate_policy(radius, _timeout) when not is_number(radius) or radius < 0,
    do: {:error, :invalid_matching_radius}

  defp validate_policy(_radius, timeout) when not is_integer(timeout) or timeout <= 0,
    do: {:error, :invalid_offer_timeout}

  defp validate_policy(_radius, _timeout), do: :ok

  defp read_clock(clock) when is_function(clock, 0) do
    case clock.() do
      now when is_integer(now) -> {:ok, now}
      _invalid -> {:error, :invalid_clock}
    end
  rescue
    _error -> {:error, :invalid_clock}
  end

  defp read_clock(_clock), do: {:error, :invalid_clock}
end
