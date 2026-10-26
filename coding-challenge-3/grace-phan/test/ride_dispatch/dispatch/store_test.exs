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

  test "updates both coordinates while preserving status and unrelated fields" do
    original = %{driver("D001") | status: :offline}
    server = start_store([original])
    location = %{latitude: -90, longitude: 180, status: :available, label: "ignored"}
    expected = %{original | latitude: -90, longitude: 180}

    assert Store.update_driver_location(server, original.id, location) == {:ok, expected}
    assert Store.get_driver(server, original.id) == {:ok, expected}
    assert Store.list_available_drivers(server) == []
  end

  test "invalid location commands leave state unchanged" do
    original = driver("D001")
    server = start_store([original])

    for location <- [
          nil,
          %{},
          %{latitude: 0},
          %{longitude: 0},
          %{latitude: 91, longitude: 0},
          %{latitude: 0, longitude: -181},
          %{latitude: "0", longitude: 0},
          %{latitude: 0, longitude: :infinity}
        ] do
      assert Store.update_driver_location(server, original.id, location) ==
               {:error, :invalid_coordinates}

      assert Store.get_driver(server, original.id) == {:ok, original}
    end
  end

  test "updating an unknown driver returns not_found without creating it" do
    server = start_store([])

    assert Store.update_driver_location(server, "missing", %{latitude: 0, longitude: 0}) ==
             :not_found

    assert Store.get_driver(server, "missing") == :not_found
    assert Store.list_available_drivers(server) == []
  end

  test "updates remain isolated between owners and returned values" do
    original = driver("D001")
    first = start_store([original])
    second = start_store([original])

    assert {:ok, updated} =
             Store.update_driver_location(first, original.id, %{latitude: 1, longitude: 2})

    changed = %{updated | latitude: 3}

    assert changed != updated
    assert Store.get_driver(first, original.id) == {:ok, updated}
    assert Store.get_driver(second, original.id) == {:ok, original}
  end

  test "competing callers preserve updates to different drivers on the same owner" do
    first = driver("D001")
    second = driver("D002")
    server = start_store([first, second])
    first_location = %{latitude: 1, longitude: 2}
    second_location = %{latitude: 3, longitude: 4}

    results =
      compete([
        fn -> Store.update_driver_location(server, first.id, first_location) end,
        fn -> Store.update_driver_location(server, second.id, second_location) end
      ])

    expected_first = Map.merge(first, first_location)
    expected_second = Map.merge(second, second_location)
    assert results == [{:ok, expected_first}, {:ok, expected_second}]
    assert Store.get_driver(server, first.id) == {:ok, expected_first}
    assert Store.get_driver(server, second.id) == {:ok, expected_second}
  end

  test "competing updates and reads never expose mixed coordinate pairs" do
    original = driver("D001")
    server = start_store([original])
    locations = [%{latitude: 1, longitude: 2}, %{latitude: 3, longitude: 4}]
    expected = Enum.map(locations, &Map.merge(original, &1))

    observations =
      compete(
        for location <- locations do
          fn ->
            for _ <- 1..25 do
              assert Store.update_driver_location(server, original.id, location) ==
                       {:ok, Map.merge(original, location)}

              assert {:ok, observed} = Store.get_driver(server, original.id)
              observed
            end
          end
        end
      )

    assert Enum.all?(List.flatten(observations), &(&1 in expected))
    assert {:ok, final} = Store.get_driver(server, original.id)
    assert final in expected
  end

  test "availability commands enable and disable while preserving all other fields" do
    original = %{driver("D001") | status: :offline}
    server = start_store([original])
    available = %{original | status: :available}

    assert Store.set_driver_availability(server, original.id, true) == {:ok, available}
    assert Store.get_driver(server, original.id) == {:ok, available}
    assert Store.list_available_drivers(server) == [available]
    assert Store.set_driver_availability(server, original.id, false) == {:ok, original}
    assert Store.get_driver(server, original.id) == {:ok, original}
    assert Store.list_available_drivers(server) == []
  end

  test "repeated availability requests succeed unchanged" do
    for {status, available?} <- [offline: false, available: true] do
      original = %{driver("D001") | status: status}
      server = start_store([original])
      assert Store.set_driver_availability(server, original.id, available?) == {:ok, original}
      assert Store.set_driver_availability(server, original.id, available?) == {:ok, original}
      assert Store.get_driver(server, original.id) == {:ok, original}
    end
  end

  test "availability commands return not_found for unknown IDs" do
    server = start_store([])

    for available? <- [true, false] do
      assert Store.set_driver_availability(server, "missing", available?) == :not_found
    end

    assert Store.list_available_drivers(server) == []
  end

  test "availability callback rejects offered and busy drivers without changing state" do
    # These states cannot be seeded or reached through current Store commands.
    # Exercise the callback with values, without mutating any live StateServer.
    for status <- [:offered, :busy], available? <- [true, false] do
      original = %{driver("D001") | status: status}
      state = %{drivers: %{original.id => original}}

      assert StateServer.handle_call(
               {:set_driver_availability, original.id, available?},
               {self(), make_ref()},
               state
             ) == {:reply, {:error, :invalid_transition}, state}
    end
  end

  test "availability callback propagates the State Machine invalid-state result" do
    original = %{driver("D001") | status: :unknown}
    state = %{drivers: %{original.id => original}}

    assert StateServer.handle_call(
             {:set_driver_availability, original.id, true},
             {self(), make_ref()},
             state
           ) == {:reply, {:error, :invalid_state}, state}
  end

  test "competing enable and disable requests allow either serialization order" do
    original = %{driver("D001") | status: :offline}
    server = start_store([original])
    available = %{original | status: :available}

    results =
      compete([
        fn -> Store.set_driver_availability(server, original.id, true) end,
        fn -> Store.set_driver_availability(server, original.id, false) end
      ])

    assert results == [{:ok, available}, {:ok, original}]
    assert {:ok, final} = Store.get_driver(server, original.id)
    assert final in [original, available]

    assert Store.list_available_drivers(server) ==
             if(final.status == :available, do: [final], else: [])
  end

  test "competing availability and location commands have a complete serial history" do
    original = %{driver("D001") | status: :offline}
    server = start_store([original])
    location = %{latitude: 1, longitude: 2}
    enabled = %{original | status: :available}
    moved = Map.merge(original, location)
    final = %{moved | status: :available}

    results =
      compete([
        fn -> Store.set_driver_availability(server, original.id, true) end,
        fn -> Store.update_driver_location(server, original.id, location) end
      ])

    assert results in [
             [{:ok, enabled}, {:ok, final}],
             [{:ok, final}, {:ok, moved}]
           ]

    assert Store.get_driver(server, original.id) == {:ok, final}
  end

  test "nonboolean availability is rejected without changing a driver" do
    original = %{driver("D001") | status: :offline}
    server = start_store([original])

    for invalid <- [nil, "false", "true", 0, 1, :available, %{}] do
      assert Store.set_driver_availability(server, original.id, invalid) ==
               {:error, :invalid_availability}

      assert Store.get_driver(server, original.id) == {:ok, original}
      assert Store.set_driver_availability(server, "missing", invalid) == :not_found
    end
  end

  defp compete(functions) do
    parent = self()
    gate = make_ref()

    tasks =
      Enum.map(functions, fn function ->
        Task.async(fn ->
          send(parent, {:ready, gate, self()})

          receive do
            {:go, ^gate} -> function.()
          end
        end)
      end)

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^gate, ^pid}, 1000
    end

    Enum.each(tasks, &send(&1.pid, {:go, gate}))
    Enum.map(tasks, &Task.await/1)
  end

  defp start_store(drivers) do
    start_supervised!(Supervisor.child_spec({StateServer, drivers: drivers}, id: make_ref()))
  end

  defp driver(id) do
    %{id: id, status: :available, latitude: 10.7769, longitude: 106.7009, label: "seed"}
  end
end
