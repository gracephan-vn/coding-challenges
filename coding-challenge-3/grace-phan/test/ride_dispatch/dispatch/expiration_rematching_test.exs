defmodule RideDispatch.Dispatch.ExpirationRematchingTest do
  use RideDispatchWeb.ConnCase, async: true
  import RideDispatch.OfferFixtures
  alias RideDispatch.Dispatch.{EventDispatcher, ExpirationScheduler, StateServer, Store}

  test "delayed supervised scheduler preserves overdue exclusivity, then expires and rematches A to B" do
    {server, first, old, clock} = reserved()
    listen(server)
    timer = scheduler(server)
    assert_receive {{:ride_dispatch, :expiration, :idle}, %{scheduler: ^timer}}, 1000
    old_tick = :sys.get_state(timer).tick
    :ok = :sys.suspend(timer)
    on_exit(fn -> if Process.alive?(timer), do: :sys.resume(timer) end)
    :atomics.put(clock, 1, old.expires_at_ms)

    response =
      connection(server) |> post("/rides/#{first.id}/offers/A/accept") |> json_response(409)

    assert response == %{"errors" => %{"detail" => "Conflict"}}
    {second, second_event} = matching(server, "second")
    assert Store.process_event(server, second_event) == {:ok, :processed}

    assert {:ok, %{status: :processed, outcome: :no_candidate}} =
             Store.get_event(server, second_event)

    assert {:ok, %{status: :offered}} = Store.get_driver(server, "A")

    assert {:ok, %{status: :driver_assigned, assignedDriverId: "A"}} =
             Store.get_ride(server, first.id)

    assert Store.get_offer(server, old.id) == {:ok, old}
    assert {:ok, _} = Store.set_driver_availability(server, "B", true)
    id = "redispatch-expired-" <> old.id
    parent = self()

    worker =
      dispatcher(server,
        process: fn owner, event_id ->
          if event_id == id do
            send(parent, {:rematch_wait, self()})

            receive do
              :go -> :ok
            end
          end

          Store.process_event(owner, event_id)
        end
      )

    assert_receive {{:ride_dispatch, :dispatcher, :idle}, %{dispatcher: ^worker}}, 1000
    :ok = :sys.resume(timer)
    assert_receive {:rematch_wait, ^worker}, 1000
    # Observe the atomic commit before allowing real asynchronous rematching.
    immediate = :sys.get_state(server)
    assert immediate.rides[first.id].status == :matching

    assert immediate.rides[first.id].assignedDriverId == nil and
             immediate.rides[first.id].currentOfferId == nil

    assert immediate.drivers["A"].status == :available
    assert immediate.offers[old.id].status == :expired
    assert immediate.offers[old.id].expiration_receipt.expired_at_ms == 30_000
    assert immediate.pending_events[id].status == :pending
    assert map_size(immediate.offers) == 1
    :atomics.put(clock, 1, 35_000)
    send(worker, :go)

    assert_receive {{:ride_dispatch, :event, :processed},
                    %{event_id: ^id, result: {:ok, :processed}}},
                   1000

    assert {:ok, %{assignedDriverId: "B", currentOfferId: replacement_id}} =
             Store.get_ride(server, first.id)

    assert {:ok, %{status: :pending, created_at_ms: 35_000, expires_at_ms: 65_000}} =
             Store.get_offer(server, replacement_id)

    assert {:ok, accepted} = Store.accept_offer(server, first.id, "B")
    # A is legitimately reused by an unrelated Ride while B owns the first.
    {:ok, third} = Store.create_ride(server, "third", body())
    third_event = "dispatch-" <> third.id

    assert_receive {{:ride_dispatch, :event, :processed},
                    %{event_id: ^third_event, result: {:ok, :processed}}},
                   1000

    assert {:ok, %{assignedDriverId: "A"}} = Store.accept_offer(server, third.id, "A")
    before = :sys.get_state(server)
    send(timer, {:scan, old_tick})
    ExpirationScheduler.wake(timer)
    assert_receive {{:ride_dispatch, :expiration, :idle}, %{scheduler: ^timer}}, 1000
    assert Store.expire_offer(server, old.id) == {:ok, :already_expired}
    assert :sys.get_state(server) == before

    assert before.rides[second.id].status == :matching and
             before.rides[second.id].assignedDriverId == nil

    assert before.drivers["A"].status == :busy and before.drivers["B"].status == :busy
    assert before.offers[replacement_id].acceptance_result == accepted
    assert before.pending_events[id].status == :processed
    assert Enum.count(Map.values(before.pending_events), &(&1.eventId == id)) == 1
    assert map_size(before.offers) == 3

    assert connection(server) |> post("/rides/#{first.id}/offers/A/accept") |> json_response(409) ==
             response

    assert connection(server) |> post("/rides/#{first.id}/offers/A/reject") |> json_response(409) ==
             response

    assert :sys.get_state(server) == before
  end

  test "expiration rematching uses latest availability and coordinates at the dispatcher boundary" do
    for change <- [:offline, :outside, :nearer] do
      drivers =
        for {id, lat} <- [{"A", 0}, {"B", 0.001}, {"C", 0.002}],
            do: %{id: id, status: :available, latitude: lat, longitude: 0}

      {server, ride, old, clock} = reserved(drivers: drivers)
      listen(server)
      parent = self()

      worker =
        dispatcher(server,
          process: fn owner, id ->
            send(parent, {:waiting, self()})

            receive do
              :go -> Store.process_event(owner, id)
            end
          end
        )

      :atomics.put(clock, 1, 30_000)
      scheduler(server)
      assert_receive {:waiting, ^worker}, 1000

      case change do
        :offline -> Store.set_driver_availability(server, "B", false)
        :outside -> Store.update_driver_location(server, "B", %{latitude: 5, longitude: 5})
        :nearer -> Store.update_driver_location(server, "C", %{latitude: 0, longitude: 0})
      end

      send(worker, :go)
      id = "redispatch-expired-" <> old.id

      assert_receive {{:ride_dispatch, :event, :processed},
                      %{event_id: ^id, result: {:ok, :processed}}},
                     1000

      assert {:ok, %{assignedDriverId: "C"}} = Store.get_ride(server, ride.id)
      assert {:ok, %{status: :available}} = Store.get_driver(server, "A")
      assert length(Store.list_offers(server)) == 2
    end
  end

  test "expiration with no alternative processes no_candidate without retry or a redispatch loop" do
    {server, ride, old, clock} = reserved()
    listen(server)
    dispatcher(server)
    :atomics.put(clock, 1, 30_000)
    scheduler(server)
    id = "redispatch-expired-" <> old.id

    assert_receive {{:ride_dispatch, :event, :processed},
                    %{event_id: ^id, result: {:ok, :processed}}},
                   1000

    assert {:ok, %{status: :processed, outcome: :no_candidate, attempts: 1}} =
             Store.get_event(server, id)

    assert {:ok, %{status: :matching, assignedDriverId: nil, currentOfferId: nil}} =
             Store.get_ride(server, ride.id)

    assert {:ok, %{status: :available}} = Store.get_driver(server, "A")
    assert length(Store.list_offers(server)) == 1
    assert length(Store.list_events(server)) == 3
    assert Store.list_actionable_events(server) == []
  end

  test "expiration event technical failures retry through the existing dispatcher without re-expiring" do
    {server, ride, old, clock} = reserved()
    listen(server)
    Store.set_driver_availability(server, "B", true)
    calls = :atomics.new(1, [])

    worker =
      dispatcher(server,
        process: fn owner, id ->
          if :atomics.add_get(calls, 1, 1) == 1,
            do: {:error, :retryable},
            else: Store.process_event(owner, id)
        end
      )

    :atomics.put(clock, 1, 30_000)
    scheduler(server)
    id = "redispatch-expired-" <> old.id
    assert_receive {{:ride_dispatch, :event, :processed}, %{event_id: ^id}}, 1000

    assert {:ok, %{status: :pending, attempts: 1, next_attempt_at: 31_000}} =
             Store.get_event(server, id)

    assert {:ok, expired} = Store.get_offer(server, old.id)
    assert {:ok, %{status: :matching}} = Store.get_ride(server, ride.id)
    :atomics.put(clock, 1, 31_000)
    EventDispatcher.wake(worker)

    assert_receive {{:ride_dispatch, :event, :processed},
                    %{event_id: ^id, result: {:ok, :processed}}},
                   1000

    assert {:ok, %{status: :processed, attempts: 2, outcome: :offer_created}} =
             Store.get_event(server, id)

    assert {:ok, %{assignedDriverId: "B"}} = Store.get_ride(server, ride.id)
    assert Store.get_offer(server, old.id) == {:ok, expired}
    assert length(Store.list_offers(server)) == 2
    assert length(Store.list_events(server)) == 3
  end

  test "synthetic corrupt unrelated Offer cannot crash subsequent expiration-triggered dispatch" do
    {server, ride, old, clock} = reserved()
    Store.set_driver_availability(server, "B", true)
    :atomics.put(clock, 1, 30_000)
    input = put_in(:sys.get_state(server).offers["broken"], %{})

    assert {:reply, {:ok, :expired}, expired} =
             StateServer.handle_call({:expire_offer, old.id}, nil, input)

    id = "redispatch-expired-" <> old.id

    assert {:reply, {:ok, :processed}, rematched} =
             StateServer.handle_call({:process_event, id}, nil, expired)

    assert rematched.rides[ride.id].assignedDriverId == "B"
    assert rematched.offers["broken"] == %{}

    for malformed <- [%{driverId: "B"}, %{rideId: ride.id}] do
      input = put_in(expired.offers["broken"], malformed)

      assert {:reply, {:error, {:permanent, :inconsistent_ownership}}, unchanged_business} =
               StateServer.handle_call({:process_event, id}, nil, input)

      assert unchanged_business.rides == input.rides
      assert unchanged_business.drivers == input.drivers
      assert unchanged_business.offers == input.offers
      assert unchanged_business.pending_events[id].status == :failed
    end
  end

  test "dispatcher restart before or after replacement processing preserves expiration causality" do
    for commit? <- [false, true] do
      {server, ride, offer, clock} = reserved()
      listen(server)
      Store.set_driver_availability(server, "B", true)
      :atomics.put(clock, 1, 30_000)
      assert Store.expire_offer(server, offer.id) == {:ok, :expired}
      {:ok, expired} = Store.get_offer(server, offer.id)
      id = "redispatch-expired-" <> offer.id
      parent = self()
      calls = :atomics.new(1, [])

      worker =
        dispatcher(server,
          process: fn owner, event_id ->
            if :atomics.add_get(calls, 1, 1) == 1 do
              if commit?, do: Store.process_event(owner, event_id)
              send(parent, {:blocked_dispatch, self()})

              receive do
                :never -> :ok
              end
            end

            Store.process_event(owner, event_id)
          end
        )

      assert_receive {:blocked_dispatch, ^worker}, 1000
      ref = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1000
      assert_receive {{:ride_dispatch, :dispatcher, :idle}, %{dispatcher: restarted}}, 1000
      refute restarted == worker

      assert {:ok, %{assignedDriverId: "B", status: :driver_assigned}} =
               Store.get_ride(server, ride.id)

      assert Store.get_offer(server, offer.id) == {:ok, expired}
      assert length(Store.list_offers(server)) == 2
      assert {:ok, %{status: :processed, attempts: 1}} = Store.get_event(server, id)
      assert length(Store.list_events(server)) == 3
    end
  end

  defp connection(server),
    do:
      build_conn()
      |> put_private(:dispatch_store, server)
      |> put_req_header("accept", "application/json")

  defp scheduler(server),
    do:
      start_supervised!(
        Supervisor.child_spec({ExpirationScheduler, store: server, scan_interval_ms: 60_000},
          id: make_ref()
        )
      )

  defp dispatcher(server, opts \\ []),
    do:
      start_supervised!(
        Supervisor.child_spec(
          {EventDispatcher, Keyword.merge([store: server, scan_interval_ms: 60_000], opts)},
          id: make_ref()
        )
      )
end
