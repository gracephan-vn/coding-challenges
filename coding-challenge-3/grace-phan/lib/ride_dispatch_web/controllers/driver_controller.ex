defmodule RideDispatchWeb.DriverController do
  use RideDispatchWeb, :controller

  alias RideDispatch.Dispatch.{StateServer, Store}

  def availability(conn, _params) do
    result =
      Store.set_driver_availability(
        server(conn),
        conn.path_params["id"],
        conn.body_params["available"]
      )

    respond(conn, result)
  end

  def location(conn, _params) do
    location = %{
      latitude: conn.body_params["latitude"],
      longitude: conn.body_params["longitude"]
    }

    respond(conn, Store.update_driver_location(server(conn), conn.path_params["id"], location))
  end

  # Private metadata is set by trusted callers, never from HTTP request parameters.
  defp server(conn), do: Map.get(conn.private, :dispatch_store, StateServer)

  defp respond(conn, {:ok, driver}) do
    json(conn, %{
      data: %{
        id: driver.id,
        status: driver.status |> Atom.to_string() |> String.upcase(),
        latitude: driver.latitude,
        longitude: driver.longitude
      }
    })
  end

  defp respond(conn, :not_found) do
    conn |> put_status(404) |> json(%{errors: %{detail: "Not Found"}})
  end
end
