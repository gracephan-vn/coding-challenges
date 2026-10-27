defmodule RideDispatch.Dispatch.LifecycleLog do
  @moduledoc false
  require Logger

  # Called only from the owner's post-installation continuation. Read a small
  # projection of the command's records; never log bodies, keys or state maps.
  def committed(command, result, before, after_state) do
    metadata = context(command, before)

    cond do
      before === after_state ->
        unchanged(command, result, replay_identity(command, result, metadata, before))

      true ->
        changed(command, result, metadata, before, after_state)
    end
  end

  def uncertain(command) do
    emit("operation.uncertain", Map.put(request_identity(command), :outcome, :timeout), :warning)
  end

  def emit(name, metadata, level \\ :info) do
    # Only scalar, bounded identifiers/categories. Invalid user-supplied IDs must
    # not inject log lines or make observability crash a command.
    fields = Enum.filter(metadata, fn {_key, value} -> safe?(value) end)
    Logger.log(level, name, fields)
  end

  defp safe?(value) when is_atom(value), do: not is_nil(value)
  defp safe?(value) when is_integer(value), do: true

  defp safe?(value) when is_binary(value),
    do:
      byte_size(value) <= 256 and String.valid?(value) and
        not String.match?(value, ~r/[\x00-\x20\x7f]/u)

  defp safe?(_), do: false

  # Only a successful command result authorizes a replay label. Historical
  # identity is a read-only projection of evidence already validated by the owner.
  defp replay_identity({action, ride_id, driver_id}, {:ok, _}, metadata, state)
       when action in [:accept_offer, :reject_offer] do
    case Enum.filter(Map.values(state.offers), fn
           %{rideId: ^ride_id, driverId: ^driver_id} -> true
           _ -> false
         end) do
      [offer] -> Map.merge(metadata, offer_fields(offer))
      _ -> metadata
    end
  end

  defp replay_identity(_, _, metadata, _), do: metadata

  defp unchanged(command, result, metadata) do
    {name, outcome} =
      case result do
        {:ok, :ignored} ->
          {"operation.ignored", :ignored}

        {:ok, _} ->
          {"operation.replayed", :replayed}

        {:error, {:not_due, _}} ->
          {"operation.deferred", :not_due}

        {:error, {:retry_at, _}} ->
          {"operation.deferred", :retry_at}

        {:error, reason} when reason in [:invalid_clock, :inconsistent_ownership, :failed] ->
          {"operation.failed", reason}

        {:error, {reason, _}} ->
          {"operation.rejected", reason}

        {:error, reason} ->
          {"operation.rejected", reason}

        :not_found ->
          {"operation.rejected", :not_found}
      end

    emit(
      name,
      Map.merge(metadata, %{operation: operation(command), outcome: outcome}),
      if(name == "operation.failed", do: :warning, else: :info)
    )
  end

  defp changed({:create_ride, key, _}, {:ok, ride}, _, _, state) do
    event = state.pending_events[state.idempotency[key].event_id]
    metadata = %{rideId: ride.id, eventId: event.eventId}
    emit("ride.created", Map.put(metadata, :outcome, :requested))
    enqueued(event)
  end

  defp changed({:process_event, id}, _, _, before, state) do
    event = state.pending_events[id]
    metadata = event_fields(event)

    if event.status == :processed do
      case Map.get(event, :outcome) do
        :matching_started ->
          emit("ride.matching_started", metadata)

        :offer_created ->
          ride = state.rides[event.rideId]
          offer = state.offers[ride.currentOfferId]
          emit("dispatch.matching", Map.merge(metadata, offer_fields(offer)))
          emit("offer.reserved", Map.merge(metadata, offer_fields(offer)))

        :no_candidate ->
          emit("dispatch.no_candidate", metadata)

        _ ->
          :ok
      end

      name =
        if event.type == :dispatch_requested, do: "dispatch.processed", else: "event.processed"

      emit(name, metadata)
      successor = Map.get(state.pending_events, "dispatch-" <> event.rideId)

      if successor && not Map.has_key?(before.pending_events, successor.eventId),
        do: enqueued(successor, %{causedByEventId: id})
    else
      emit("event.processing_failed", metadata, :warning)
    end
  end

  defp changed({:fail_event, id, _, _}, _, _, _, state) do
    event = state.pending_events[id]

    name =
      if event.status == :failed, do: "event.processing_failed", else: "event.retry_scheduled"

    emit(name, event_fields(event), :warning)
  end

  defp changed({:terminal_ride, operation, id}, _, _, _, state) do
    receipt = state.rides[id].terminal_receipt

    emit(if(operation == :cancel, do: "ride.cancelled", else: "ride.completed"), %{
      rideId: id,
      driverId: receipt.driverId,
      offerId: receipt.offerId,
      outcome: state.rides[id].status,
      driverStatus: if(receipt.driverId, do: :available)
    })
  end

  defp changed({:accept_offer, _, _}, _, metadata, _, _) do
    emit("offer.accepted", Map.merge(metadata, %{outcome: :accepted, driverStatus: :busy}))
  end

  defp changed({action, _, _}, _, metadata, _, state) when action == :reject_offer do
    closed("offer.rejected", :rejection_receipt, metadata, state)
  end

  defp changed({:expire_offer, _}, _, metadata, _, state) do
    closed("offer.expired", :expiration_receipt, metadata, state)
  end

  defp closed(name, receipt_key, metadata, state) do
    offer = state.offers[metadata.offerId]
    event = state.pending_events[offer[receipt_key].redispatch_event_id]

    emit(
      name,
      Map.merge(metadata, %{
        eventId: event.eventId,
        outcome: offer.status,
        driverStatus: :available
      })
    )

    enqueued(event, %{offerId: offer.id, driverId: offer.driverId})
  end

  defp enqueued(event, extra \\ %{}) do
    name = if event.type == :dispatch_requested, do: "dispatch.requested", else: "event.enqueued"
    emit(name, Map.merge(event_fields(event), Map.put(extra, :outcome, :pending)))
  end

  defp event_fields(record) do
    event = as_map(record)

    %{
      rideId: Map.get(event, :rideId),
      eventId: Map.get(event, :eventId),
      eventType: Map.get(event, :type),
      outcome: Map.get(event, :outcome) || Map.get(event, :last_error) || Map.get(event, :status),
      attempts: Map.get(event, :attempts, 0),
      retryAtMs: Map.get(event, :next_attempt_at)
    }
  end

  defp offer_fields(offer) when is_map(offer),
    do: %{
      rideId: Map.get(offer, :rideId),
      driverId: Map.get(offer, :driverId),
      offerId: Map.get(offer, :id)
    }

  defp offer_fields(_), do: %{}

  defp context({:create_ride, key, _}, state) do
    case Map.get(state.idempotency, key) do
      %{event_id: id} -> event_fields(Map.get(state.pending_events, id, %{}))
      _ -> %{}
    end
  end

  defp context({:terminal_ride, operation, id}, state) do
    ride = as_map(Map.get(state.rides, id))
    receipt = as_map(Map.get(ride, :terminal_receipt))

    %{
      rideId: id,
      operation: operation,
      driverId: Map.get(receipt, :driverId) || Map.get(ride, :assignedDriverId),
      offerId: Map.get(receipt, :offerId) || Map.get(ride, :currentOfferId)
    }
  end

  defp context({:expire_offer, id}, state),
    do: Map.merge(offer_fields(Map.get(state.offers, id)), %{offerId: id})

  defp context({action, id}, state) when action == :process_event,
    do: Map.merge(event_fields(Map.get(state.pending_events, id, %{})), %{eventId: id})

  defp context({:fail_event, id, _, _}, state), do: context({:process_event, id}, state)

  defp context(command, state) do
    identity = request_identity(command)
    ride = as_map(Map.get(state.rides, Map.get(identity, :rideId)))
    offer = Map.get(state.offers, Map.get(ride, :currentOfferId))
    # A stale request for A must not be attributed to B's current Offer.
    fields = offer_fields(offer)

    if Map.get(identity, :driverId) in [nil, Map.get(fields, :driverId)],
      do: Map.merge(fields, identity),
      else: identity
  end

  defp request_identity({action, ride_id, driver_id})
       when action in [:accept_offer, :reject_offer],
       do: %{rideId: ride_id, driverId: driver_id}

  defp request_identity({:terminal_ride, operation, id}), do: %{rideId: id, operation: operation}
  defp request_identity({:expire_offer, id}), do: %{offerId: id}
  defp request_identity({:process_event, id}), do: %{eventId: id}
  defp request_identity({:fail_event, id, _, _}), do: %{eventId: id}
  defp request_identity(_), do: %{}

  defp as_map(value) when is_map(value), do: value
  defp as_map(_), do: %{}

  defp operation({:terminal_ride, operation, _}), do: operation
  defp operation(command), do: elem(command, 0)
end
