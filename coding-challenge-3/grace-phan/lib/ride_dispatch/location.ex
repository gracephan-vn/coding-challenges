defmodule RideDispatch.Location do
  def valid?(%{latitude: latitude}) when latitude > 90, do: false
  def valid?(%{latitude: _latitude, longitude: _longitude}), do: true
end
