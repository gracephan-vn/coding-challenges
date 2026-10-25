defmodule RideDispatch.Dispatch.StoreTest do
  use ExUnit.Case, async: true

  alias RideDispatch.Dispatch.{StateServer, Store}

  test "reads a seeded driver and reports an unknown ID" do
    driver = driver("D001")
    server = start_store([driver])

    assert Store.get_driver(server, driver.id) == {:ok, driver}
    assert Store.get_driver(server, "missing") == :not_found
  end

  test "lists only available drivers in lexicographic ID order" do
    first = driver("D10")
    second = driver("D2")
    offline = %{driver("D001") | status: :offline}
    server = start_store([second, offline, first])

    assert Store.list_available_drivers(server) == [first, second]
    assert Store.list_available_drivers(start_store([])) == []
  end

  test "separate instances own independent seeds and returned maps are immutable values" do
    original = driver("D001")
    first = start_store([original])
    second = start_store([])
    assert {:ok, returned} = Store.get_driver(first, original.id)
    changed = %{returned | latitude: 20.0}

    assert changed != original
    assert Store.get_driver(first, original.id) == {:ok, original}
    assert Store.get_driver(second, original.id) == :not_found
  end

  test "the application supervises a named state owner accessible through Store" do
    assert is_pid(Process.whereis(StateServer))
    assert Store.list_available_drivers(StateServer) == []
  end

  test "rejects duplicate seed IDs instead of overwriting a record" do
    Process.flag(:trap_exit, true)
    original = driver("D001")
    duplicate = %{original | longitude: 100.0}

    assert StateServer.start_link(drivers: [original, duplicate]) ==
             {:error, {:duplicate_driver_id, "D001"}}
  end

  test "rejects malformed driver seeds and states requiring an active ride" do
    Process.flag(:trap_exit, true)
    original = driver("D001")

    for invalid <- [
          %{original | status: :busy},
          %{original | status: :offered},
          %{original | status: :unknown},
          %{original | id: ""},
          %{original | id: 1},
          %{original | latitude: 91},
          %{original | longitude: -181},
          %{original | latitude: "10"},
          Map.delete(original, :id),
          Map.delete(original, :status),
          Map.delete(original, :latitude),
          Map.delete(original, :longitude),
          nil
        ] do
      assert StateServer.start_link(drivers: [invalid]) == {:error, :invalid_driver_seed}
    end
  end

  test "rejects non-list seed collections" do
    Process.flag(:trap_exit, true)

    for seeds <- [nil, %{}, "drivers"] do
      assert StateServer.start_link(drivers: seeds) == {:error, :invalid_driver_seeds}
    end
  end

  defp start_store(drivers) do
    start_supervised!(Supervisor.child_spec({StateServer, drivers: drivers}, id: make_ref()))
  end

  defp driver(id) do
    %{id: id, status: :available, latitude: 10.7769, longitude: 106.7009, label: "seed"}
  end
end
