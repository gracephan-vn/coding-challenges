defmodule RideDispatch.Dispatch.Matcher do
  alias RideDispatch.Location

  def nearest(pickup, drivers) do
    drivers
    |> Enum.filter(&(&1.status == :available))
    |> Enum.min_by(&Location.distance_km(pickup, &1), fn -> nil end)
    |> case do
      nil -> :none
      driver -> {:ok, driver}
    end
  end
end
