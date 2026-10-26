defmodule RideDispatch.Dispatch.Store do
  @moduledoc """
  Public boundary for authoritative dispatch state. Pass a server PID or name.
  Queries return immutable values, not access to the owner's state.

  State is volatile: restarting the owner reloads seeds, not runtime updates.
  Calls use the standard GenServer timeout; a timeout does not cancel a command.
  """

  # Queries
  @doc "Returns the current Ride as `{:ok, ride}` or `:not_found`."
  def get_ride(server, ride_id), do: GenServer.call(server, {:get_ride, ride_id})

  @doc "Returns `{:ok, driver}` or `:not_found`."
  def get_driver(server, driver_id), do: GenServer.call(server, {:get_driver, driver_id})

  @doc "Returns available drivers in lexicographic ID order."
  def list_available_drivers(server), do: GenServer.call(server, :list_available_drivers)

  # Commands
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
  def create_ride(server, key, request), do: GenServer.call(server, {:create_ride, key, request})

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
end
