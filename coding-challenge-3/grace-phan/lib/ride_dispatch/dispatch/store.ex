defmodule RideDispatch.Dispatch.Store do
  @moduledoc """
  Public boundary for authoritative dispatch state. Pass a server PID or name.
  Queries return immutable values, not access to the owner's state.
  """

  # Queries
  def get_driver(server, driver_id), do: GenServer.call(server, {:get_driver, driver_id})

  def list_available_drivers(server), do: GenServer.call(server, :list_available_drivers)
end
