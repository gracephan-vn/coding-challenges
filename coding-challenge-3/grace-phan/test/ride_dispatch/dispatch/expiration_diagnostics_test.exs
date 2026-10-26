defmodule RideDispatch.Dispatch.ExpirationDiagnosticsTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import RideDispatch.OfferFixtures
  alias RideDispatch.Dispatch.{ExpirationScheduler, Store}
  alias RideDispatch.OfferFixtures.CallbackOwner

  test "synthetic malformed record logs once while unrelated valid Offer expires; changes and reminders recheck" do
    {server, _, _, clock} = reserved()
    assert {:ok, _} = Store.set_driver_availability(server, "B", true)
    {ride, id} = matching(server, "healthy")
    assert {:ok, :processed} = Store.process_event(server, id)
    snapshot = :sys.get_state(server)
    snapshot = put_in(snapshot.offers["broken"], %{})
    fixture = start_supervised!({CallbackOwner, snapshot})
    listen(fixture)
    :atomics.put(clock, 1, 30_000)

    log =
      capture_log(fn ->
        worker = scheduler(fixture, diagnostic_reminder_ms: 1000)
        assert_receive {{:ride_dispatch, :expiration, :result}, %{result: {:ok, :expired}}}, 1000
        idle(worker)
        for _ <- 1..3, do: recheck(worker)
        assert {:ok, %{status: :matching}} = Store.get_ride(fixture, ride.id)
        assert :sys.get_state(fixture).offers["broken"] == %{}
        # Only this dedicated test fixture can change synthetic corruption.
        assert :ok = GenServer.call(fixture, {:fixture_offer, "broken", nil})
        recheck(worker)
        :atomics.put(clock, 1, 31_000)
        recheck(worker)
        for _ <- 1..3, do: recheck(worker)
      end)

    assert length(Regex.scan(~r/offer_id="broken" category=invalid_identity/, log)) == 3
  end

  test "synthetic permanent ownership error is suppressed, does not starve unrelated work, and recovers on fingerprint change" do
    {server, ride_a, offer_a, clock} = reserved()
    assert {:ok, _} = Store.set_driver_availability(server, "B", true)
    {ride_b, id} = matching(server, "B")
    assert {:ok, :processed} = Store.process_event(server, id)
    snapshot = put_in(:sys.get_state(server).drivers["A"].status, :busy)
    fixture = start_supervised!({CallbackOwner, snapshot})
    listen(fixture)
    :atomics.put(clock, 1, 30_000)

    log =
      capture_log(fn ->
        worker = scheduler(fixture)

        assert_receive {{:ride_dispatch, :expiration, :result},
                        %{offer_id: a, result: {:error, :inconsistent_ownership}}},
                       1000

        assert a == offer_a.id
        assert_receive {{:ride_dispatch, :expiration, :result}, %{result: {:ok, :expired}}}, 1000
        idle(worker)
        for _ <- 1..3, do: recheck(worker)
        assert {:ok, %{status: :matching}} = Store.get_ride(fixture, ride_b.id)
        assert {:ok, %{status: :driver_assigned}} = Store.get_ride(fixture, ride_a.id)
        assert :sys.get_state(fixture).offers[offer_a.id] == offer_a
        changed = Map.put(offer_a, :diagnostic_note, "changed")
        :ok = GenServer.call(fixture, {:fixture_offer, offer_a.id, changed})
        recheck(worker)
      end)

    assert length(Regex.scan(~r/category=inconsistent_ownership/, log)) == 2
  end

  test "scheduler restart rediscovers malformed records and resets local diagnostic suppression" do
    {server, _, _, _} = reserved()
    snapshot = put_in(:sys.get_state(server).offers["broken"], nil)
    fixture = start_supervised!({CallbackOwner, snapshot})
    listen(fixture)

    log =
      capture_log(fn ->
        worker = scheduler(fixture)
        idle(worker)
        ref = Process.monitor(worker)
        Process.exit(worker, :kill)
        assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 1000
        assert_receive {{:ride_dispatch, :expiration, :idle}, %{scheduler: replacement}}, 1000
        refute replacement == worker
        for _ <- 1..2, do: recheck(replacement)
      end)

    assert length(Regex.scan(~r/offer_id="broken" category=invalid_identity/, log)) == 2
  end

  test "invalid global clock is observable and bounded, then recovers without business mutation" do
    {server, _, offer, clock} = reserved()
    listen(server)
    before = :sys.get_state(server)
    :atomics.put(clock, 1, -999_999)

    log =
      capture_log(fn ->
        worker = scheduler(server)
        idle(worker)
        for _ <- 1..3, do: recheck(worker)
        assert :sys.get_state(server).offers == before.offers
        assert :sys.get_state(server).pending_events == before.pending_events
        :atomics.put(clock, 1, 30_000)
        ExpirationScheduler.wake(worker)

        assert_receive {{:ride_dispatch, :expiration, :result},
                        %{offer_id: id, result: {:ok, :expired}}},
                       1000

        assert id == offer.id
      end)

    assert length(Regex.scan(~r/category=invalid_clock/, log)) == 1
  end

  defp scheduler(server, opts \\ []) do
    start_supervised!(
      Supervisor.child_spec(
        {ExpirationScheduler, Keyword.merge([store: server, scan_interval_ms: 60_000], opts)},
        id: make_ref()
      )
    )
  end

  defp idle(worker) do
    assert_receive {{:ride_dispatch, :expiration, :idle}, %{scheduler: ^worker}}, 1000
  end

  defp recheck(worker) do
    ExpirationScheduler.wake(worker)
    idle(worker)
  end
end
