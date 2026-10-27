defmodule RideDispatch.Dispatch.TerminalConcurrencyTest do
  use ExUnit.Case, async: true
  import RideDispatch.OfferFixtures
  alias RideDispatch.Dispatch.Store

  for race <- [
        :cancel_accept,
        :cancel_reject,
        :cancel_expire,
        :cancel_dispatch,
        :cancel_cancel,
        :complete_complete,
        :complete_cancel,
        :complete_accept,
        :complete_expire,
        :complete_reserve
      ] do
    test "ordered and barrier-released #{race} preserve every authoritative ownership record" do
      for order <- [:left, :right, :competing], _ <- 1..3 do
        run_race(unquote(race), order)
      end
    end
  end

  defp run_race(:cancel_dispatch, order) do
    {server, _} = owner()
    {ride, event} = matching(server, "original")

    [cancel, dispatch] =
      ordered(order, fn -> Store.cancel_ride(server, ride.id) end, fn ->
        Store.process_event(server, event)
      end)

    assert {:ok, %{status: :cancelled} = result} = cancel
    assert dispatch in [{:ok, :processed}, {:ok, :ignored}]
    state = :sys.get_state(server)
    assert state.drivers["A"].status == :available
    assert map_size(state.offers) in [0, 1] and map_size(state.pending_events) == 2
    assert state.pending_events[event].status == :processed
    for offer <- Map.values(state.offers), do: assert(offer.status == :cancelled)
    assert Store.cancel_ride(server, ride.id) == {:ok, result}
    assert :sys.get_state(server) == state
    assert_invariants(state)
  end

  defp run_race(race, order) do
    {server, ride, offer, clock} = reserved()

    accepted =
      if race in [
           :complete_complete,
           :complete_cancel,
           :complete_accept,
           :complete_expire,
           :complete_reserve
         ] do
        {:ok, accepted} = Store.accept_offer(server, ride.id, "A")
        accepted
      end

    before = :sys.get_state(server)
    {left, right, other} = commands(race, server, ride, offer, clock)
    [a, b] = ordered(order, left, right)
    state = :sys.get_state(server)
    terminal = state.rides[ride.id]

    case race do
      :cancel_accept ->
        assert {:ok, %{status: :cancelled}} = a
        assert match?({:ok, _}, b) or b == {:error, :invalid_transition}
        if match?({:ok, _}, b), do: assert(state.offers[offer.id].acceptance_result == elem(b, 1))
        assert state.drivers["A"].status == :available
        assert map_size(state.pending_events) == 2

      :cancel_reject ->
        assert {:ok, %{status: :cancelled}} = a
        assert match?({:ok, _}, b) or b == {:error, :invalid_transition}
        event = "redispatch-" <> offer.id
        assert Map.has_key?(state.pending_events, event) == match?({:ok, _}, b)
        assert map_size(state.pending_events) == if(match?({:ok, _}, b), do: 3, else: 2)
        assert state.drivers["A"].status == :available

      :cancel_expire ->
        assert {:ok, %{status: :cancelled}} = a
        assert b in [{:ok, :ignored}, {:ok, :expired}]

        assert Map.has_key?(state.pending_events, "redispatch-expired-" <> offer.id) ==
                 (b == {:ok, :expired})

        assert state.drivers["A"].status == :available
        assert map_size(state.pending_events) == if(b == {:ok, :expired}, do: 3, else: 2)

      :cancel_cancel ->
        assert a == b and match?({:ok, %{status: :cancelled}}, a)
        assert state.drivers["A"].status == :available

      :complete_complete ->
        assert a == b and match?({:ok, %{status: :completed}}, a)
        assert state.drivers["A"].status == :available

      :complete_cancel ->
        assert Enum.count([a, b], &match?({:ok, _}, &1)) == 1
        assert {:error, :invalid_transition} in [a, b]
        assert terminal.status in [:completed, :cancelled]
        assert state.drivers["A"].status == :available

      :complete_accept ->
        assert {:ok, %{status: :completed}} = a
        assert b == {:ok, accepted}
        assert state.drivers["A"].status == :available

      :complete_expire ->
        assert {:ok, %{status: :completed}} = a
        assert b == {:ok, :ignored}
        assert state.drivers["A"].status == :available

      :complete_reserve ->
        assert {:ok, %{status: :completed}} = a
        assert b == {:ok, :processed}
        current = state.rides[other.id]
        event = state.pending_events["dispatch-" <> other.id]
        assert event.status == :processed

        if current.status == :driver_assigned do
          assert current.assignedDriverId == "A" and event.outcome == :offer_created
          assert {:ok, _} = Store.accept_offer(server, other.id, "A")
        else
          assert current.status == :matching and current.assignedDriverId == nil
          assert event.outcome == :no_candidate and state.drivers["A"].status == :available
        end

        reused = :sys.get_state(server)
        assert Store.complete_ride(server, ride.id) == a
        assert :sys.get_state(server) == reused
        assert_invariants(reused)
    end

    assert terminal.status in [:cancelled, :completed]
    assert terminal.assignedDriverId == nil and terminal.currentOfferId == nil

    assert state.rides[ride.id].terminal_receipt.original_result ==
             Map.delete(terminal, :terminal_receipt)

    if accepted do
      assert state.offers[offer.id].accepted_at_ms == before.offers[offer.id].accepted_at_ms
      assert state.offers[offer.id].acceptance_result == accepted
    end

    assert state.idempotency["original"] == before.idempotency["original"]
    assert_invariants(state)
  end

  defp commands(:cancel_accept, s, r, _o, _),
    do: {fn -> Store.cancel_ride(s, r.id) end, fn -> Store.accept_offer(s, r.id, "A") end, nil}

  defp commands(:cancel_reject, s, r, _o, _),
    do: {fn -> Store.cancel_ride(s, r.id) end, fn -> Store.reject_offer(s, r.id, "A") end, nil}

  defp commands(:cancel_expire, s, r, o, clock) do
    :atomics.put(clock, 1, o.expires_at_ms)
    {fn -> Store.cancel_ride(s, r.id) end, fn -> Store.expire_offer(s, o.id) end, nil}
  end

  defp commands(:cancel_cancel, s, r, _, _),
    do: {fn -> Store.cancel_ride(s, r.id) end, fn -> Store.cancel_ride(s, r.id) end, nil}

  defp commands(:complete_complete, s, r, _, _),
    do: {fn -> Store.complete_ride(s, r.id) end, fn -> Store.complete_ride(s, r.id) end, nil}

  defp commands(:complete_cancel, s, r, _, _),
    do: {fn -> Store.complete_ride(s, r.id) end, fn -> Store.cancel_ride(s, r.id) end, nil}

  defp commands(:complete_accept, s, r, _, _),
    do: {fn -> Store.complete_ride(s, r.id) end, fn -> Store.accept_offer(s, r.id, "A") end, nil}

  defp commands(:complete_expire, s, r, o, _),
    do: {fn -> Store.complete_ride(s, r.id) end, fn -> Store.expire_offer(s, o.id) end, nil}

  defp commands(:complete_reserve, s, r, _, _) do
    {other, event} = matching(s, "other")
    {fn -> Store.complete_ride(s, r.id) end, fn -> Store.process_event(s, event) end, other}
  end

  defp ordered(:left, left, right), do: [left.(), right.()]

  defp ordered(:right, left, right) do
    b = right.()
    [left.(), b]
  end

  defp ordered(:competing, left, right), do: competing([left, right])

  defp assert_invariants(state) do
    active = Enum.filter(Map.values(state.offers), &(&1.status in [:pending, :accepted]))
    assert Enum.all?(Enum.frequencies_by(active, & &1.driverId), fn {_, n} -> n == 1 end)
    assert Enum.all?(Enum.frequencies_by(active, & &1.rideId), fn {_, n} -> n == 1 end)

    for offer <- active do
      ride = state.rides[offer.rideId]
      driver = state.drivers[offer.driverId]
      assert ride.currentOfferId == offer.id and ride.assignedDriverId == driver.id

      assert {ride.status, driver.status} ==
               if(offer.status == :pending,
                 do: {:driver_assigned, :offered},
                 else: {:driver_accepted, :busy}
               )
    end

    for ride <- Map.values(state.rides), ride.status in [:cancelled, :completed] do
      assert ride.assignedDriverId == nil and ride.currentOfferId == nil
      refute Enum.any?(active, &(&1.rideId == ride.id))
      assert ride.terminal_receipt.rideId == ride.id
    end

    for event <- Map.values(state.pending_events) do
      assert event.status in [:pending, :processed]
      assert event.eventId == state.pending_events[event.eventId].eventId
    end
  end
end
