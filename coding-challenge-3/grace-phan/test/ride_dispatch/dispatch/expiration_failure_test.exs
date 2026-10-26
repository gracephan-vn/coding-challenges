defmodule RideDispatch.Dispatch.ExpirationFailureTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  import RideDispatch.OfferFixtures
  alias RideDispatch.Dispatch.{ExpirationScheduler, Store}

  test "technical failures back off, stop after three attempts, and retry on bounded rediscovery" do
    {server, _, offer, clock} = reserved()
    listen(server)
    :atomics.put(clock, 1, 30_000)
    calls = :atomics.new(1, [])

    log =
      capture_log(fn ->
        worker =
          scheduler(server,
            expire: fn owner, id ->
              if :atomics.add_get(calls, 1, 1) <= 3,
                do: {:error, :retryable},
                else: Store.expire_offer(owner, id)
            end
          )

        for now <- [30_000, 31_000, 33_000] do
          :atomics.put(clock, 1, now)
          ExpirationScheduler.wake(worker)

          assert_receive {{:ride_dispatch, :expiration, :result},
                          %{result: {:error, :retryable}, scheduler: ^worker}},
                         1000

          idle(worker)
        end

        assert :atomics.get(calls, 1) == 3
        :atomics.put(clock, 1, 40_000)
        ExpirationScheduler.wake(worker)
        idle(worker)
        assert :atomics.get(calls, 1) == 3
        assert {:ok, %{status: :pending}} = Store.get_offer(server, offer.id)
        assert length(Store.list_events(server)) == 2
        :atomics.put(clock, 1, 93_000)
        ExpirationScheduler.wake(worker)

        assert_receive {{:ride_dispatch, :expiration, :result},
                        %{result: {:ok, :expired}, scheduler: ^worker}},
                       1000

        assert length(Store.list_events(server)) == 3
      end)

    assert length(Regex.scan(~r/category=retry_exhausted/, log)) == 1
  end

  test "uncertain timeouts before and after commit reread proof without charging technical failures" do
    for commit? <- [false, true] do
      {server, _, offer, clock} = reserved()
      listen(server)
      :atomics.put(clock, 1, 30_000)
      calls = :atomics.new(1, [])

      worker =
        scheduler(server,
          scan_interval_ms: 1000,
          expire: fn owner, id ->
            if :atomics.add_get(calls, 1, 1) == 1 do
              if commit?, do: Store.expire_offer(owner, id)
              # Controlled signal around real Store outcomes, not elapsed timeout.
              exit({:timeout, :controlled_call})
            end

            Store.expire_offer(owner, id)
          end
        )

      expected = if commit?, do: {:ok, :already_expired}, else: {:error, :uncertain}

      assert_receive {{:ride_dispatch, :expiration, :result},
                      %{result: ^expected, scheduler: ^worker}},
                     1000

      if not commit? do
        assert {:ok, %{status: :pending}} = Store.get_offer(server, offer.id)
        assert length(Store.list_events(server)) == 2
        assert Map.get(:sys.get_state(worker).retries[offer.id], :attempts) == 0
        :atomics.put(clock, 1, 31_000)
        ExpirationScheduler.wake(worker)

        assert_receive {{:ride_dispatch, :expiration, :result},
                        %{result: {:ok, :expired}, scheduler: ^worker}},
                       1000
      end

      assert {:ok, %{status: :expired, expiration_receipt: receipt}} =
               Store.get_offer(server, offer.id)

      assert receipt.redispatch_event_id == "redispatch-expired-" <> offer.id
      assert length(Store.list_events(server)) == 3
      assert :atomics.get(calls, 1) <= 2
    end
  end

  test "early authoritative result is not completion and is rescheduled" do
    {server, _, offer, clock} = reserved()
    listen(server)
    :atomics.put(clock, 1, 30_000)
    calls = :atomics.new(1, [])

    worker =
      scheduler(server,
        expire: fn owner, id ->
          if :atomics.add_get(calls, 1, 1) == 1, do: :atomics.put(clock, 1, 29_999)
          Store.expire_offer(owner, id)
        end
      )

    assert_receive {{:ride_dispatch, :expiration, :result},
                    %{result: {:error, {:not_due, 30_000}}, scheduler: ^worker}},
                   1000

    idle(worker)
    assert {:ok, %{status: :pending}} = Store.get_offer(server, offer.id)
    assert length(Store.list_events(server)) == 2
    :atomics.put(clock, 1, 30_000)
    ExpirationScheduler.wake(worker)

    assert_receive {{:ride_dispatch, :expiration, :result},
                    %{result: {:ok, :expired}, scheduler: ^worker}},
                   1000
  end

  @tag timeout: 10_000
  test "an actual Store timeout leaves a queued command that reads time only at processing" do
    {server, ride, offer, clock} = reserved()
    :ok = :sys.suspend(server)

    try do
      task =
        Task.async(fn ->
          try do
            Store.expire_offer(server, offer.id)
          catch
            :exit, {:timeout, _} -> :uncertain
          end
        end)

      assert Task.await(task, 6000) == :uncertain
      :atomics.put(clock, 1, 30_000)
    after
      :sys.resume(server)
    end

    assert {:ok, %{status: :matching}} = Store.get_ride(server, ride.id)
    before = :sys.get_state(server)
    assert Store.expire_offer(server, offer.id) == {:ok, :already_expired}
    assert :sys.get_state(server) == before
    assert before.offers[offer.id].expiration_receipt.expired_at_ms == 30_000
    assert length(Store.list_events(server)) == 3
  end

  defp scheduler(server, opts) do
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
end
