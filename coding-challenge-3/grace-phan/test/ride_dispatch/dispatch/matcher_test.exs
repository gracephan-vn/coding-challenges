defmodule RideDispatch.Dispatch.MatcherTest do
  use ExUnit.Case, async: true

  alias RideDispatch.Dispatch.Matcher
  alias RideDispatch.Location

  @pickup %{latitude: 0.0, longitude: 0.0}

  test "selects the nearest available driver regardless of input order" do
    near = driver("D002", 0.005)
    far = driver("D001", 0.01)
    assert Matcher.nearest(@pickup, [far, near]) == {:ok, near}
    assert Matcher.nearest(@pickup, [near, far]) == {:ok, near}
  end

  test "ignores offline, offered, and busy drivers" do
    available = driver("D004", 0.01)

    unavailable =
      for {status, id} <- [offline: "D001", offered: "D002", busy: "D003"] do
        %{driver(id, 0.0) | status: status}
      end

    assert Matcher.nearest(@pickup, unavailable ++ [available]) == {:ok, available}
    assert Matcher.nearest(@pickup, unavailable) == :none
  end

  test "returns none for an empty candidate list" do
    assert Matcher.nearest(@pickup, []) == :none
  end

  test "defaults to a 2 km radius and allows a configured radius" do
    inside = driver("D001", 0.01798)
    outside = driver("D002", 0.01799)
    assert Location.distance_km(@pickup, inside) < 2.0
    assert Location.distance_km(@pickup, outside) > 2.0
    assert Matcher.nearest(@pickup, [inside]) == {:ok, inside}
    assert Matcher.nearest(@pickup, [outside]) == :none
    assert Matcher.nearest(@pickup, [outside], radius_km: 3.0) == {:ok, outside}
    assert Matcher.nearest(@pickup, [inside], radius_km: 1.0) == :none
  end

  test "includes the exact radius boundary and excludes a point just beyond it" do
    boundary = driver("D001", 0.01)
    beyond = driver("D002", 0.010000001)
    radius = Location.distance_km(@pickup, boundary)
    assert Matcher.nearest(@pickup, [boundary], radius_km: radius) == {:ok, boundary}
    assert Matcher.nearest(@pickup, [beyond], radius_km: radius) == :none
  end

  test "zero radius includes only colocated drivers" do
    colocated = driver("D001", 0.0)
    assert Matcher.nearest(@pickup, [colocated], radius_km: 0) == {:ok, colocated}
    assert Matcher.nearest(@pickup, [driver("D002", 0.000001)], radius_km: 0) == :none
  end

  test "breaks exact distance ties lexicographically regardless of input order" do
    first = driver("D10", 0.01)
    second = driver("D2", 0.01)
    assert Matcher.nearest(@pickup, [second, first]) == {:ok, first}
    assert Matcher.nearest(@pickup, [first, second]) == {:ok, first}
  end

  test "excludes rejected and timed-out driver IDs for this ride" do
    rejected = driver("D001", 0.001)
    timed_out = driver("D002", 0.002)
    next = driver("D003", 0.003)
    drivers = [rejected, timed_out, next]
    opts = [excluded_driver_ids: [rejected.id, timed_out.id]]

    assert Matcher.nearest(@pickup, drivers, opts) == {:ok, next}
    assert Matcher.nearest(@pickup, [rejected, timed_out], opts) == :none
    assert Matcher.nearest(@pickup, drivers, opts) == {:ok, next}
  end

  test "exclusions do not leak to another ride or mutate drivers" do
    first = driver("D001", 0.001)
    second = driver("D002", 0.002)
    drivers = [first, second]
    original = :erlang.term_to_binary(drivers)

    assert Matcher.nearest(@pickup, drivers, excluded_driver_ids: [first.id]) == {:ok, second}
    assert Matcher.nearest(@pickup, drivers) == {:ok, first}
    assert :erlang.term_to_binary(drivers) == original
    assert first.status == :available
  end

  test "rejects invalid pickups even without candidates" do
    for pickup <- [
          nil,
          %{},
          %{latitude: 0},
          %{latitude: 91, longitude: 0},
          %{latitude: 0, longitude: -181},
          %{latitude: "0", longitude: 0}
        ] do
      assert Matcher.nearest(pickup, []) == {:error, :invalid_pickup}
      assert Matcher.nearest(pickup, [driver("D001", 0.0)]) == {:error, :invalid_pickup}
    end
  end

  test "never selects drivers with missing or invalid coordinates" do
    valid = driver("D100", 0.01)

    for invalid <- [
          Map.delete(driver("D001", 0.0), :latitude),
          Map.delete(driver("D001", 0.0), :longitude),
          %{driver("D001", 0.0) | latitude: -91},
          %{driver("D001", 0.0) | longitude: 181},
          %{driver("D001", 0.0) | latitude: nil},
          %{driver("D001", 0.0) | longitude: :infinity}
        ] do
      assert Matcher.nearest(@pickup, [invalid]) == :none
      assert Matcher.nearest(@pickup, [invalid, valid]) == {:ok, valid}
    end
  end

  test "skips malformed drivers and unsupported statuses" do
    valid = driver("D100", 0.01)

    invalid = [
      nil,
      %{},
      Map.delete(driver("D001", 0.0), :id),
      %{driver("D001", 0.0) | id: 1},
      Map.delete(driver("D001", 0.0), :status),
      %{driver("D001", 0.0) | status: :unknown}
    ]

    assert Matcher.nearest(@pickup, invalid) == :none
    assert Matcher.nearest(@pickup, invalid ++ [valid]) == {:ok, valid}
  end

  test "rejects invalid radius configuration" do
    for radius <- [-1, "2", nil, :infinity] do
      assert Matcher.nearest(@pickup, [], radius_km: radius) == {:error, :invalid_radius}

      assert Matcher.nearest(@pickup, [driver("D001", 0.0)], radius_km: radius) ==
               {:error, :invalid_radius}
    end
  end

  defp driver(id, longitude) do
    %{id: id, status: :available, latitude: 0.0, longitude: longitude}
  end
end
