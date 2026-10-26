defmodule RideDispatch.Dispatch.StateServer do
  @moduledoc false
  use GenServer

  alias RideDispatch.Rides.Request
  alias RideDispatch.Location
  alias RideDispatch.Drivers.StateMachine

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  end

  @impl true
  def init(opts) do
    with {:ok, drivers} <- seed_drivers(Keyword.get(opts, :drivers, [])),
         {:ok, passengers} <- seed_passengers(Keyword.get(opts, :passengers, [])) do
      {:ok,
       %{
         drivers: drivers,
         passengers: passengers,
         rides: %{},
         idempotency: %{},
         pending_events: %{}
       }}
    else
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

  def handle_call({:set_driver_availability, id, available?}, _from, state) do
    case Map.fetch(state.drivers, id) do
      :error ->
        {:reply, :not_found, state}

      {:ok, driver} when is_boolean(available?) ->
        action = if available?, do: :enable_availability, else: :disable_availability

        case StateMachine.transition(driver, action) do
          {:ok, updated} ->
            new_state = %{state | drivers: Map.put(state.drivers, id, updated)}
            {:reply, {:ok, updated}, new_state}

          {:error, _reason} = error ->
            {:reply, error, state}
        end

      {:ok, _driver} ->
        {:reply, {:error, :invalid_availability}, state}
    end
  end

  def handle_call({:get_ride, id}, _from, state) do
    {:reply, Map.get(state.rides, id, :not_found) |> ride_result(), state}
  end

  def handle_call({:create_ride, key, body}, _from, state) do
    with true <- Request.valid_key?(key),
         {:ok, canonical} <- Request.normalize(body) do
      case Map.fetch(state.idempotency, key) do
        {:ok, %{canonical_request: ^canonical, original_result: result}} ->
          {:reply, result, state}

        {:ok, _different} ->
          {:reply, {:error, :idempotency_conflict}, state}

        :error ->
          create_ride(state, key, canonical)
      end
    else
      false -> {:reply, {:error, :invalid_idempotency_key}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp ride_result(:not_found), do: :not_found
  defp ride_result(ride), do: {:ok, ride}

  defp create_ride(state, key, canonical) do
    if Map.has_key?(state.passengers, canonical.passengerId) do
      # VM-wide uniqueness, including owner restarts in the same VM. No durable
      # identity guarantee across VM restarts; all authoritative state is volatile.
      suffix = Integer.to_string(System.unique_integer([:positive, :monotonic]))
      ride_id = "ride-" <> suffix
      event_id = "event-" <> suffix
      ride = Map.merge(canonical, %{id: ride_id, status: :requested, assignedDriverId: nil})
      result = {:ok, ride}
      record = %{canonical_request: canonical, original_result: result, event_id: event_id}
      event = %{eventId: event_id, rideId: ride_id, type: :ride_created, status: :pending}

      updated = %{
        state
        | rides: Map.put(state.rides, ride_id, ride),
          idempotency: Map.put(state.idempotency, key, record),
          pending_events: Map.put(state.pending_events, event_id, event)
      }

      {:reply, result, updated}
    else
      {:reply, {:error, :passenger_not_found}, state}
    end
  end

  defp seed_passengers(seeds) when is_list(seeds) do
    Enum.reduce_while(seeds, {:ok, %{}}, fn
      %{id: id} = passenger, {:ok, passengers} when is_binary(id) and id != "" ->
        if Map.has_key?(passengers, id) do
          {:halt, {:error, {:duplicate_passenger_id, id}}}
        else
          {:cont, {:ok, Map.put(passengers, id, passenger)}}
        end

      _invalid, _acc ->
        {:halt, {:error, :invalid_passenger_seed}}
    end)
  end

  defp seed_passengers(_seeds), do: {:error, :invalid_passenger_seeds}

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
