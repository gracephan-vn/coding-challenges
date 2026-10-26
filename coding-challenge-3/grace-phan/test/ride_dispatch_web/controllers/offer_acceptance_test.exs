defmodule RideDispatchWeb.OfferAcceptanceTest do
  use RideDispatchWeb.ConnCase, async: true
  alias RideDispatch.Dispatch.{StateServer, Store}

  setup do
    clock = :atomics.new(1, [])

    server =
      start_supervised!(
        {StateServer,
         passengers: [%{id: "P001"}],
         drivers: [
           %{id: "D001", status: :available, latitude: 0, longitude: 0},
           %{id: "D002", status: :offline, latitude: 0, longitude: 0}
         ],
         clock: fn ->
           case :atomics.get(clock, 1) do
             -1 -> nil
             time -> time
           end
         end}
      )

    body = %{
      "passengerId" => "P001",
      "pickup" => %{"latitude" => 0, "longitude" => 0},
      "destination" => %{"latitude" => 1, "longitude" => 1}
    }

    {:ok, ride} = Store.create_ride(server, "creation", body)
    [created] = Store.list_events(server)
    assert Store.process_event(server, created.eventId) == {:ok, :processed}
    assert Store.process_event(server, "dispatch-" <> ride.id) == {:ok, :processed}
    [offer] = Store.list_offers(server)
    %{server: server, ride: ride, offer: offer, clock: clock, body: body}
  end

  test "exact route accepts without body or idempotency header using the existing Ride JSON schema",
       c do
    before = :sys.get_state(c.server)
    response = request(c.server, c.ride.id, "D001") |> json_response(200)
    assert response == public_ride(c.ride, "DRIVER_ACCEPTED", "D001")
    assert {:ok, %{status: :busy}} = Store.get_driver(c.server, "D001")
    assert {:ok, %{status: :accepted, accepted_at_ms: 0}} = Store.get_offer(c.server, c.offer.id)
    assert connection(c.server) |> get("/rides/" <> c.ride.id) |> json_response(200) == response

    assert connection(c.server)
           |> put_req_header("content-type", "application/json")
           |> put_req_header("idempotency-key", "creation")
           |> post("/rides", Jason.encode!(c.body))
           |> json_response(201) == public_ride(c.ride, "REQUESTED", nil)

    after_acceptance = :sys.get_state(c.server)
    assert after_acceptance.pending_events == before.pending_events
    assert after_acceptance.idempotency == before.idempotency
    assert map_size(after_acceptance.offers) == 1
  end

  test "empty object, discarded-response retry and late replay return the original 200", c do
    original = json_request(c.server, c.ride.id, "D001", %{}) |> json_response(200)
    before = :sys.get_state(c.server)
    :atomics.put(c.clock, 1, c.offer.expires_at_ms + 1)
    assert request(c.server, c.ride.id, "D001") |> json_response(200) == original
    assert :sys.get_state(c.server) == before
  end

  test "unsupported fields and parsed non-object payloads are 400 without mutation", c do
    before = :sys.get_state(c.server)

    for payload <- [
          %{rideId: "other"},
          %{driverId: "D002"},
          %{offerId: "other"},
          %{now_ms: 0},
          %{dispatch_store: inspect(c.server)},
          [],
          nil,
          true,
          1
        ] do
      assert json_request(c.server, c.ride.id, "D001", payload) |> json_response(400) ==
               error("Bad Request")

      assert :sys.get_state(c.server) == before
    end
  end

  test "malformed JSON is rejected by the real Endpoint parser", c do
    before = :sys.get_state(c.server)

    {400, _, response} =
      assert_error_sent 400, fn ->
        connection(c.server)
        |> put_req_header("content-type", "application/json")
        |> post(accept_path(c.ride.id, "D001"), ~s({"broken":))
      end

    assert Jason.decode!(response) == error("Bad Request")
    assert :sys.get_state(c.server) == before
  end

  test "unknown resources/absent relationship are 404 and wrong owner/expired are 409", c do
    assert request(c.server, "missing", "D001") |> json_response(404) == error("Not Found")
    assert request(c.server, c.ride.id, "missing") |> json_response(404) == error("Not Found")
    {:ok, unassigned} = Store.create_ride(c.server, "no-offer", c.body)
    assert request(c.server, unassigned.id, "D001") |> json_response(404) == error("Not Found")
    before = :sys.get_state(c.server)
    assert request(c.server, c.ride.id, "D002") |> json_response(409) == error("Conflict")
    :atomics.put(c.clock, 1, c.offer.expires_at_ms)

    assert connection(c.server)
           |> post(accept_path(c.ride.id, "D001") <> "?now_ms=0&driverId=D002")
           |> json_response(409) == error("Conflict")

    assert :sys.get_state(c.server) == before
  end

  test "invalid trusted clock returns sanitized 500 with no acceptance", c do
    before = :sys.get_state(c.server)
    :atomics.put(c.clock, 1, -1)

    assert request(c.server, c.ride.id, "D001") |> json_response(500) ==
             error("Internal Server Error")

    assert :sys.get_state(c.server) == before
  end

  test "clients cannot select an isolated owner through query headers or JSON", c do
    before = :sys.get_state(c.server)
    production = Process.whereis(StateServer)

    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("dispatch-store", inspect(c.server))

    assert post(
             conn,
             accept_path(c.ride.id, "D001") <>
               "?dispatch_store=" <> URI.encode_www_form(inspect(c.server))
           )
           |> json_response(404) == error("Not Found")

    assert Process.whereis(StateServer) == production
    assert :sys.get_state(c.server) == before
  end

  defp connection(server),
    do:
      build_conn()
      |> put_private(:dispatch_store, server)
      |> put_req_header("accept", "application/json")

  defp accept_path(ride, driver), do: "/rides/#{ride}/offers/#{driver}/accept"
  defp request(server, ride, driver), do: post(connection(server), accept_path(ride, driver))

  defp json_request(server, ride, driver, body),
    do:
      connection(server)
      |> put_req_header("content-type", "application/json")
      |> post(accept_path(ride, driver), Jason.encode!(body))

  defp error(detail), do: %{"errors" => %{"detail" => detail}}

  defp public_ride(ride, status, driver),
    do: %{
      "data" => %{
        "rideId" => ride.id,
        "passengerId" => ride.passengerId,
        "pickup" => %{"latitude" => ride.pickup.latitude, "longitude" => ride.pickup.longitude},
        "destination" => %{
          "latitude" => ride.destination.latitude,
          "longitude" => ride.destination.longitude
        },
        "status" => status,
        "assignedDriverId" => driver
      }
    }
end
