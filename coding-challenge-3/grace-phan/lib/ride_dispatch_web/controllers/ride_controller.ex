defmodule RideDispatchWeb.RideController do
  use RideDispatchWeb, :controller

  alias RideDispatch.Rides
  alias RideDispatch.Dispatch.StateServer

  def create(conn, _params) do
    case get_req_header(conn, "idempotency-key") do
      [key] ->
        case Rides.create_ride(server(conn), key, conn.body_params) do
          {:ok, ride} ->
            conn
            |> put_status(201)
            |> put_resp_header("location", "/rides/" <> ride.id)
            |> json(%{data: public_ride(ride)})

          {:error, :idempotency_conflict} ->
            error(conn, 409, "Conflict")

          {:error, _reason} ->
            error(conn, 400, "Bad Request")
        end

      _missing_or_multiple ->
        error(conn, 400, "Bad Request")
    end
  end

  def show(conn, _params) do
    case Rides.get_ride(server(conn), conn.path_params["rideId"]) do
      {:ok, ride} -> json(conn, %{data: public_ride(ride)})
      :not_found -> error(conn, 404, "Not Found")
    end
  end

  defp server(conn), do: Map.get(conn.private, :dispatch_store, StateServer)

  defp error(conn, status, detail),
    do: conn |> put_status(status) |> json(%{errors: %{detail: detail}})

  defp public_ride(ride) do
    %{
      rideId: ride.id,
      passengerId: ride.passengerId,
      pickup: ride.pickup,
      destination: ride.destination,
      status: ride.status |> Atom.to_string() |> String.upcase(),
      assignedDriverId: ride.assignedDriverId
    }
  end
end
