defmodule RideDispatchWeb.RideControllerTest do
  use RideDispatchWeb.ConnCase, async: true
  alias RideDispatch.Dispatch.{StateServer, Store}

  setup do
    %{server: start_supervised!({StateServer, passengers: [%{id: "P001"}]})}
  end

  defp body do
    %{
      "passengerId" => "P001",
      "pickup" => %{"latitude" => 10.7769, "longitude" => 106.7009},
      "destination" => %{"latitude" => 10.8231, "longitude" => 106.6297}
    }
  end

  test "challenge request creates, replays original 201 and retrieves current ride", %{
    server: server
  } do
    conn = create(server, body())
    assert %{"data" => ride} = json_response(conn, 201)

    assert Map.keys(ride) |> Enum.sort() ==
             Enum.sort(~w(rideId passengerId pickup destination status assignedDriverId))

    assert ride["status"] == "REQUESTED"
    assert ride["passengerId"] == "P001"
    assert ride["assignedDriverId"] == nil
    assert ride["pickup"] == body()["pickup"]
    assert ride["destination"] == body()["destination"]
    assert get_resp_header(conn, "location") == ["/rides/" <> ride["rideId"]]
    assert create(server, body()) |> json_response(201) == %{"data" => ride}

    for _ <- 1..2,
        do: assert(read(server, ride["rideId"]) |> json_response(200) == %{"data" => ride})

    assert {:ok, stored} = Store.get_ride(server, ride["rideId"])
    assert stored.status == :requested
    other = create(server, body(), "another-key") |> json_response(201)
    refute other["data"]["rideId"] == ride["rideId"]
  end

  test "JSON ordering whitespace and numeric representation do not affect replay", %{
    server: server
  } do
    request = %{body() | "pickup" => %{"latitude" => 10, "longitude" => 106}}
    original = create(server, request) |> json_response(201)

    raw =
      ~s( { "destination": {"longitude":106.6297,"latitude":10.8231}, "pickup":{"longitude":106.0,"latitude":1e1}, "passengerId":"P001" } )

    assert conn(server)
           |> put_req_header("idempotency-key", "7f4d9c2e-ride-request-001")
           |> post("/rides", raw)
           |> json_response(201) == original
  end

  test "keys require exactly one nonblank header and query parameters cannot supply fields", %{
    server: server
  } do
    before = :sys.get_state(server)

    for key <- [nil, "", "   "] do
      assert create(server, body(), key) |> json_response(400) == error("Bad Request")
    end

    duplicate = %{
      conn(server)
      | req_headers: [
          {"idempotency-key", "a"},
          {"idempotency-key", "b"} | conn(server).req_headers
        ]
    }

    assert duplicate |> post("/rides", Jason.encode!(body())) |> json_response(400) ==
             error("Bad Request")

    assert conn(server)
           |> put_req_header("idempotency-key", "key")
           |> post("/rides?passengerId=P001", "{}")
           |> json_response(400) == error("Bad Request")

    assert :sys.get_state(server) == before
  end

  test "strict malformed fields and unknown passengers are 400 with no side effects", %{
    server: server
  } do
    before = :sys.get_state(server)

    invalid = [
      nil,
      [],
      true,
      %{},
      Map.put(body(), "extra", 1),
      Map.put(body(), "passengerId", "unknown"),
      Map.put(body(), "pickup", "bad"),
      put_in(body(), ["destination", "extra"], 1),
      put_in(body(), ["pickup", "latitude"], 91),
      put_in(body(), ["destination", "longitude"], -181),
      put_in(body(), ["pickup", "latitude"], "10")
    ]

    for payload <- invalid do
      assert create(server, payload) |> json_response(400) == error("Bad Request")
      assert :sys.get_state(server) == before
    end
  end

  test "valid boundaries are accepted", %{server: server} do
    payload = %{
      body()
      | "pickup" => %{"latitude" => -90, "longitude" => -180},
        "destination" => %{"latitude" => 90, "longitude" => 180}
    }

    assert create(server, payload).status == 201
  end

  test "conflicting canonical payload is 409 even for unknown passenger; malformed remains 400",
       %{server: server} do
    assert create(server, body()).status == 201
    before = :sys.get_state(server)

    for payload <- [
          Map.put(body(), "passengerId", "missing"),
          put_in(body(), ["pickup", "latitude"], 11)
        ] do
      assert create(server, payload) |> json_response(409) == error("Conflict")
    end

    assert create(server, Map.put(body(), "extra", 1)) |> json_response(400) ==
             error("Bad Request")

    assert :sys.get_state(server) == before
  end

  test "actual malformed JSON syntax is rejected by Endpoint", %{server: server} do
    before = :sys.get_state(server)

    {400, _headers, response} =
      assert_error_sent 400, fn ->
        conn(server) |> put_req_header("idempotency-key", "key") |> post("/rides", ~s({"broken":))
      end

    assert Jason.decode!(response) == error("Bad Request")
    assert :sys.get_state(server) == before
  end

  test "unknown rides and isolated owners return 404", %{server: server} do
    assert read(server, "missing") |> json_response(404) == error("Not Found")
    other = start_supervised!(Supervisor.child_spec({StateServer, []}, id: :other))
    %{"data" => ride} = create(server, body()) |> json_response(201)
    assert read(other, ride["rideId"]) |> json_response(404) == error("Not Found")
  end

  test "production uses the single supervised owner and seeded P001" do
    owner = Process.whereis(StateServer)
    assert :sys.get_state(owner).passengers["P001"] == %{id: "P001"}

    response =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get("/rides/missing")
      |> json_response(404)

    assert response == error("Not Found")
    assert Process.whereis(StateServer) == owner
  end

  test "asynchronous processing changes GET while POST replay retains original creation", %{
    server: server
  } do
    parent = self()
    handler = make_ref()

    :telemetry.attach(
      handler,
      [:ride_dispatch, :event, :processed],
      fn _, _, metadata, _ ->
        if metadata.server == server, do: send(parent, {:ride_processed, metadata.result})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    start_supervised!({RideDispatch.Dispatch.EventDispatcher, store: server})
    original = create(server, body()) |> json_response(201)
    assert original["data"]["status"] == "REQUESTED"
    assert_receive {:ride_processed, {:ok, :processed}}, 1000
    current = read(server, original["data"]["rideId"]) |> json_response(200)
    assert current == put_in(original, ["data", "status"], "MATCHING")
    assert create(server, body()) |> json_response(201) == original
    assert Enum.count(Store.list_events(server), &(&1.type == :dispatch_requested)) == 1
  end

  test "HTTP Driver updates feed asynchronous reservation and rejected availability preserves ownership" do
    server =
      start_supervised!(
        Supervisor.child_spec(
          {StateServer,
           passengers: [%{id: "P001"}],
           drivers: [
             %{id: "D001", status: :available, latitude: 10.7769, longitude: 106.7009},
             %{id: "D002", status: :offline, latitude: 10.777, longitude: 106.7009, label: "keep"}
           ]},
          id: :reservation_http
        )
      )

    assert conn(server)
           |> put("/drivers/D001/location", Jason.encode!(%{latitude: 0, longitude: 0}))
           |> json_response(200)

    assert conn(server)
           |> put("/drivers/D002/availability", Jason.encode!(%{available: true}))
           |> json_response(200)

    parent = self()
    handler = make_ref()

    :telemetry.attach(
      handler,
      [:ride_dispatch, :event, :processed],
      fn _, _, metadata, _ ->
        if metadata.server == server and String.starts_with?(metadata.event_id, "dispatch-") do
          send(parent, {:assigned, metadata.event_id, metadata.result})
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    start_supervised!({RideDispatch.Dispatch.EventDispatcher, store: server})
    original = create(server, body()) |> json_response(201)
    ride_id = original["data"]["rideId"]
    assert_receive {:assigned, event_id, {:ok, :processed}}, 1000
    assert event_id == "dispatch-" <> ride_id

    expected =
      original
      |> put_in(["data", "status"], "DRIVER_ASSIGNED")
      |> put_in(["data", "assignedDriverId"], "D002")

    assert read(server, ride_id) |> json_response(200) == expected
    assert create(server, body()) |> json_response(201) == original
    assert {:ok, %{status: :offered, label: "keep"}} = Store.get_driver(server, "D002")
    before = :sys.get_state(server)

    for available <- [false, true] do
      assert conn(server)
             |> put("/drivers/D002/availability", Jason.encode!(%{available: available}))
             |> json_response(409) == error("Conflict")
    end

    after_rejection = :sys.get_state(server)

    assert Map.take(after_rejection, [:drivers, :rides, :offers, :pending_events]) ==
             Map.take(before, [:drivers, :rides, :offers, :pending_events])

    assert [offer] = Store.list_offers(server)
    assert offer.driverId == "D002" and offer.rideId == ride_id and offer.status == :pending
  end

  defp conn(server),
    do:
      build_conn()
      |> put_private(:dispatch_store, server)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")

  defp create(server, payload, key \\ "7f4d9c2e-ride-request-001") do
    connection = conn(server)
    connection = if key, do: put_req_header(connection, "idempotency-key", key), else: connection
    post(connection, "/rides", Jason.encode!(payload))
  end

  defp read(server, id), do: conn(server) |> get("/rides/" <> id)
  defp error(detail), do: %{"errors" => %{"detail" => detail}}
end
