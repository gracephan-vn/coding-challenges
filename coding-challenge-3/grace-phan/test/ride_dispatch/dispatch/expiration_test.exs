defmodule RideDispatch.Dispatch.ExpirationTest do
  use ExUnit.Case, async: true
  import RideDispatch.OfferFixtures
  alias RideDispatch.Dispatch.{StateServer, Store}

  test "early expiration changes nothing; equality atomically expires the exact Offer" do
    {server, ride, offer, clock} = reserved()
    before = :sys.get_state(server)
    assert Store.expire_offer(server, offer.id) == {:error, {:not_due, 30_000}}
    assert :sys.get_state(server) == before
    :atomics.put(clock, 1, offer.expires_at_ms)
    assert Store.expire_offer(server, offer.id) == {:ok, :expired}
    after_expire = :sys.get_state(server)

    assert after_expire.rides[ride.id] == %{
             before.rides[ride.id]
             | status: :matching,
               assignedDriverId: nil,
               currentOfferId: nil
           }

    assert after_expire.drivers["A"] == %{before.drivers["A"] | status: :available}
    id = "redispatch-expired-" <> offer.id

    receipt = %{
      offerId: offer.id,
      rideId: ride.id,
      driverId: "A",
      expired_at_ms: 30_000,
      redispatch_event_id: id
    }

    assert after_expire.offers == %{
             offer.id => Map.merge(offer, %{status: :expired, expiration_receipt: receipt})
           }

    assert after_expire.pending_events ==
             Map.put(before.pending_events, id, %{
               eventId: id,
               rideId: ride.id,
               type: :dispatch_requested,
               status: :pending
             })

    assert after_expire.idempotency == before.idempotency
    assert Store.create_ride(server, "original", body()) == {:ok, ride}
  end

  test "expiration replays exact evidence after rematching, acceptance and Driver reuse" do
    {server, ride, offer, clock} = reserved()
    :atomics.put(clock, 1, 30_000)
    assert Store.expire_offer(server, offer.id) == {:ok, :expired}
    assert {:ok, _} = Store.set_driver_availability(server, "B", true)
    assert {:ok, :processed} = Store.process_event(server, "redispatch-expired-" <> offer.id)
    assert {:ok, accepted} = Store.accept_offer(server, ride.id, "B")
    {other, id} = matching(server, "other")
    assert {:ok, :processed} = Store.process_event(server, id)
    assert {:ok, %{assignedDriverId: "A"}} = Store.accept_offer(server, other.id, "A")
    before = :sys.get_state(server)
    assert Store.expire_offer(server, offer.id) == {:ok, :already_expired}
    assert :sys.get_state(server) == before
    assert before.drivers["A"].status == :busy and before.drivers["B"].status == :busy
    assert before.offers[accepted.currentOfferId].acceptance_result == accepted
    input = %{before | clock: fn -> raise "replay must not read time" end}

    assert {:reply, {:ok, :already_expired}, ^input} =
             StateServer.handle_call({:expire_offer, offer.id}, nil, input)
  end

  test "synthetic expiration receipt and linked-event corruption cannot authorize replay" do
    {server, ride, offer, clock} = reserved()
    :atomics.put(clock, 1, 30_000)
    assert Store.expire_offer(server, offer.id) == {:ok, :expired}
    state = :sys.get_state(server)
    expired = state.offers[offer.id]
    receipt = expired.expiration_receipt
    id = receipt.redispatch_event_id

    broken_receipts = [
      nil,
      %{},
      %{receipt | offerId: "wrong"},
      %{receipt | rideId: "wrong"},
      %{receipt | driverId: "wrong"},
      %{receipt | expired_at_ms: 29_999},
      %{receipt | redispatch_event_id: "wrong"}
    ]

    variants =
      Enum.map(broken_receipts, &put_in(state.offers[offer.id].expiration_receipt, &1)) ++
        [
          put_in(state.offers[offer.id].status, :pending),
          put_in(state.offers[offer.id], Map.delete(expired, :expiration_receipt)),
          put_in(state.offers[offer.id], Map.put(expired, :accepted_at_ms, 0)),
          put_in(state.offers[offer.id], Map.put(expired, :rejection_receipt, %{})),
          %{state | pending_events: Map.delete(state.pending_events, id)},
          put_in(state.pending_events[id].rideId, "wrong"),
          put_in(state.pending_events[id].eventId, "wrong"),
          put_in(state.pending_events[id].type, :ride_created),
          put_in(state.rides[ride.id].currentOfferId, offer.id)
        ]

    for input <- variants do
      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:expire_offer, offer.id}, nil, input)
    end

    for status <- [:pending, :processed, :failed] do
      input = put_in(state.pending_events[id].status, status)

      assert {:reply, {:ok, :already_expired}, ^input} =
               StateServer.handle_call({:expire_offer, offer.id}, nil, input)
    end
  end

  test "closed accepted and rejected Offers are ignored only with valid historical evidence" do
    for action <- [:accept, :reject] do
      {server, ride, offer, clock} = reserved()

      if action == :accept,
        do: Store.accept_offer(server, ride.id, "A"),
        else: Store.reject_offer(server, ride.id, "A")

      :atomics.put(clock, 1, 30_000)
      before = :sys.get_state(server)
      assert Store.expire_offer(server, offer.id) == {:ok, :ignored}
      assert :sys.get_state(server) == before
      field = if action == :accept, do: :acceptance_result, else: :rejection_receipt
      input = put_in(before.offers[offer.id], Map.delete(before.offers[offer.id], field))

      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:expire_offer, offer.id}, nil, input)
    end
  end

  test "new expiration evidence cannot be ignored or overwritten by acceptance and rejection" do
    {server, ride, offer, _} = reserved()
    state = :sys.get_state(server)

    for action <- [:accept_offer, :reject_offer] do
      input = put_in(state.offers[offer.id], Map.put(offer, :expiration_receipt, %{}))

      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({action, ride.id, "A"}, nil, input)
    end

    for action <- [:accept_offer, :reject_offer] do
      {server, ride, offer, _} = reserved()
      apply(Store, action, [server, ride.id, "A"])
      state = :sys.get_state(server)

      input =
        put_in(state.offers[offer.id], Map.put(state.offers[offer.id], :expiration_receipt, %{}))

      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({action, ride.id, "A"}, nil, input)
    end
  end

  test "negative monotonic time is valid and malformed trusted readings preserve state" do
    {server, _, offer, clock} = reserved(now: -40_000)
    :atomics.put(clock, 1, -10_000)
    assert Store.expire_offer(server, offer.id) == {:ok, :expired}

    assert {:ok, %{expiration_receipt: %{expired_at_ms: -10_000}}} =
             Store.get_offer(server, offer.id)

    {server, _, offer, _} = reserved()
    state = :sys.get_state(server)

    for clock <- [fn -> nil end, fn -> 1.5 end, fn -> raise "clock" end, fn -> -1 end] do
      input = %{state | clock: clock}

      assert {:reply, {:error, :invalid_clock}, ^input} =
               StateServer.handle_call({:expire_offer, offer.id}, nil, input)
    end
  end

  test "scheduling discovery returns authoritative time and only pending identity/deadline diagnostics" do
    {server, ride, offer, clock} = reserved()
    before = :sys.get_state(server)
    assert {:ok, schedule} = Store.expiration_schedule(server)
    assert schedule.now_ms == 0
    assert [%{offer_id: id, expires_at_ms: 30_000, fingerprint: fingerprint}] = schedule.pending
    assert id == offer.id and is_integer(fingerprint)
    assert schedule.invalid_offers == []
    assert :sys.get_state(server) == before
    assert {:ok, _} = Store.accept_offer(server, ride.id, "A")
    assert {:ok, %{pending: [], invalid_offers: []}} = Store.expiration_schedule(server)
    :atomics.put(clock, 1, -999_999)
    assert Store.expiration_schedule(server) == {:error, :invalid_clock}
  end

  test "synthetic malformed Offer discovery does not hide healthy Offers or block their expiration" do
    {server, ride, offer, clock} = reserved()
    :atomics.put(clock, 1, 30_000)
    state = :sys.get_state(server)

    for malformed <- [%{}, nil, %{offer | id: "wrong"}, %{offer | expires_at_ms: nil}] do
      input = put_in(state.offers["broken"], malformed)

      assert {:reply, {:ok, schedule}, ^input} =
               StateServer.handle_call(:expiration_schedule, nil, input)

      assert [%{offer_id: "broken", reason: reason, fingerprint: _}] = schedule.invalid_offers
      assert reason in [:invalid_identity, :invalid_deadline]
      assert Enum.any?(schedule.pending, &(&1.offer_id == offer.id))
      # Identity-only corrupt records unrelated to this ownership cannot block it.
      if malformed in [%{}, nil] do
        assert {:reply, {:ok, :expired}, updated} =
                 StateServer.handle_call({:expire_offer, offer.id}, nil, input)

        assert updated.offers["broken"] == malformed
        assert updated.rides[ride.id].status == :matching
      end
    end
  end

  test "identifiers, exact ownership, malformed deadlines and conflicting evidence fail without mutation" do
    {server, ride, offer, clock} = reserved()
    :atomics.put(clock, 1, 30_000)
    state = :sys.get_state(server)

    for id <- [nil, 0, [], "", <<255>>],
        do: assert(Store.expire_offer(server, id) == {:error, :invalid_request})

    assert Store.expire_offer(server, "missing") == :not_found
    assert :sys.get_state(server) == state

    variants = [
      put_in(state.offers[offer.id].id, "wrong"),
      put_in(state.offers[offer.id].rideId, "missing"),
      put_in(state.offers[offer.id].driverId, "missing"),
      put_in(state.rides[ride.id].id, "wrong"),
      put_in(state.drivers["A"].id, "wrong"),
      put_in(state.rides[ride.id].currentOfferId, nil),
      put_in(state.rides[ride.id].assignedDriverId, "B"),
      put_in(state.drivers["A"].status, :busy),
      put_in(state.rides[ride.id].status, :completed),
      put_in(state.offers[offer.id].expires_at_ms, nil),
      put_in(state.offers[offer.id].created_at_ms, 30_000),
      put_in(state.offers[offer.id], Map.put(offer, :accepted_at_ms, 0)),
      put_in(state.offers[offer.id], Map.put(offer, :rejection_receipt, %{})),
      put_in(state.offers[offer.id], Map.put(offer, :expiration_receipt, %{})),
      put_in(state.pending_events["redispatch-expired-" <> offer.id], %{eventId: "collision"}),
      put_in(state.offers["other"], %{offer | id: "other"}),
      put_in(state.rides["other"], %{state.rides[ride.id] | id: "other"})
    ]

    for input <- variants do
      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:expire_offer, offer.id}, nil, input)
    end
  end

  test "live terminal expiration replay rejects synthetic dangling and cross-Ride references" do
    for status <- [:completed, :cancelled] do
      {server, ride, offer, clock} = reserved()
      :atomics.put(clock, 1, 30_000)
      assert Store.expire_offer(server, offer.id) == {:ok, :expired}

      if status == :completed do
        assert {:ok, _} = Store.set_driver_availability(server, "B", true)
        assert {:ok, :processed} = Store.process_event(server, "redispatch-expired-" <> offer.id)
        assert {:ok, _} = Store.accept_offer(server, ride.id, "B")
        assert {:ok, _} = Store.complete_ride(server, ride.id)
      else
        assert {:ok, _} = Store.cancel_ride(server, ride.id)
      end

      input = :sys.get_state(server)
      assert Store.expire_offer(server, offer.id) == {:ok, :already_expired}
      assert :sys.get_state(server) == input
      broken = put_in(input.rides[ride.id].assignedDriverId, "A")

      assert {:reply, {:error, :inconsistent_ownership}, ^broken} =
               StateServer.handle_call({:expire_offer, offer.id}, nil, broken)

      other = %{
        input.rides[ride.id]
        | id: "other",
          status: :driver_assigned,
          assignedDriverId: "A",
          currentOfferId: offer.id
      }

      broken = put_in(input.rides["other"], other)

      assert {:reply, {:error, :inconsistent_ownership}, ^broken} =
               StateServer.handle_call({:expire_offer, offer.id}, nil, broken)
    end
  end

  test "synthetic replacement status without valid current evidence cannot authorize historical replay" do
    {server, ride, offer, clock} = reserved()
    :atomics.put(clock, 1, 30_000)
    assert Store.expire_offer(server, offer.id) == {:ok, :expired}
    Store.set_driver_availability(server, "B", true)
    Store.process_event(server, "redispatch-expired-" <> offer.id)
    {:ok, replacement} = Store.get_ride(server, ride.id)
    state = :sys.get_state(server)

    input =
      put_in(
        state.offers[replacement.currentOfferId],
        Map.put(state.offers[replacement.currentOfferId], :expiration_receipt, %{})
      )

    assert {:reply, {:error, :inconsistent_ownership}, ^input} =
             StateServer.handle_call({:expire_offer, offer.id}, nil, input)

    Store.accept_offer(server, ride.id, "B")
    state = :sys.get_state(server)

    input =
      put_in(
        state.offers[replacement.currentOfferId],
        Map.delete(state.offers[replacement.currentOfferId], :acceptance_result)
      )

    assert {:reply, {:error, :inconsistent_ownership}, ^input} =
             StateServer.handle_call({:expire_offer, offer.id}, nil, input)
  end

  test "discovery reports missing or contradictory closed receipts instead of omitting corruption" do
    for action <- [:accept, :reject, :expire] do
      {server, ride, offer, clock} = reserved()

      case action do
        :accept ->
          Store.accept_offer(server, ride.id, "A")

        :reject ->
          Store.reject_offer(server, ride.id, "A")

        :expire ->
          :atomics.put(clock, 1, 30_000)
          Store.expire_offer(server, offer.id)
      end

      state = :sys.get_state(server)

      field =
        case action do
          :accept -> :acceptance_result
          :reject -> :rejection_receipt
          :expire -> :expiration_receipt
        end

      input = put_in(state.offers[offer.id], Map.delete(state.offers[offer.id], field))

      assert {:reply,
              {:ok, %{pending: [], invalid_offers: [%{offer_id: id, reason: :invalid_evidence}]}},
              ^input} =
               StateServer.handle_call(:expiration_schedule, nil, input)

      assert id == offer.id
    end
  end
end
