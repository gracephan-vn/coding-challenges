defmodule RideDispatch.Location do
  def valid?(%{latitude: latitude, longitude: longitude}) do
    latitude >= -90 and latitude <= 90 and longitude >= -180 and longitude <= 180
  end
end
