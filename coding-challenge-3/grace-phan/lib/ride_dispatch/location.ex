defmodule RideDispatch.Location do
  def valid?(%{latitude: latitude, longitude: longitude})
      when is_number(latitude) and is_number(longitude) do
    latitude >= -90 and latitude <= 90 and longitude >= -180 and longitude <= 180
  end

  def valid?(_location), do: false

  def distance_km(_from, _to), do: 0.0
end
