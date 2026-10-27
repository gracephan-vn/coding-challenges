defmodule RideDispatch.Dispatch.Store do
  @moduledoc """
  Public boundary for authoritative dispatch state. Pass a server PID or name.
  Queries return immutable values, not access to the owner's state.

  State is volatile: restarting the owner reloads seeds, not runtime updates.
  Calls use the standard GenServer timeout; a timeout does not cancel a command.
  """

  # Queries
  @doc """
  Read-only owner-clock snapshot: `{:ok, %{now_ms: integer, pending: deadlines,
  invalid_offers: diagnostics}}` or `{:error, :invalid_clock}`. Pending entries
  contain only offer_id, expires_at_ms and a diagnostic fingerprint. Invalid
  entries contain storage identity, reason and fingerprint. Fingerprints are
  nonauthoritative change hints; they never prove business identity or eligibility.
  """
  def expiration_schedule(server), do: GenServer.call(server, :expiration_schedule)

  @doc "All retained Offers, sorted by ID; deadlines alone never release ownership."
  def list_offers(server), do: GenServer.call(server, :list_offers)
  @doc "Returns `{:ok, offer}` or `:not_found`."
  def get_offer(server, id), do: GenServer.call(server, {:get_offer, id})

  @doc "All retained events, sorted by ID, including unsupported pending events."
  def list_events(server), do: GenServer.call(server, :list_events)
  @doc "Returns `{:ok, event}` or `:not_found`, including processed/failed records."
  def get_event(server, id), do: GenServer.call(server, {:get_event, id})
  @doc "Due supported pending events only; discovery does not claim or mutate work."
  def list_actionable_events(server), do: GenServer.call(server, :list_actionable_events)
  @doc "Milliseconds until the next supported pending event is eligible, or nil; uses owner time."
  def next_event_delay(server), do: GenServer.call(server, :next_event_delay)

  @doc "Returns the current Ride as `{:ok, ride}` or `:not_found`."
  def get_ride(server, ride_id), do: GenServer.call(server, {:get_ride, ride_id})

  @doc "Returns `{:ok, driver}` or `:not_found`."
  def get_driver(server, driver_id), do: GenServer.call(server, {:get_driver, driver_id})

  @doc "Returns available drivers in lexicographic ID order."
  def list_available_drivers(server), do: GenServer.call(server, :list_available_drivers)

  @doc "Cancel one Ride atomically; proven retries return the original terminal result."
  def cancel_ride(server, ride_id), do: command(server, {:terminal_ride, :cancel, ride_id})

  @doc "Complete one accepted Ride atomically; proven retries never release a Driver again."
  def complete_ride(server, ride_id),
    do: command(server, {:terminal_ride, :complete, ride_id})

  # Commands
  @doc """
  Expire one exact Offer using authoritative processing time. Returns
  `{:ok, :expired | :already_expired | :ignored}`, `:not_found`, or
  `{:error, {:not_due, deadline} | :invalid_request | :invalid_clock | :inconsistent_ownership}`.
  The transition, immutable receipt and one redispatch event commit together.
  A timeout does not cancel the command; all evidence is volatile.
  """
  def expire_offer(server, offer_id) do
    result = command(server, {:expire_offer, offer_id})
    if result == {:ok, :expired}, do: GenServer.cast(server, :notify_events)
    result
  end

  @doc """
  Atomically reject the exact current pending Offer, release its Driver and
  enqueue one Offer-derived redispatch event. Returns `{:ok, original_matching_ride}`,
  `:not_found`, or `{:error, reason}` using acceptance's identity/error conventions.
  Late rejection is allowed while the reservation is still pending. Proven receipt
  replay never releases a replacement assignment or enqueues again. Wake-ups are
  hints sent after the command; state and receipts are volatile, not durable.
  """
  def reject_offer(server, ride_id, driver_id) do
    result = command(server, {:reject_offer, ride_id, driver_id})
    if match?({:ok, _}, result), do: GenServer.cast(server, :notify_events)
    result
  end

  @doc """
  Atomically accept the exact current pending Offer using owner time. No key or
  caller timestamp is needed. Returns `{:ok, original_accepted_ride}` or
  `:not_found` for unknown resources/absent relationship. Validated receipt replay
  returns the original snapshot without mutation, including after its deadline.
  Multiple Offers for the Ride/Driver pair return `{:error, :ambiguous_offer}`.
  Other errors: `:invalid_request`, `:wrong_driver`, `:offer_expired`,
  `:invalid_transition`, `:inconsistent_ownership`, `:invalid_clock`.
  Expired first attempts retain their reservation. Evidence is volatile; a call
  timeout does not cancel the command. This API does not authenticate the caller.
  """
  def accept_offer(server, ride_id, driver_id),
    do: command(server, {:accept_offer, ride_id, driver_id})

  @doc "Subscribe a dispatcher or scheduler to nonauthoritative wake-up hints."
  def subscribe_events(server), do: GenServer.call(server, :subscribe_events)

  @doc """
  Atomically process and acknowledge RideCreated or DispatchRequested. RideCreated
  starts matching and enqueues DispatchRequested. DispatchRequested uses current
  authoritative state to reserve one pending Offer or record a no-candidate result.
  Reservation coordinates Ride, Driver, Offer and Event; it does not accept a ride.
  Returns `{:ok, :processed | :already_processed | :ignored}`, `:not_found`,
  or `{:error, :unsupported_event | :failed | :invalid_clock | {:retry_at, time} | {:permanent, reason}}`.
  Unsupported work is never consumed. Duplicate commands leave state unchanged.
  """
  def process_event(server, id) do
    result = command(server, {:process_event, id})
    if result == {:ok, :processed}, do: GenServer.cast(server, :notify_events)
    result
  end

  @doc "Record a definite worker-side failure with an observed attempt version; never use for a timeout."
  def fail_event(server, id, version, :processing_failed),
    do: command(server, {:fail_event, id, version, :processing_failed})

  @doc """
  Atomically creates a REQUESTED Ride, original result and pending RideCreated
  event. Accepts a nonblank string key and a strict string-keyed request map.
  Returns `{:ok, original_ride}` or `{:error, reason}` where reason is
  `:invalid_idempotency_key`, `:invalid_request`, `:idempotency_conflict`, or
  `:passenger_not_found`. Input validation precedes canonical replay/conflict;
  passenger existence is checked only for new keys. Keys are owner-global.
  A retry after a timeout is safe while this owner survives. Pending events are
  not delivered here; nothing is durable across owner loss.
  """
  def create_ride(server, key, request) do
    result = command(server, {:create_ride, key, request})
    if match?({:ok, _}, result), do: GenServer.cast(server, :notify_events)
    result
  end

  @doc """
  Enables (`true`) or disables (`false`) availability atomically through the
  Driver State Machine. Repeated requests succeed unchanged.

  Returns `{:ok, driver}`, `:not_found`, or the State Machine's error tuple.
  Nonboolean input returns `{:error, :invalid_availability}`. Unknown IDs take
  precedence over input validation, consistent with location commands.
  Other driver fields are preserved; rejected transitions leave state unchanged.
  """
  def set_driver_availability(server, driver_id, available?) do
    GenServer.call(server, {:set_driver_availability, driver_id, available?})
  end

  @doc """
  Atomically updates both coordinates, preserving all other driver fields.

  Returns `{:ok, driver}`, `:not_found`, or `{:error, :invalid_coordinates}`.
  Unknown IDs take precedence over coordinate validation. Extra location fields
  are ignored. Rejected commands leave state unchanged.
  """
  def update_driver_location(server, driver_id, location) do
    GenServer.call(server, {:update_driver_location, driver_id, location})
  end

  defp command(server, message) do
    GenServer.call(server, {:observed, message})
  catch
    :exit, {:timeout, _} = reason ->
      RideDispatch.Dispatch.LifecycleLog.uncertain(message)
      exit(reason)
  end
end
