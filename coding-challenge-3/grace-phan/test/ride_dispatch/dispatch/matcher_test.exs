defmodule RideDispatch.Dispatch.MatcherTest do
  use ExUnit.Case, async: true

  alias RideDispatch.Dispatch.Matcher

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

  defp driver(id, longitude) do
    %{id: id, status: :available, latitude: 0.0, longitude: longitude}
  end
end
