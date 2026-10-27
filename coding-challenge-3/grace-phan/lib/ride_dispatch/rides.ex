defmodule RideDispatch.Rides do
  @moduledoc "Ride application boundary; authoritative operations are delegated to Store."
  alias RideDispatch.Dispatch.Store

  defdelegate cancel_ride(server, ride_id), to: Store
  defdelegate complete_ride(server, ride_id), to: Store

  defdelegate create_ride(server, key, request), to: Store
  defdelegate get_ride(server, ride_id), to: Store
  defdelegate accept_offer(server, ride_id, driver_id), to: Store
  defdelegate reject_offer(server, ride_id, driver_id), to: Store
end
