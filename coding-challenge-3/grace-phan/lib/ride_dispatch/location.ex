defmodule RideDispatch.Location do
  def valid?(%{latitude: latitude}) when latitude > 90, do: false
end
