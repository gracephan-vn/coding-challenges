defmodule RideDispatch.Dispatch.StateServer do
  @moduledoc false
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    drivers = Map.new(Keyword.get(opts, :drivers, []), &{&1.id, &1})
    {:ok, %{drivers: drivers}}
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
end
