defmodule RideDispatch.LocationTest do
  use ExUnit.Case, async: true

  alias RideDispatch.Location

  describe "distance_km/2" do
    test "returns an error for invalid coordinates in either argument" do
      valid = %{latitude: 10.7769, longitude: 106.7009}

      for invalid <- [
            %{latitude: 91, longitude: 0},
            %{latitude: -91, longitude: 0},
            %{latitude: 0, longitude: 181},
            %{latitude: 0, longitude: -181},
            %{latitude: "10", longitude: 0},
            %{latitude: 0, longitude: :infinity},
            %{latitude: :nan, longitude: 0},
            %{latitude: 0},
            %{longitude: 0},
            %{},
            nil,
            []
          ] do
        assert Location.distance_km(invalid, valid) == {:error, :invalid_coordinates}
        assert Location.distance_km(valid, invalid) == {:error, :invalid_coordinates}
        assert Location.distance_km(invalid, invalid) == {:error, :invalid_coordinates}
      end
    end

    test "identical coordinates have zero distance" do
      location = %{latitude: 10.7769, longitude: 106.7009}
      assert_in_delta Location.distance_km(location, location), 0.0, 1.0e-9
    end

    test "calculates a short equatorial distance in kilometers" do
      from = %{latitude: 0, longitude: 0}
      to = %{latitude: 0, longitude: 0.01}
      assert_in_delta Location.distance_km(from, to), 1.1119493, 1.0e-6
    end

    test "accounts for latitude when calculating a great-circle distance" do
      # These points subtend 60 degrees at the center of a spherical Earth.
      from = %{latitude: 45, longitude: 0}
      to = %{latitude: 45, longitude: 90}
      assert_in_delta Location.distance_km(from, to), 6671.6956, 0.001
    end

    test "is symmetric and non-negative for southern and western coordinates" do
      from = %{latitude: -33.8688, longitude: 151.2093}
      to = %{latitude: 40.7128, longitude: -74.0060}
      forward = Location.distance_km(from, to)
      reverse = Location.distance_km(to, from)

      assert forward > 0
      assert reverse >= 0
      assert_in_delta forward, reverse, 1.0e-8
    end

    test "supports poles and antipodal points" do
      for {from, to} <- [
            {%{latitude: -90, longitude: -180}, %{latitude: 90, longitude: 180}},
            {%{latitude: 36.12, longitude: -86.67}, %{latitude: -36.12, longitude: 93.33}}
          ] do
        assert_in_delta Location.distance_km(from, to), 20015.0868, 0.001
      end
    end

    test "uses the short distance across the antimeridian" do
      from = %{latitude: 0, longitude: 179.99}
      to = %{latitude: 0, longitude: -179.99}
      assert_in_delta Location.distance_km(from, to), 2.2238985, 1.0e-6

      assert_in_delta Location.distance_km(
                        %{latitude: 0, longitude: -180},
                        %{latitude: 0, longitude: 180}
                      ),
                      0.0,
                      1.0e-9
    end
  end

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
