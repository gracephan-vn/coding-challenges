defmodule RideDispatch.Rides.Request do
  @moduledoc """
  Strict creation input shared by HTTP and Store: string-keyed JSON-shaped maps.
  Canonical maps use atom keys and numeric coordinates normalized to floats,
  without rounding. Unsupported fields are rejected. Keys are opaque, global
  within an owner, nonblank strings; passenger IDs are exact nonempty strings.
  """
  alias RideDispatch.Location

  def valid_key?(key) when is_binary(key), do: String.valid?(key) and String.trim(key) != ""
  def valid_key?(_key), do: false

  def normalize(%{"passengerId" => id, "pickup" => pickup, "destination" => destination} = body)
      when map_size(body) == 3 and is_binary(id) and id != "" do
    with {:ok, pickup} <- coordinates(pickup),
         {:ok, destination} <- coordinates(destination) do
      {:ok, %{passengerId: id, pickup: pickup, destination: destination}}
    end
  end

  def normalize(_body), do: {:error, :invalid_request}

  defp coordinates(%{"latitude" => lat, "longitude" => lon} = point) when map_size(point) == 2 do
    if Location.valid?(%{latitude: lat, longitude: lon}) do
      {:ok, %{latitude: number(lat), longitude: number(lon)}}
    else
      {:error, :invalid_request}
    end
  end

  defp coordinates(_point), do: {:error, :invalid_request}
  defp number(value) when value == 0, do: 0.0
  defp number(value), do: value / 1
end
