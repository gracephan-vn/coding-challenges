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
