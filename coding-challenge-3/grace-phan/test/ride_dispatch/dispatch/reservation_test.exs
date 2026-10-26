defmodule RideDispatch.Dispatch.ReservationTest do
  use ExUnit.Case, async: true

  alias RideDispatch.Dispatch.{StateServer, Store}

  test "Offer queries are read-only and isolated" do
    server = owner()
    assert Store.list_offers(server) == []
    assert Store.get_offer(server, "missing") == :not_found
    assert Store.list_offers(owner()) == []
  end

  test "matching policy defaults and explicit values are validated at startup" do
    assert {:ok, state} = StateServer.init([])
    assert state.matching_radius_km == 2.0
    assert state.offer_timeout_ms == 30_000

    assert {:ok, custom} = StateServer.init(matching_radius_km: 0, offer_timeout_ms: 1)
    assert custom.matching_radius_km == 0
    assert custom.offer_timeout_ms == 1

    for radius <- [-1, "2", nil, :infinity] do
      assert StateServer.init(matching_radius_km: radius) == {:stop, :invalid_matching_radius}
    end

    for timeout <- [0, -1, 1.5, "30000", nil] do
      assert StateServer.init(offer_timeout_ms: timeout) == {:stop, :invalid_offer_timeout}
    end
  end

  test "startup rejects invalid clocks and accepts negative monotonic milliseconds" do
    for clock <- [nil, fn _ -> 0 end, fn -> 0.0 end, fn -> nil end, fn -> raise "clock" end] do
      assert StateServer.init(clock: clock) == {:stop, :invalid_clock}
    end

    assert {:ok, _state} = StateServer.init(clock: fn -> -1_000_000 end)
  end

  defp owner(opts \\ []) do
    opts = Keyword.merge([passengers: [%{id: "P001"}], clock: fn -> 0 end], opts)
    start_supervised!(Supervisor.child_spec({StateServer, opts}, id: make_ref()))
  end
end
