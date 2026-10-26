defmodule RideDispatchWeb.DriverControllerTest do
  use RideDispatchWeb.ConnCase, async: true

  alias RideDispatch.Dispatch.{StateServer, Store}

  setup do
    driver = %{
      id: "D001",
      status: :offline,
      latitude: 10.7769,
      longitude: 106.7009,
      label: "private",
      metadata: %{secret: "not serialized"}
    }

    server = start_supervised!({StateServer, drivers: [driver]})
    %{server: server, driver: driver}
  end

  test "availability enables, repeats, and disables through the exact route", context do
    %{server: server, driver: driver} = context

    for available? <- [true, true, false, false] do
      conn = request(server, "/drivers/D001/availability", %{"available" => available?})
      expected = %{driver | status: if(available?, do: :available, else: :offline)}
      assert json_response(conn, 200) == %{"data" => public_driver(expected)}
      assert Store.get_driver(server, driver.id) == {:ok, expected}
    end
  end

  test "location updates preserve unrelated fields and return an explicit public schema",
       context do
    %{server: server, driver: driver} = context

    for location <- [
          %{"latitude" => 1.0, "longitude" => 2.0},
          %{"latitude" => -90, "longitude" => -180},
          %{"latitude" => 90, "longitude" => 180}
        ] do
      body = Map.merge(location, %{"status" => "BUSY", "id" => "D002", "label" => "changed"})
      conn = request(server, "/drivers/D001/location", body)
      expected = %{driver | latitude: location["latitude"], longitude: location["longitude"]}
      assert json_response(conn, 200) == %{"data" => public_driver(expected)}
      assert Store.get_driver(server, driver.id) == {:ok, expected}
    end

    assert Store.get_driver(server, "D002") == :not_found
  end

  test "unknown IDs return a consistent JSON 404", %{server: server} do
    for {endpoint, body} <- [
          {"availability", %{"available" => true}},
          {"location", %{"latitude" => 0, "longitude" => 0}}
        ] do
      conn = request(server, "/drivers/missing/#{endpoint}", body)
      assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
    end
  end

  test "requests without injection use the application-owned StateServer" do
    owner = Process.whereis(StateServer)

    conn =
      build_conn()
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json")
      |> put("/drivers/missing/availability", ~s({"available":true}))

    assert json_response(conn, 404) == %{"errors" => %{"detail" => "Not Found"}}
    assert Process.whereis(StateServer) == owner
  end

  test "HTTP updates remain isolated between per-connection owners", %{
    server: server,
    driver: driver
  } do
    other = start_supervised!(Supervisor.child_spec({StateServer, drivers: [driver]}, id: :other))
    assert request(server, "/drivers/D001/availability", %{"available" => true}).status == 200
    assert Store.get_driver(other, driver.id) == {:ok, driver}
  end

  test "invalid booleans return JSON 400 and preserve stored data", %{
    server: server,
    driver: driver
  } do
    for value <- [nil, "true", "false", 0, 1, [], %{}] do
      conn = request(server, "/drivers/D001/availability", %{"available" => value})
      assert json_response(conn, 400) == %{"errors" => %{"detail" => "Bad Request"}}
      assert Store.get_driver(server, driver.id) == {:ok, driver}
    end
  end

  test "invalid coordinates return JSON 400 without changing either coordinate", context do
    %{server: server, driver: driver} = context

    for {latitude, longitude} <- [
          {91, 0},
          {-91, 0},
          {0, 181},
          {0, -181},
          {"10", 0},
          {0, "106"},
          {nil, 0},
          {0, true},
          {[], 0},
          {0, %{}}
        ] do
      conn =
        request(server, "/drivers/D001/location", %{
          "latitude" => latitude,
          "longitude" => longitude
        })

      assert json_response(conn, 400) == %{"errors" => %{"detail" => "Bad Request"}}
      assert Store.get_driver(server, driver.id) == {:ok, driver}
    end
  end

  test "missing fields and parsed non-object JSON have a consistent 400 response", context do
    %{server: server, driver: driver} = context

    for {endpoint, body} <- [
          {"availability", %{}},
          {"availability", %{"availability" => true}},
          {"availability", []},
          {"availability", true},
          {"availability", nil},
          {"location", %{}},
          {"location", %{"latitude" => 0}},
          {"location", %{"longitude" => 0}},
          {"location", %{"location" => %{"latitude" => 0, "longitude" => 0}}},
          {"location", [0, 0]},
          {"location", "coordinates"}
        ] do
      conn = request(server, "/drivers/D001/#{endpoint}", body)
      assert json_response(conn, 400) == %{"errors" => %{"detail" => "Bad Request"}}
      assert Store.get_driver(server, driver.id) == {:ok, driver}
    end
  end

  test "query parameters cannot supply required body fields", %{server: server, driver: driver} do
    for path <- [
          "/drivers/D001/availability?available=true",
          "/drivers/D001/location?latitude=0&longitude=0"
        ] do
      assert request(server, path, %{}) |> json_response(400) ==
               %{"errors" => %{"detail" => "Bad Request"}}
    end

    assert Store.get_driver(server, driver.id) == {:ok, driver}
  end

  test "malformed JSON syntax is rendered as 400 by the Endpoint before the controller",
       context do
    %{server: server, driver: driver} = context

    for endpoint <- ["availability", "location"] do
      {400, headers, body} =
        assert_error_sent 400, fn ->
          build_conn()
          |> put_private(:dispatch_store, server)
          |> put_req_header("content-type", "application/json")
          |> put_req_header("accept", "application/json")
          |> put("/drivers/D001/#{endpoint}", ~s({"broken":))
        end

      assert {"content-type", "application/json; charset=utf-8"} in headers
      assert Jason.decode!(body) == %{"errors" => %{"detail" => "Bad Request"}}
      assert Store.get_driver(server, driver.id) == {:ok, driver}
    end
  end

  test "Store transition rejection maps a valid availability command to JSON 409", context do
    # Response-only protocol fixture: no invalid Driver state or live-state backdoor.
    # Actual offered/busy rejection is covered by Store callback and StateMachine tests.
    conflict = start_supervised!({__MODULE__.ConflictReply, self()})
    conn = request(conflict, "/drivers/D001/availability", %{"available" => false})
    assert json_response(conn, 409) == %{"errors" => %{"detail" => "Conflict"}}
    assert_receive {:availability_command, "D001", false}
    assert Store.get_driver(context.server, context.driver.id) == {:ok, context.driver}
  end

  defmodule ConflictReply do
    use GenServer
    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    @impl true
    def init(owner), do: {:ok, owner}
    @impl true
    def handle_call({:set_driver_availability, id, available?}, _from, owner) do
      send(owner, {:availability_command, id, available?})
      {:reply, {:error, :invalid_transition}, owner}
    end
  end

  defp request(server, path, body) do
    build_conn()
    |> put_private(:dispatch_store, server)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "application/json")
    |> put(path, Jason.encode!(body))
  end

  defp public_driver(driver) do
    %{
      "id" => driver.id,
      "status" => driver.status |> Atom.to_string() |> String.upcase(),
      "latitude" => driver.latitude,
      "longitude" => driver.longitude
    }
  end
end
