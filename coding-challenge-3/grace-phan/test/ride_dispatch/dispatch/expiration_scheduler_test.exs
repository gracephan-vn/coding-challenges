defmodule RideDispatch.Dispatch.ExpirationSchedulerTest do
  use ExUnit.Case, async: true
  import RideDispatch.OfferFixtures
  alias RideDispatch.Dispatch.{ExpirationScheduler, Store}

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
    assert_receive {{:ride_dispatch, :expiration, :idle}, %{scheduler: ^worker}}, 1000
    local = :sys.get_state(worker)
    assert is_reference(local.timer)
    assert Process.read_timer(local.timer) <= 20
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

  defp scheduler(server, opts \\ []) do
    start_supervised!(
      Supervisor.child_spec({ExpirationScheduler, Keyword.merge([store: server], opts)},
        id: make_ref()
      )
    )
  end
end
