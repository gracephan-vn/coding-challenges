defmodule RideDispatchWeb.RideLifecycleTest do
  use RideDispatchWeb.ConnCase, async: true
  import RideDispatch.OfferFixtures
  alias RideDispatch.Dispatch.Store
  alias RideDispatch.OfferFixtures.CallbackOwner

  for phase <- [:requested, :matching, :driver_assigned, :driver_accepted] do
    test "HTTP cancellation of #{phase} returns original result and current terminal GET" do
      {server, _} = owner()
      ride = prepare(server, unquote(phase), "original")
      before = :sys.get_state(server)
      response = request(server, ride.id, :cancel) |> json_response(200)
      assert response == public(ride, "CANCELLED", nil)
      state = :sys.get_state(server)
      assert request(server, ride.id, :cancel, %{}) |> json_response(200) == response
      assert conn(server) |> get("/rides/" <> ride.id) |> json_response(200) == response
      assert request(server, ride.id, :complete) |> json_response(409) == error("Conflict")
      assert :sys.get_state(server) == state
      assert state.drivers["A"].status == :available
      assert state.pending_events == before.pending_events
      assert state.rides[ride.id].terminal_receipt.original_result.status == :cancelled
    end
  end

  test "live HTTP completion, Driver reuse, original acceptance replay and obsolete expiration" do
    {server, _} = owner()
    first = http_create(server, "first")
    dispatch(server, first)
    accepted = conn(server) |> post("/rides/#{first.id}/offers/A/accept") |> json_response(200)
    {:ok, assigned} = Store.get_ride(server, first.id)
    old_offer = assigned.currentOfferId
    completed = request(server, first.id, :complete) |> json_response(200)
    assert completed == public(first, "COMPLETED", nil)
    assert {:ok, %{status: :available}} = Store.get_driver(server, "A")
    second = http_create(server, "second")
    dispatch(server, second)

    second_response =
      conn(server) |> post("/rides/#{second.id}/offers/A/accept") |> json_response(200)

    before = :sys.get_state(server)
    assert request(server, first.id, :complete, %{}) |> json_response(200) == completed

    assert conn(server) |> post("/rides/#{first.id}/offers/A/accept") |> json_response(200) ==
             accepted

    assert conn(server) |> post("/rides/#{first.id}/offers/A/reject") |> json_response(409) ==
             error("Conflict")

    assert Store.expire_offer(server, old_offer) == {:ok, :ignored}
    assert request(server, first.id, :cancel) |> json_response(409) == error("Conflict")
    assert conn(server) |> get("/rides/" <> second.id) |> json_response(200) == second_response
    assert before.drivers["A"].status == :busy
    assert map_size(before.offers) == 2 and map_size(before.pending_events) == 4
    assert conn(server) |> get("/rides/" <> first.id) |> json_response(200) == completed

    assert conn(server)
           |> put_req_header("idempotency-key", "first")
           |> post("/rides", body())
           |> json_response(201) == public(first, "REQUESTED", nil)

    assert :sys.get_state(server) == before
  end

  for operation <- [:cancel, :complete] do
    test "#{operation} rejects malformed payloads and unparsed bodies without state changes" do
      {server, _} = owner()
      ride = prepare(server, :driver_accepted, "payload")
      operation = unquote(operation)
      before = :sys.get_state(server)

      for payload <- [%{"extra" => true}, %{"rideId" => "other"}, [], [1], true, 1, nil] do
        assert conn(server)
               |> put_req_header("content-type", "application/json")
               |> post(command_path(ride.id, operation), Jason.encode!(payload))
               |> json_response(400) == error("Bad Request")
      end

      for type <- ["text/plain", "application/octet-stream"] do
        assert conn(server)
               |> put_req_header("content-type", type)
               |> post(command_path(ride.id, operation), "nonempty")
               |> json_response(400) == error("Bad Request")
      end

      assert_error_sent 400, fn ->
        conn(server)
        |> put_req_header("content-type", "application/json")
        |> post(command_path(ride.id, operation), "{")
      end

      assert :sys.get_state(server) == before
    end

    test "#{operation} maps unknown Ride and broken authoritative evidence consistently" do
      {server, ride, _, _} = reserved()

      assert request(server, "missing", unquote(operation)) |> json_response(404) ==
               error("Not Found")

      assert {:ok, _} = Store.accept_offer(server, ride.id, "A")
      state = put_in(:sys.get_state(server).rides[ride.id].assignedDriverId, "missing")
      fixture = start_supervised!({CallbackOwner, state})

      assert request(fixture, ride.id, unquote(operation)) |> json_response(500) ==
               error("Internal Server Error")

      assert :sys.get_state(fixture) == state
    end
  end

  test "completion conflicts in every nonaccepted source state without mutation" do
    for phase <- [:requested, :matching, :driver_assigned] do
      {server, _} = owner()
      ride = prepare(server, phase, "invalid")
      before = :sys.get_state(server)
      assert request(server, ride.id, :complete) |> json_response(409) == error("Conflict")
      assert :sys.get_state(server) == before
    end
  end

  test "external query fields cannot select a test Store or override path identity" do
    {server, ride, _, _} = reserved()
    state = :sys.get_state(server)
    # No conn.private injection: this request must use the application-owned Store.
    assert build_conn()
           |> post(
             command_path(ride.id, :cancel) <> "?dispatch_store=#{inspect(server)}&rideId=other"
           )
           |> json_response(404) == error("Not Found")

    assert :sys.get_state(server) == state
  end

  defp prepare(server, phase, key) do
    {:ok, ride} = Store.create_ride(server, key, body())

    if phase != :requested do
      created =
        Enum.find(Store.list_events(server), &(&1.rideId == ride.id and &1.type == :ride_created))

      assert Store.process_event(server, created.eventId) == {:ok, :processed}
    end

    if phase in [:driver_assigned, :driver_accepted],
      do: assert(Store.process_event(server, "dispatch-" <> ride.id) == {:ok, :processed})

    if phase == :driver_accepted, do: assert({:ok, _} = Store.accept_offer(server, ride.id, "A"))
    ride
  end

  defp http_create(server, key) do
    response =
      conn(server)
      |> put_req_header("idempotency-key", key)
      |> post("/rides", body())
      |> json_response(201)

    {:ok, ride} = Store.get_ride(server, response["data"]["rideId"])
    ride
  end

  defp dispatch(server, ride) do
    created =
      Enum.find(Store.list_events(server), &(&1.rideId == ride.id and &1.type == :ride_created))

    assert Store.process_event(server, created.eventId) == {:ok, :processed}
    assert Store.process_event(server, "dispatch-" <> ride.id) == {:ok, :processed}
  end

  defp conn(server),
    do:
      build_conn()
      |> put_private(:dispatch_store, server)
      |> put_req_header("accept", "application/json")

  defp command_path(id, operation), do: "/rides/#{id}/#{operation}"
  defp request(server, id, operation), do: conn(server) |> post(command_path(id, operation))

  defp request(server, id, operation, payload),
    do:
      conn(server)
      |> put_req_header("content-type", "application/json")
      |> post(command_path(id, operation), Jason.encode!(payload))

  defp error(detail), do: %{"errors" => %{"detail" => detail}}

  defp public(ride, status, driver),
    do: %{
      "data" => %{
        "rideId" => ride.id,
        "passengerId" => ride.passengerId,
        "pickup" => Map.new(ride.pickup, fn {k, v} -> {Atom.to_string(k), v} end),
        "destination" => Map.new(ride.destination, fn {k, v} -> {Atom.to_string(k), v} end),
        "status" => status,
        "assignedDriverId" => driver
      }
    }
end
