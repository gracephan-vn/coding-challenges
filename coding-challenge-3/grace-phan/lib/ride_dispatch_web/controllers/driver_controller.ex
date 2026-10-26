defmodule RideDispatchWeb.DriverController do
  @moduledoc """
  Driver JSON updates using body fields `available` or `latitude`/`longitude`.

  Successful updates return 200 with an explicit public driver under `data`.
  Store validation errors map to 400, unknown IDs to 404, and state conflicts to
  409, all using the existing `errors.detail` envelope. Store's unknown-ID
  precedence is preserved for parsed payloads. Malformed JSON is rejected by
  the Endpoint parser before any Store call. Extra body fields are ignored.
  """

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

  defp respond(conn, {:error, reason})
       when reason in [:invalid_availability, :invalid_coordinates] do
    conn |> put_status(400) |> json(%{errors: %{detail: "Bad Request"}})
  end

  defp respond(conn, {:error, reason}) when reason in [:invalid_transition, :invalid_state] do
    conn |> put_status(409) |> json(%{errors: %{detail: "Conflict"}})
  end
end
