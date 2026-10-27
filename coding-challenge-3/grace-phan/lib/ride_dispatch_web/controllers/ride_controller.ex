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

  def cancel(conn, _params), do: terminal_command(conn, &Rides.cancel_ride/2)
  def complete(conn, _params), do: terminal_command(conn, &Rides.complete_ride/2)

  defp terminal_command(conn, command) do
    command(conn, fn server, ride_id, _driver_id -> command.(server, ride_id) end)
  end

  def accept_offer(conn, _params), do: offer_command(conn, &Rides.accept_offer/3)
  def reject_offer(conn, _params), do: offer_command(conn, &Rides.reject_offer/3)

  defp offer_command(conn, operation), do: command(conn, operation)

  defp command(conn, command) do
    with true <- conn.body_params == %{},
         {:ok, "", conn} <- read_body(conn, length: 1, read_length: 1) do
      case command.(
             server(conn),
             conn.path_params["rideId"],
             conn.path_params["driverId"]
           ) do
        {:ok, original_ride} ->
          json(conn, %{data: public_ride(original_ride)})

        :not_found ->
          error(conn, 404, "Not Found")

        {:error, :invalid_request} ->
          error(conn, 400, "Bad Request")

        {:error, reason}
        when reason in [:wrong_driver, :offer_expired, :invalid_transition, :ambiguous_offer] ->
          error(conn, 409, "Conflict")

        {:error, _invariant_or_clock_failure} ->
          error(conn, 500, "Internal Server Error")
      end
    else
      {_, _body, conn} -> error(conn, 400, "Bad Request")
      _ -> error(conn, 400, "Bad Request")
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
