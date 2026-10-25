defmodule RideDispatch.Location do
  @earth_radius_km 6371.0

  def valid?(%{latitude: latitude, longitude: longitude})
      when is_number(latitude) and is_number(longitude) do
    latitude >= -90 and latitude <= 90 and longitude >= -180 and longitude <= 180
  end

  def valid?(_location), do: false

  @doc """
  Returns the spherical great-circle distance in kilometers, using a 6,371 km Earth radius.

  Returns `{:error, :invalid_coordinates}` if either coordinate map is invalid.
  """
  def distance_km(from, to) do
    if valid?(from) and valid?(to) do
      haversine_km(from, to)
    else
      {:error, :invalid_coordinates}
    end
  end

  defp haversine_km(from, to) do
    latitude_from = radians(from.latitude)
    latitude_to = radians(to.latitude)
    latitude_delta = latitude_to - latitude_from
    longitude_delta = radians(to.longitude - from.longitude)

    a =
      :math.pow(:math.sin(latitude_delta / 2), 2) +
        :math.cos(latitude_from) * :math.cos(latitude_to) *
          :math.pow(:math.sin(longitude_delta / 2), 2)

    # Roundoff near antipodal points can otherwise put a outside [0, 1].
    a = min(1.0, max(0.0, a))
    2 * @earth_radius_km * :math.atan2(:math.sqrt(a), :math.sqrt(1 - a))
  end

  defp radians(degrees), do: degrees * :math.pi() / 180
end
