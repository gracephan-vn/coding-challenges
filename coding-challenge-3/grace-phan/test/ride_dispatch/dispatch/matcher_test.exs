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

  defp driver(id, longitude) do
    %{id: id, status: :available, latitude: 0.0, longitude: longitude}
  end
end
