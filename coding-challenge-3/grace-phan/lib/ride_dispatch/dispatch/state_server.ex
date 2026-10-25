defmodule RideDispatch.Dispatch.StateServer do
  @moduledoc false
  use GenServer

  alias RideDispatch.Location

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    case seed_drivers(Keyword.get(opts, :drivers, [])) do
      {:ok, drivers} -> {:ok, %{drivers: drivers}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:get_driver, id}, _from, state) do
    result =
      case Map.fetch(state.drivers, id) do
        {:ok, driver} -> {:ok, driver}
        :error -> :not_found
      end

    {:reply, result, state}
  end

  def handle_call(:list_available_drivers, _from, state) do
    drivers =
      state.drivers
      |> Map.values()
      |> Enum.filter(&(&1.status == :available))
      |> Enum.sort_by(& &1.id)

    {:reply, drivers, state}
  end

  def handle_call({:update_driver_location, id, location}, _from, state) do
    case Map.fetch(state.drivers, id) do
      :error ->
        {:reply, :not_found, state}

      {:ok, driver} ->
        if Location.valid?(location) do
          updated = %{driver | latitude: location.latitude, longitude: location.longitude}
          new_state = %{state | drivers: Map.put(state.drivers, id, updated)}
          {:reply, {:ok, updated}, new_state}
        else
          {:reply, {:error, :invalid_coordinates}, state}
        end
    end
  end

  defp seed_drivers(seeds) when is_list(seeds) do
    Enum.reduce_while(seeds, {:ok, %{}}, fn driver, {:ok, drivers} ->
      cond do
        not valid_seed?(driver) ->
          {:halt, {:error, :invalid_driver_seed}}

        Map.has_key?(drivers, driver.id) ->
          {:halt, {:error, {:duplicate_driver_id, driver.id}}}

        true ->
          {:cont, {:ok, Map.put(drivers, driver.id, driver)}}
      end
    end)
  end

  defp seed_drivers(_seeds), do: {:error, :invalid_driver_seeds}

  defp valid_seed?(%{id: id, status: status} = driver)
       when is_binary(id) and id != "" and status in [:offline, :available],
       do: Location.valid?(driver)

  defp valid_seed?(_driver), do: false
end
