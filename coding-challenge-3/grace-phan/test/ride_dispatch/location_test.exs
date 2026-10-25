defmodule RideDispatch.LocationTest do
  use ExUnit.Case, async: true

  alias RideDispatch.Location

  test "rejects latitude greater than 90" do
    assert Location.valid?(%{latitude: 91.0, longitude: 106.7009}) == false
  end

  test "accepts valid coordinates" do
    assert Location.valid?(%{latitude: 10.7769, longitude: 106.7009}) == true
  end

  test "accepts inclusive coordinate boundaries" do
    for latitude <- [-90, -90.0, 90, 90.0],
        longitude <- [-180, -180.0, 180, 180.0] do
      assert Location.valid?(%{latitude: latitude, longitude: longitude}) == true
    end
  end

  test "accepts zero coordinates" do
    assert Location.valid?(%{latitude: 0, longitude: 0}) == true
    assert Location.valid?(%{latitude: 0.0, longitude: -0.0}) == true
  end

  test "rejects latitude below minus 90" do
    for latitude <- [-91, -90.0001] do
      assert Location.valid?(%{latitude: latitude, longitude: 106.7009}) == false
    end
  end

  test "rejects latitude just above 90" do
    assert Location.valid?(%{latitude: 90.0001, longitude: 106.7009}) == false
  end

  test "rejects longitude below minus 180" do
    for longitude <- [-181, -180.0001] do
      assert Location.valid?(%{latitude: 10.7769, longitude: longitude}) == false
    end
  end

  test "rejects longitude above 180" do
    for longitude <- [181, 180.0001] do
      assert Location.valid?(%{latitude: 10.7769, longitude: longitude}) == false
    end
  end

  test "rejects missing coordinates" do
    for location <- [%{}, %{latitude: 10.7769}, %{longitude: 106.7009}] do
      assert Location.valid?(location) == false
    end
  end

  test "rejects non-map inputs" do
    for location <- [nil, true, false, 0, 10.0, "location", [], {10.7769, 106.7009}] do
      assert Location.valid?(location) == false
    end
  end

  test "rejects nonnumeric coordinates" do
    for value <- [nil, true, false, "10.7769", "", :invalid, [], %{}, {0, 0}],
        coordinate <- [:latitude, :longitude] do
      location = Map.put(%{latitude: 10.7769, longitude: 106.7009}, coordinate, value)
      assert Location.valid?(location) == false
    end
  end

  test "rejects non-finite representations" do
    # BEAM floats cannot represent NaN or infinity; reject these external representations.
    for value <- [:nan, :infinity, :neg_infinity, "NaN", "Infinity", "-Infinity"],
        coordinate <- [:latitude, :longitude] do
      location = Map.put(%{latitude: 10.7769, longitude: 106.7009}, coordinate, value)
      assert Location.valid?(location) == false
    end
  end

  test "rejects extreme finite numbers without raising" do
    for value <- [1.0e308, -1.0e308, Integer.pow(10, 400), -Integer.pow(10, 400)],
        coordinate <- [:latitude, :longitude] do
      location = Map.put(%{latitude: 10.7769, longitude: 106.7009}, coordinate, value)
      assert Location.valid?(location) == false
    end
  end
end
