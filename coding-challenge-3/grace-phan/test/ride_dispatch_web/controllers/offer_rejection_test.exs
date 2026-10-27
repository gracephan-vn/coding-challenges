defmodule RideDispatchWeb.OfferRejectionTest do
  use RideDispatchWeb.ConnCase, async: true
  alias RideDispatch.Dispatch.{EventDispatcher, StateServer, Store}

  setup do
    clock = :atomics.new(1, [])

    server =
      start_supervised!(
        {StateServer,
         passengers: [%{id: "P"}],
         drivers: [
           %{id: "A", status: :available, latitude: 0, longitude: 0, label: "keep"},
           %{id: "B", status: :offline, latitude: 0, longitude: 0}
         ],
         clock: fn ->
           case :atomics.get(clock, 1) do
             -1 -> nil
             n -> n
           end
         end}
      )

    body = %{
      "passengerId" => "P",
      "pickup" => %{"latitude" => 0, "longitude" => 0},
      "destination" => %{"latitude" => 1, "longitude" => 1}
    }

    {:ok, ride} = Store.create_ride(server, "original", body)
    [created] = Store.list_events(server)
    assert {:ok, :processed} = Store.process_event(server, created.eventId)
    assert {:ok, :processed} = Store.process_event(server, "dispatch-" <> ride.id)
    [offer] = Store.list_offers(server)
    %{server: server, ride: ride, offer: offer, clock: clock, body: body}
  end

  test "specified route rejects without body/header, returning MATCHING in the established envelope",
       c do
    response = request(c.server, c.ride.id, "A") |> json_response(200)
    assert response == public_ride(c.ride, "MATCHING", nil)
    assert connection(c.server) |> get("/rides/" <> c.ride.id) |> json_response(200) == response
    assert {:ok, %{status: :available, label: "keep"}} = Store.get_driver(c.server, "A")

    assert {:ok, %{status: :rejected, rejection_receipt: receipt}} =
             Store.get_offer(c.server, c.offer.id)

    assert receipt.offerId == c.offer.id

    assert {:ok, %{status: :pending, rideId: ride_id, type: :dispatch_requested}} =
             Store.get_event(c.server, "redispatch-" <> c.offer.id)

    assert ride_id == c.ride.id
    before = :sys.get_state(c.server)
    assert json_request(c.server, c.ride.id, "A", %{}) |> json_response(200) == response
    assert :sys.get_state(c.server) == before

    assert connection(c.server)
           |> put_req_header("content-type", "application/json")
           |> put_req_header("idempotency-key", "original")
           |> post("/rides", Jason.encode!(c.body))
           |> json_response(201) == public_ride(c.ride, "REQUESTED", nil)
  end

  test "a completed HTTP response may be discarded and retried without another redispatch", c do
    task =
      Task.async(fn ->
        request(c.server, c.ride.id, "A")
        :response_discarded
      end)

    assert Task.await(task) == :response_discarded
    before = :sys.get_state(c.server)

    assert request(c.server, c.ride.id, "A") |> json_response(200) ==
             public_ride(c.ride, "MATCHING", nil)

    assert :sys.get_state(c.server) == before
    assert before.offers[c.offer.id].rejection_receipt.original_result == before.rides[c.ride.id]
    assert map_size(before.pending_events) == 3
    assert before.pending_events["redispatch-" <> c.offer.id].status == :pending
  end

  test "strict command bodies reject unsupported fields and parsed non-object JSON without mutation",
       c do
    before = :sys.get_state(c.server)

    for payload <- [
          %{rideId: "other"},
          %{driverId: "B"},
          %{offerId: "other"},
          %{now_ms: 0},
          %{dispatch_store: inspect(c.server)},
          [],
          nil,
          true,
          1
        ] do
      assert json_request(c.server, c.ride.id, "A", payload) |> json_response(400) ==
               error("Bad Request")

      assert :sys.get_state(c.server) == before
    end
  end

  test "malformed JSON syntax and unparsed nonempty bodies are rejected by actual HTTP handling",
       c do
    before = :sys.get_state(c.server)

    {400, _, response} =
      assert_error_sent 400, fn ->
        connection(c.server)
        |> put_req_header("content-type", "application/json")
        |> post(reject_path(c.ride.id, "A"), ~s({"broken":))
      end

    assert Jason.decode!(response) == error("Bad Request")

    for type <- ["text/plain", "application/octet-stream"] do
      assert connection(c.server)
             |> put_req_header("content-type", type)
             |> post(reject_path(c.ride.id, "A"), "unexpected=1")
             |> json_response(400) == error("Bad Request")
    end

    response =
      Plug.Test.conn(:post, reject_path(c.ride.id, "A"), "unexpected=1")
      |> put_private(:dispatch_store, c.server)
      |> put_req_header("accept", "application/json")
      |> RideDispatchWeb.Endpoint.call(RideDispatchWeb.Endpoint.init([]))

    assert json_response(response, 400) == error("Bad Request")
    assert :sys.get_state(c.server) == before
  end

  test "unknown resources/absent relationship are 404, wrong holder and accepted are 409", c do
    before = :sys.get_state(c.server)
    assert request(c.server, "missing", "A") |> json_response(404) == error("Not Found")
    assert request(c.server, c.ride.id, "missing") |> json_response(404) == error("Not Found")
    assert request(c.server, c.ride.id, "B") |> json_response(409) == error("Conflict")
    assert :sys.get_state(c.server) == before
    {:ok, unassigned} = Store.create_ride(c.server, "no-offer", c.body)
    assert request(c.server, unassigned.id, "A") |> json_response(404) == error("Not Found")
    assert {:ok, _} = Store.accept_offer(c.server, c.ride.id, "A")
    before = :sys.get_state(c.server)
    assert request(c.server, c.ride.id, "A") |> json_response(409) == error("Conflict")
    assert :sys.get_state(c.server) == before
  end

  test "late rejection succeeds, while invalid trusted time returns a sanitized 500", c do
    :atomics.put(c.clock, 1, -1)
    before = :sys.get_state(c.server)

    assert request(c.server, c.ride.id, "A") |> json_response(500) ==
             error("Internal Server Error")

    assert :sys.get_state(c.server) == before
    :atomics.put(c.clock, 1, c.offer.expires_at_ms)

    assert request(c.server, c.ride.id, "A") |> json_response(200) ==
             public_ride(c.ride, "MATCHING", nil)
  end

  test "HTTP rejection rematches asynchronously; old Reject replays and old Accept returns 409 after B accepts",
       c do
    assert {:ok, _} = Store.set_driver_availability(c.server, "B", true)
    original = request(c.server, c.ride.id, "A") |> json_response(200)
    parent = self()

    worker =
      start_supervised!(
        {EventDispatcher,
         store: c.server,
         process: fn owner, id ->
           result = Store.process_event(owner, id)
           send(parent, {:processed, id, result})
           result
         end}
      )

    id = "redispatch-" <> c.offer.id
    assert_receive {:processed, ^id, {:ok, :processed}}, 1000
    assert Process.alive?(worker)

    assert connection(c.server)
           |> post("/rides/#{c.ride.id}/offers/B/accept")
           |> json_response(200) == public_ride(c.ride, "DRIVER_ACCEPTED", "B")

    before = :sys.get_state(c.server)
    assert request(c.server, c.ride.id, "A") |> json_response(200) == original

    assert connection(c.server)
           |> post("/rides/#{c.ride.id}/offers/A/accept")
           |> json_response(409) == error("Conflict")

    assert :sys.get_state(c.server) == before
    assert before.drivers["B"].status == :busy

    assert before.offers[before.rides[c.ride.id].currentOfferId].acceptance_result.status ==
             :driver_accepted

    assert before.pending_events[id].status == :processed
    assert map_size(before.offers) == 2
    assert Enum.count(Map.values(before.pending_events), &(&1.eventId == id)) == 1

    assert connection(c.server) |> get("/rides/" <> c.ride.id) |> json_response(200) ==
             public_ride(c.ride, "DRIVER_ACCEPTED", "B")
  end

  test "concurrent HTTP rejects return one original result and create one event", c do
    parent = self()

    tasks =
      for _ <- 1..5,
          do:
            Task.async(fn ->
              send(parent, {:ready, self()})

              receive do
                :go -> request(c.server, c.ride.id, "A") |> json_response(200)
              end
            end)

    for _ <- tasks, do: assert_receive({:ready, _}, 1000)
    Enum.each(tasks, &send(&1.pid, :go))
    assert [result] = tasks |> Enum.map(&Task.await/1) |> Enum.uniq()
    assert result == public_ride(c.ride, "MATCHING", nil)
    state = :sys.get_state(c.server)
    assert map_size(state.offers) == 1
    assert state.offers[c.offer.id].status == :rejected
    assert state.offers[c.offer.id].rejection_receipt.original_result == state.rides[c.ride.id]
    assert state.drivers["A"].status == :available
    assert map_size(state.pending_events) == 3
    assert state.pending_events["redispatch-" <> c.offer.id].status == :pending
  end

  test "external clients cannot choose the owner or override path identities", c do
    before = :sys.get_state(c.server)

    response =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("dispatch-store", inspect(c.server))
      |> post(
        reject_path(c.ride.id, "A") <>
          "?dispatch_store=" <> URI.encode_www_form(inspect(c.server))
      )

    assert json_response(response, 404) == error("Not Found")
    assert :sys.get_state(c.server) == before

    assert connection(c.server)
           |> post(reject_path(c.ride.id, "B") <> "?driverId=A&now_ms=0")
           |> json_response(409) == error("Conflict")

    assert :sys.get_state(c.server) == before
  end

  test "mapping-only protocol fixtures sanitize ambiguous and corrupt state responses", c do
    for {reason, status, detail} <- [
          {:ambiguous_offer, 409, "Conflict"},
          {:inconsistent_ownership, 500, "Internal Server Error"},
          {:invalid_request, 400, "Bad Request"}
        ] do
      fixture =
        start_supervised!(Supervisor.child_spec({__MODULE__.ErrorReply, reason}, id: make_ref()))

      assert request(fixture, c.ride.id, "A") |> json_response(status) == error(detail)
    end
  end

  defmodule ErrorReply do
    use GenServer
    def start_link(reason), do: GenServer.start_link(__MODULE__, reason)
    def init(reason), do: {:ok, reason}
    # Response-mapping fixture follows Store's internal observation envelope.
    def handle_call({:observed, command}, from, state), do: handle_call(command, from, state)

    def handle_call({:reject_offer, _, _}, _, reason), do: {:reply, {:error, reason}, reason}
  end

  defp connection(server),
    do:
      build_conn()
      |> put_private(:dispatch_store, server)
      |> put_req_header("accept", "application/json")

  defp reject_path(ride, driver), do: "/rides/#{ride}/offers/#{driver}/reject"
  defp request(server, ride, driver), do: post(connection(server), reject_path(ride, driver))

  defp json_request(server, ride, driver, body),
    do:
      connection(server)
      |> put_req_header("content-type", "application/json")
      |> post(reject_path(ride, driver), Jason.encode!(body))

  defp error(detail), do: %{"errors" => %{"detail" => detail}}

  defp public_ride(ride, status, driver),
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
