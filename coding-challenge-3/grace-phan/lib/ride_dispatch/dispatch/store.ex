defmodule RideDispatch.Dispatch.Store do
  @moduledoc """
  Public boundary for authoritative dispatch state. Pass a server PID or name.
  Queries return immutable values, not access to the owner's state.

  State is volatile: restarting the owner reloads seeds, not runtime updates.
  Calls use the standard GenServer timeout; a timeout does not cancel a command.
  """

  # Queries
  @doc "Returns `{:ok, driver}` or `:not_found`."
  def get_driver(server, driver_id), do: GenServer.call(server, {:get_driver, driver_id})

  @doc "Returns available drivers in lexicographic ID order."
  def list_available_drivers(server), do: GenServer.call(server, :list_available_drivers)

  # Commands
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
