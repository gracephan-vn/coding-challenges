defmodule RideDispatch.Dispatch.Matcher do
  alias RideDispatch.Location

  def nearest(pickup, drivers, opts \\ []) do
    radius = Keyword.get(opts, :radius_km, 2.0)
    excluded_ids = MapSet.new(Keyword.get(opts, :excluded_driver_ids, []))

    drivers
    |> Enum.filter(&(&1.status == :available))
    |> Enum.reject(&MapSet.member?(excluded_ids, &1.id))
    |> Enum.map(&{Location.distance_km(pickup, &1), &1})
    |> Enum.filter(fn {distance, _driver} -> distance <= radius end)
    |> Enum.min_by(fn {distance, driver} -> {distance, driver.id} end, fn -> nil end)
    |> case do
      nil -> :none
      {_distance, driver} -> {:ok, driver}
    end
  end
end
