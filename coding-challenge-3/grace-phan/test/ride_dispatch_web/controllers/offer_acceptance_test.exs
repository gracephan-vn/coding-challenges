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

    for available <- [false, true] do
      assert connection(c.server)
             |> put_req_header("content-type", "application/json")
             |> put("/drivers/D001/availability", Jason.encode!(%{available: available}))
             |> json_response(409) == error("Conflict")
    end

    assert :sys.get_state(c.server) == after_acceptance
  end

  test "empty object, discarded-response retry and late replay return the original 200", c do
    task =
      Task.async(fn ->
        json_request(c.server, c.ride.id, "D001", %{})
        :response_discarded
      end)

    assert Task.await(task) == :response_discarded
    original = public_ride(c.ride, "DRIVER_ACCEPTED", "D001")
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

  test "unparsed nonempty request bodies cannot be mistaken for an empty command", c do
    before = :sys.get_state(c.server)

    for media_type <- ["text/plain", "application/octet-stream"] do
      conn = connection(c.server)
      conn = if media_type, do: put_req_header(conn, "content-type", media_type), else: conn

      assert post(conn, accept_path(c.ride.id, "D001"), "unsupported=1") |> json_response(400) ==
               error("Bad Request")

      assert :sys.get_state(c.server) == before
    end

    # ConnTest.post requires Content-Type for binary bodies; use the real Endpoint
    # directly to cover a body without that header as well.
    response =
      Plug.Test.conn(:post, accept_path(c.ride.id, "D001"), "unsupported=1")
      |> put_private(:dispatch_store, c.server)
      |> put_req_header("accept", "application/json")
      |> RideDispatchWeb.Endpoint.call(RideDispatchWeb.Endpoint.init([]))

    assert json_response(response, 400) == error("Bad Request")
    assert :sys.get_state(c.server) == before
  end

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

  test "concurrent HTTP acceptance requests return the same original result", c do
    parent = self()

    tasks =
      for _ <- 1..5 do
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> request(c.server, c.ride.id, "D001") |> json_response(200)
          end
        end)
      end

    for task <- tasks, do: assert_receive({:ready, pid} when pid == task.pid)
    for task <- tasks, do: send(task.pid, :go)
    assert [result] = tasks |> Enum.map(&Task.await/1) |> Enum.uniq()
    assert result == public_ride(c.ride, "DRIVER_ACCEPTED", "D001")
    assert [offer] = Store.list_offers(c.server)
    assert offer.id == c.offer.id and offer.status == :accepted and offer.accepted_at_ms == 0
    assert {:ok, %{status: :busy}} = Store.get_driver(c.server, "D001")
    assert length(Store.list_events(c.server)) == 2
  end

  test "mapping-only protocol fixture sanitizes ambiguous stale and invariant errors", c do
    for {reason, status, detail} <- [
          {:ambiguous_offer, 409, "Conflict"},
          {:invalid_transition, 409, "Conflict"},
          {:inconsistent_ownership, 500, "Internal Server Error"},
          {:invalid_request, 400, "Bad Request"}
        ] do
      fixture =
        start_supervised!(
          Supervisor.child_spec({__MODULE__.ErrorReply, {reason, self()}}, id: make_ref())
        )

      assert request(fixture, c.ride.id, "D001") |> json_response(status) == error(detail)
      assert_receive {:acceptance_called, ride_id, "D001"}
      assert ride_id == c.ride.id
    end

    # This fixture verifies response mapping only. Real invariant validation is
    # exercised separately by the actual StateServer callback tests.
    assert {:ok, %{status: :pending}} = Store.get_offer(c.server, c.offer.id)
  end

  defmodule ErrorReply do
    use GenServer
    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
    def init(opts), do: {:ok, opts}

    # Response-mapping fixture follows Store's internal observation envelope.
    def handle_call({:observed, command}, from, state), do: handle_call(command, from, state)

    def handle_call({:accept_offer, ride, driver}, _from, {reason, parent} = state) do
      send(parent, {:acceptance_called, ride, driver})
      {:reply, {:error, reason}, state}
    end
  end
end
