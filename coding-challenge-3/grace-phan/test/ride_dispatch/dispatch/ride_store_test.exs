defmodule RideDispatch.Dispatch.RideStoreTest do
  use ExUnit.Case, async: true
  alias RideDispatch.Dispatch.{StateServer, Store}

  defp request(id \\ "P001") do
    %{
      "passengerId" => id,
      "pickup" => %{"latitude" => 10, "longitude" => 106},
      "destination" => %{"latitude" => -90, "longitude" => 180}
    }
  end

  defp owner do
    start_supervised!({StateServer, passengers: [%{id: "P001"}, %{id: "P002"}]})
  end

  test "validates passenger seeds and duplicate IDs" do
    assert {:ok, state} = StateServer.init(passengers: [%{id: "P001", name: "Passenger"}])
    assert state.passengers == %{"P001" => %{id: "P001", name: "Passenger"}}

    for seed <- [nil, %{}, %{id: ""}, %{id: 1}] do
      assert StateServer.init(passengers: [seed]) == {:stop, :invalid_passenger_seed}
    end

    assert StateServer.init(passengers: nil) == {:stop, :invalid_passenger_seeds}

    assert StateServer.init(passengers: [%{id: "P001"}, %{id: "P001"}]) ==
             {:stop, {:duplicate_passenger_id, "P001"}}
  end

  test "creates unique requested rides and reads current stored records in isolation" do
    server = owner()
    assert {:ok, first} = Store.create_ride(server, "first", request())
    assert {:ok, second} = Store.create_ride(server, "second", request())
    assert is_binary(first.id) and first.id != ""
    refute first.id == second.id
    assert first.status == :requested
    assert first.assignedDriverId == nil
    assert first.passengerId == "P001"
    assert first.pickup == %{latitude: 10.0, longitude: 106.0}
    assert first.destination == %{latitude: -90.0, longitude: 180.0}
    for _ <- 1..2, do: assert(Store.get_ride(server, first.id) == {:ok, first})
    assert Store.get_ride(server, "missing") == :not_found
    other = start_supervised!(Supervisor.child_spec({StateServer, []}, id: :other))
    assert Store.get_ride(other, first.id) == :not_found
    assert Store.create_ride(other, "first", request()) == {:error, :passenger_not_found}
  end

  test "rejects invalid keys and requests before lookup without state changes" do
    {:ok, state} = StateServer.init(passengers: [%{id: "P001"}])

    for key <- [nil, "", " \t", [], 1] do
      assert {:reply, {:error, :invalid_idempotency_key}, ^state} =
               StateServer.handle_call({:create_ride, key, request()}, nil, state)
    end

    for body <- [
          %{},
          Map.put(request(), "extra", 1),
          put_in(request(), ["pickup", "latitude"], 91)
        ] do
      assert {:reply, {:error, :invalid_request}, ^state} =
               StateServer.handle_call({:create_ride, "key", body}, nil, state)
    end

    assert {:reply, {:error, :passenger_not_found}, ^state} =
             StateServer.handle_call({:create_ride, "key", request("missing")}, nil, state)
  end

  test "canonical retries return original result and conflicts leave all state unchanged" do
    {:ok, state} = StateServer.init(passengers: [%{id: "P001"}])

    assert {:reply, {:ok, ride}, created} =
             StateServer.handle_call({:create_ride, "key", request()}, nil, state)

    equivalent = put_in(request(), ["pickup", "latitude"], 10.0)

    assert {:reply, {:ok, ^ride}, ^created} =
             StateServer.handle_call({:create_ride, "key", equivalent}, nil, created)

    # Mutable passenger validation occurs only for new keys. This isolated callback
    # fixture does not mutate a live owner or introduce a production setter.
    without_passenger = %{created | passengers: %{}}

    assert {:reply, {:ok, ^ride}, ^without_passenger} =
             StateServer.handle_call({:create_ride, "key", equivalent}, nil, without_passenger)

    for different <- [request("missing"), put_in(request(), ["destination", "latitude"], 0)] do
      assert {:reply, {:error, :idempotency_conflict}, ^created} =
               StateServer.handle_call({:create_ride, "key", different}, nil, created)
    end

    assert {:reply, {:error, :invalid_request}, ^created} =
             StateServer.handle_call({:create_ride, "key", %{}}, nil, created)
  end

  test "one callback installs a ride, original result and distinct pending event together" do
    {:ok, state} = StateServer.init(passengers: [%{id: "P001"}])

    assert {:reply, {:ok, ride}, created} =
             StateServer.handle_call({:create_ride, "key", request()}, nil, state)

    assert created.rides == %{ride.id => ride}

    assert [%{eventId: event_id, rideId: ride_id, type: :ride_created, status: :pending}] =
             Map.values(created.pending_events)

    assert event_id != ride.id
    assert ride_id == ride.id
    assert Map.keys(created.pending_events) == [event_id]

    assert %{canonical_request: canonical, original_result: {:ok, ^ride}, event_id: ^event_id} =
             created.idempotency["key"]

    assert {:ok, ^canonical} = RideDispatch.Rides.Request.normalize(request())
    assert map_size(created.idempotency) == 1
    assert created.drivers == state.drivers
    assert created.passengers == state.passengers
  end

  test "competing duplicate commands and a lost-result retry create exactly one record of each kind" do
    server = owner()
    results = compete(for _ <- 1..20, do: fn -> Store.create_ride(server, "key", request()) end)
    assert [{:ok, ride}] = Enum.uniq(results)
    # Discarded response: retry the completed command against the surviving owner.
    assert Store.create_ride(server, "key", request()) == {:ok, ride}
    state = :sys.get_state(server)
    assert map_size(state.rides) == 1
    assert map_size(state.idempotency) == 1
    assert map_size(state.pending_events) == 1
    assert state.rides[ride.id] == ride
  end

  test "competing different requests have one winner without assuming ordering" do
    server = owner()

    results =
      compete(
        for passenger <- ["P001", "P002"],
            do: fn -> Store.create_ride(server, "key", request(passenger)) end
      )

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :idempotency_conflict})) == 1
    state = :sys.get_state(server)
    assert map_size(state.rides) == 1
    assert map_size(state.idempotency) == 1
    assert map_size(state.pending_events) == 1
  end

  defp compete(commands) do
    parent = self()
    ref = make_ref()

    tasks =
      Enum.map(commands, fn command ->
        Task.async(fn ->
          send(parent, {:ready, ref, self()})

          receive do
            {:go, ^ref} -> command.()
          end
        end)
      end)

    for _ <- tasks, do: assert_receive({:ready, ^ref, _})
    for task <- tasks, do: send(task.pid, {:go, ref})
    Enum.map(tasks, &Task.await/1)
  end
end
