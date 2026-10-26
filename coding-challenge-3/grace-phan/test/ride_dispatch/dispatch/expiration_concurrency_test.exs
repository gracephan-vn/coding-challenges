defmodule RideDispatch.Dispatch.ExpirationConcurrencyTest do
  use ExUnit.Case, async: true
  import RideDispatch.OfferFixtures
  alias RideDispatch.Dispatch.Store

  test "before deadline Accept wins safely; overdue Accept never wins against expiration" do
    for now <- [29_999, 30_000], order <- [:left, :right, :competing], _ <- 1..5 do
      {server, ride, offer, clock} = reserved()
      :atomics.put(clock, 1, now)
      expire = fn -> Store.expire_offer(server, offer.id) end
      accept = fn -> Store.accept_offer(server, ride.id, "A") end
      [expired, accepted] = ordered(order, expire, accept)
      state = :sys.get_state(server)

      if now < offer.expires_at_ms do
        assert expired in [{:ok, :ignored}, {:error, {:not_due, 30_000}}]
        assert {:ok, result} = accepted
        assert state.rides[ride.id] == result
        assert state.drivers["A"].status == :busy
        assert state.offers[offer.id].status == :accepted
        assert state.offers[offer.id].accepted_at_ms == 29_999
        assert state.offers[offer.id].acceptance_result == result
        assert map_size(state.pending_events) == 2
        :atomics.put(clock, 1, 30_000)
        assert Store.expire_offer(server, offer.id) == {:ok, :ignored}
        assert Store.accept_offer(server, ride.id, "A") == {:ok, result}
        assert :sys.get_state(server) == state
      else
        assert expired == {:ok, :expired}
        assert accepted in [{:error, :offer_expired}, {:error, :invalid_transition}]
        assert state.rides[ride.id].status == :matching

        assert state.rides[ride.id].assignedDriverId == nil and
                 state.rides[ride.id].currentOfferId == nil

        assert state.drivers["A"].status == :available
        assert state.offers[offer.id].status == :expired
        refute Map.has_key?(state.offers[offer.id], :acceptance_result)
        assert map_size(state.pending_events) == 3
        assert state.pending_events["redispatch-expired-" <> offer.id].status == :pending
      end

      assert map_size(state.offers) == 1
    end
  end

  test "ordered and barrier-released Reject/Expire produce exactly one winning close and event" do
    for order <- [:left, :right, :competing], _ <- 1..8 do
      {server, ride, offer, clock} = reserved()
      :atomics.put(clock, 1, 30_000)

      [expired, rejected] =
        ordered(
          order,
          fn -> Store.expire_offer(server, offer.id) end,
          fn -> Store.reject_offer(server, ride.id, "A") end
        )

      state = :sys.get_state(server)
      assert state.rides[ride.id].status == :matching

      assert state.rides[ride.id].assignedDriverId == nil and
               state.rides[ride.id].currentOfferId == nil

      assert state.drivers["A"].status == :available
      assert map_size(state.offers) == 1 and map_size(state.pending_events) == 3

      case {expired, rejected} do
        {{:ok, :expired}, {:error, :invalid_transition}} ->
          assert state.offers[offer.id].status == :expired
          refute Map.has_key?(state.offers[offer.id], :rejection_receipt)
          assert state.pending_events["redispatch-expired-" <> offer.id].status == :pending
          refute Map.has_key?(state.pending_events, "redispatch-" <> offer.id)

        {{:ok, :ignored}, {:ok, result}} ->
          assert state.rides[ride.id] == result
          assert state.offers[offer.id].status == :rejected
          refute Map.has_key?(state.offers[offer.id], :expiration_receipt)
          assert state.pending_events["redispatch-" <> offer.id].status == :pending
          refute Map.has_key?(state.pending_events, "redispatch-expired-" <> offer.id)
      end

      before = :sys.get_state(server)
      assert Store.expire_offer(server, offer.id) in [{:ok, :already_expired}, {:ok, :ignored}]
      assert :sys.get_state(server) == before
    end
  end

  test "competing expirations retain exactly one immutable receipt and redispatch event" do
    {server, ride, offer, clock} = reserved()
    :atomics.put(clock, 1, 30_000)
    results = competing(List.duplicate(fn -> Store.expire_offer(server, offer.id) end, 12))
    assert Enum.count(results, &(&1 == {:ok, :expired})) == 1
    assert Enum.count(results, &(&1 == {:ok, :already_expired})) == 11
    state = :sys.get_state(server)
    assert state.offers[offer.id].expiration_receipt.expired_at_ms == 30_000
    assert state.rides[ride.id].status == :matching

    assert state.rides[ride.id].assignedDriverId == nil and
             state.rides[ride.id].currentOfferId == nil

    assert state.drivers["A"].status == :available
    assert map_size(state.offers) == 1
    assert map_size(state.pending_events) == 3
    assert state.pending_events["redispatch-expired-" <> offer.id].status == :pending

    assert competing(List.duplicate(fn -> Store.expire_offer(server, offer.id) end, 8)) ==
             List.duplicate({:ok, :already_expired}, 8)

    assert :sys.get_state(server) == state
  end

  defp ordered(:left, left, right), do: [left.(), right.()]

  defp ordered(:right, left, right) do
    second = right.()
    [left.(), second]
  end

  defp ordered(:competing, left, right), do: competing([left, right])
end
