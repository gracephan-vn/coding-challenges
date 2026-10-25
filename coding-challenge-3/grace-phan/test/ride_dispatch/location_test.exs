defmodule RideDispatch.LocationTest do
  use ExUnit.Case, async: true

  alias RideDispatch.Location

  test "rejects latitude greater than 90" do
    assert Location.valid?(%{latitude: 91.0, longitude: 106.7009}) == false
  end
end
