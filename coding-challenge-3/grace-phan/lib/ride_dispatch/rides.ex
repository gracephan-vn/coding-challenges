defmodule RideDispatch.Rides do
  @moduledoc "Ride application boundary; authoritative operations are delegated to Store."
  alias RideDispatch.Dispatch.Store

  defdelegate create_ride(server, key, request), to: Store
  defdelegate get_ride(server, ride_id), to: Store
end
