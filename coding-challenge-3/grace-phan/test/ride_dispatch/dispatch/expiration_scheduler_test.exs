defmodule RideDispatch.Dispatch.ExpirationSchedulerTest do
  use ExUnit.Case, async: true
  import RideDispatch.OfferFixtures
  alias RideDispatch.Dispatch.{EventDispatcher, ExpirationScheduler, StateServer, Store}

  test "application supervises permanent workers under the existing one-for-one arrangement" do
    assert is_pid(Process.whereis(ExpirationScheduler))

    for child <- [StateServer, EventDispatcher, ExpirationScheduler] do
      assert {:ok, %{restart: :permanent, type: :worker}} =
               :supervisor.get_childspec(RideDispatch.Supervisor, child)
    end

    assert :one_for_one in Tuple.to_list(:sys.get_state(RideDispatch.Supervisor))
  end

  test "startup expires overdue work through Store without HTTP" do
    {server, ride, offer, clock} = reserved()
    listen(server)
    :atomics.put(clock, 1, 30_000)
    worker = scheduler(server)

    assert_receive {{:ride_dispatch, :expiration, :result},
                    %{offer_id: id, result: {:ok, :expired}, scheduler: ^worker}},
                   1000

    assert id == offer.id
    assert {:ok, %{status: :matching, assignedDriverId: nil}} = Store.get_ride(server, ride.id)
    assert {:ok, %{status: :available}} = Store.get_driver(server, "A")
    assert {:ok, %{status: :pending}} = Store.get_event(server, "redispatch-expired-" <> offer.id)
  end

  test "next-deadline timer expires at fake-clock equality; obsolete ticks cannot repeat it" do
    {server, _, offer, clock} = reserved(offer_timeout_ms: 20)
    listen(server)
    worker = scheduler(server, scan_interval_ms: 60_000)

    assert_receive {{:ride_dispatch, :expiration, :idle}, %{scheduler: ^worker, delay_ms: 20}},
                   1000

    local = :sys.get_state(worker)
    assert is_reference(local.timer)
    # Assert computed scheduling policy, not a racy remaining timer duration.
    assert {:ok, %{status: :pending}} = Store.get_offer(server, offer.id)
    :atomics.put(clock, 1, 20)

    assert_receive {{:ride_dispatch, :expiration, :result},
                    %{result: {:ok, :expired}, scheduler: ^worker}},
                   1000

    before = :sys.get_state(server)
    send(worker, {:scan, local.tick})
    :sys.get_state(worker)
    assert :sys.get_state(server) == before
  end

  test "reservation wake-up advances scheduling without waiting for recovery scan" do
    {server, clock} = owner(offer_timeout_ms: 20)
    listen(server)
    worker = scheduler(server, scan_interval_ms: 60_000)
    assert_receive {{:ride_dispatch, :expiration, :idle}, %{scheduler: ^worker}}, 1000
    {ride, dispatch} = matching(server, "new")
    assert {:ok, :processed} = Store.process_event(server, dispatch)
    :atomics.put(clock, 1, 20)

    assert_receive {{:ride_dispatch, :expiration, :result},
                    %{result: {:ok, :expired}, scheduler: ^worker}},
                   1000

    assert {:ok, %{status: :matching}} = Store.get_ride(server, ride.id)
  end

  test "recovery scanning finds Offers without any notifications" do
    {server, clock} = owner()
    listen(server)
    worker = scheduler(server, subscribe?: false, scan_interval_ms: 20)
    assert_receive {{:ride_dispatch, :expiration, :idle}, %{scheduler: ^worker}}, 1000
    {_, dispatch} = matching(server, "missed")
    assert {:ok, :processed} = Store.process_event(server, dispatch)
    :atomics.put(clock, 1, 30_000)

    assert_receive {{:ride_dispatch, :expiration, :result},
                    %{result: {:ok, :expired}, scheduler: ^worker}},
                   1000

    assert :sys.get_state(server).event_subscribers == %{}
  end

  test "invalid scheduler configuration is rejected before startup" do
    for interval <- [0, -1, 1.5, nil, 60_001] do
      assert ExpirationScheduler.init(store: self(), scan_interval_ms: interval) ==
               {:stop, :invalid_scan_interval}
    end
  end

  test "real one-for-one owner replacement preserves siblings and invalidates old-owner work" do
    parent = self()
    clock = :atomics.new(1, [])
    calls = :atomics.new(1, [])
    owner_name = {:global, {__MODULE__, make_ref()}}
    listen(owner_name)

    children =
      for module <- [StateServer, EventDispatcher, ExpirationScheduler] do
        {:ok, spec} = :supervisor.get_childspec(RideDispatch.Supervisor, module)
        {^module, :start_link, [opts]} = spec.start
        opts = Keyword.delete(opts, :name)

        opts =
          case module do
            StateServer ->
              Keyword.merge(opts,
                name: owner_name,
                drivers: [%{id: "A", status: :available, latitude: 0, longitude: 0}],
                clock: fn ->
                  send(parent, {:owner_clock, self()})
                  :atomics.get(clock, 1)
                end
              )

            EventDispatcher ->
              Keyword.merge(opts, store: owner_name, scan_interval_ms: 20)

            ExpirationScheduler ->
              Keyword.merge(opts,
                store: owner_name,
                scan_interval_ms: 20,
                expire: fn owner, id ->
                  send(parent, {:expire_call, owner, id})

                  case :atomics.add_get(calls, 1, 1) do
                    1 ->
                      {:error, :retryable}

                    2 ->
                      send(parent, {:blocked, self()})

                      receive do
                        :go -> Store.expire_offer(owner, id)
                      end

                    _ ->
                      Store.expire_offer(owner, id)
                  end
                end
              )
          end

        %{spec | start: {module, :start_link, [opts]}}
      end

    # Real Supervisor, using the application's actual child restart specs and
    # observed strategy. Names/seeds/clocks are isolated, not global app changes.
    sup =
      start_supervised!(%{
        id: make_ref(),
        start: {Supervisor, :start_link, [children, [strategy: :one_for_one]]},
        type: :supervisor
      })

    members = Map.new(Supervisor.which_children(sup), fn {id, pid, _, _} -> {id, pid} end)
    old_owner = members[StateServer]
    worker = members[ExpirationScheduler]
    dispatcher = members[EventDispatcher]

    {:ok, ride} =
      Store.create_ride(owner_name, "first", %{
        "passengerId" => "P001",
        "pickup" => %{"latitude" => 0, "longitude" => 0},
        "destination" => %{"latitude" => 1, "longitude" => 1}
      })

    dispatch_id = "dispatch-" <> ride.id
    assert_receive {{:ride_dispatch, :event, :processed}, %{event_id: ^dispatch_id}}, 1000
    [old_offer] = Store.list_offers(old_owner)
    old_tick = :sys.get_state(worker).tick
    :atomics.put(clock, 1, old_offer.expires_at_ms)
    ExpirationScheduler.wake(worker)

    assert_receive {{:ride_dispatch, :expiration, :result},
                    %{result: {:error, :retryable}, scheduler: ^worker}},
                   1000

    assert_receive {{:ride_dispatch, :expiration, :idle}, %{scheduler: ^worker}}, 1000
    assert :sys.get_state(worker).retries[old_offer.id].attempts == 1
    :atomics.put(clock, 1, old_offer.expires_at_ms + 1000)
    ExpirationScheduler.wake(worker)
    assert_receive {:blocked, ^worker}, 1000
    assert_receive {:expire_call, ^old_owner, old_id}, 1000
    assert old_id == old_offer.id
    ref = Process.monitor(old_owner)
    Process.exit(old_owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^old_owner, :killed}, 1000
    assert_receive {:owner_clock, replacement} when replacement != old_owner, 1000
    assert Store.list_offers(replacement) == []
    assert Store.list_events(replacement) == []
    members_after = Map.new(Supervisor.which_children(sup), fn {id, pid, _, _} -> {id, pid} end)
    assert members_after[EventDispatcher] == dispatcher
    assert members_after[ExpirationScheduler] == worker
    send(worker, {:scan, old_tick})
    send(worker, :go)

    assert_receive {{:ride_dispatch, :expiration, :idle},
                    %{owner: ^replacement, scheduler: ^worker}},
                   1000

    local = :sys.get_state(worker)
    assert local.owner == replacement and local.tick != old_tick
    assert local.retries == %{} and local.diagnostics == %{}
    assert Store.get_offer(replacement, old_id) == :not_found
    assert Store.list_events(replacement) == []

    {:ok, new_ride} =
      Store.create_ride(owner_name, "new", %{
        "passengerId" => "P001",
        "pickup" => %{"latitude" => 0, "longitude" => 0},
        "destination" => %{"latitude" => 1, "longitude" => 1}
      })

    new_dispatch = "dispatch-" <> new_ride.id
    assert_receive {{:ride_dispatch, :event, :processed}, %{event_id: ^new_dispatch}}, 1000
    [new_offer] = Store.list_offers(replacement)
    refute new_offer.id == old_id
    :atomics.put(clock, 1, new_offer.expires_at_ms)
    ExpirationScheduler.wake(worker)
    assert_receive {:expire_call, ^replacement, new_id}, 1000
    assert new_id == new_offer.id

    assert_receive {{:ride_dispatch, :expiration, :result},
                    %{owner: ^replacement, result: {:ok, :expired}}},
                   1000

    assert {:ok, %{status: :expired}} = Store.get_offer(replacement, new_id)
    assert Store.get_offer(replacement, old_id) == :not_found
  end

  test "scheduler restart before and after commit rediscovers work without duplicate expiration" do
    for commit? <- [false, true] do
      {server, ride, offer, clock} = reserved()
      listen(server)
      :atomics.put(clock, 1, 30_000)
      parent = self()
      calls = :atomics.new(1, [])

      worker =
        scheduler(server,
          expire: fn owner, id ->
            if :atomics.add_get(calls, 1, 1) == 1 do
              if commit?, do: Store.expire_offer(owner, id)
              send(parent, {:blocked, self()})

              receive do
                :never -> :ok
              end
            end

            Store.expire_offer(owner, id)
          end
        )

      assert_receive {:blocked, ^worker}, 1000
      ref = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1000
      assert_receive {{:ride_dispatch, :expiration, :idle}, %{scheduler: restarted}}, 1000
      refute restarted == worker

      assert {:ok, %{status: :expired, expiration_receipt: receipt}} =
               Store.get_offer(server, offer.id)

      assert receipt.expired_at_ms == 30_000
      assert {:ok, %{status: :matching}} = Store.get_ride(server, ride.id)
      assert length(Store.list_events(server)) == 3
      assert Store.expire_offer(server, offer.id) == {:ok, :already_expired}
    end
  end

  defp scheduler(server, opts \\ []) do
    start_supervised!(
      Supervisor.child_spec({ExpirationScheduler, Keyword.merge([store: server], opts)},
        id: make_ref()
      )
    )
  end
end
