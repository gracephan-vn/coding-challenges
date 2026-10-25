defmodule RideDispatch.Dispatch.Matcher do
  @moduledoc """
  Pure candidate selection. This module does not reserve drivers or change ride state.
  """

  alias RideDispatch.Location

  @doc """
  Selects the nearest available driver, breaking exact distance ties by string ID.

  Drivers are maps with unique string `:id`, atom `:status`, `:latitude`, and
  `:longitude` fields. Only `:available` drivers with valid coordinates qualify;
  malformed drivers are skipped. Returns `{:ok, driver}` or `:none`.

  Options are a keyword list: `:radius_km` defaults to 2.0 (inclusive), and
  `:excluded_driver_ids` is an enumerable of IDs rejected or timed out for this
  ride, defaulting to `[]`. The caller retains and supplies that ride's history.

  Returns `{:error, :invalid_pickup}` for invalid pickup coordinates or
  `{:error, :invalid_radius}` for a nonnumeric or negative radius.
  """
  def nearest(pickup, drivers, opts \\ []) do
    radius = Keyword.get(opts, :radius_km, 2.0)

    cond do
      not Location.valid?(pickup) ->
        {:error, :invalid_pickup}

      not is_number(radius) or radius < 0 ->
        {:error, :invalid_radius}

      true ->
        excluded_ids = MapSet.new(Keyword.get(opts, :excluded_driver_ids, []))
        select_candidate(pickup, drivers, radius, excluded_ids)
    end
  end

  defp select_candidate(pickup, drivers, radius, excluded_ids) do
    drivers
    |> Enum.filter(&eligible?/1)
    |> Enum.reject(&MapSet.member?(excluded_ids, &1.id))
    |> Enum.map(&{Location.distance_km(pickup, &1), &1})
    |> Enum.filter(fn {distance, _driver} -> distance <= radius end)
    |> Enum.min_by(fn {distance, driver} -> {distance, driver.id} end, fn -> nil end)
    |> case do
      nil -> :none
      {_distance, driver} -> {:ok, driver}
    end
  end

  defp eligible?(%{id: id, status: :available} = driver) when is_binary(id),
    do: Location.valid?(driver)

  defp eligible?(_driver), do: false
end
