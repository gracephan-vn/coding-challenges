defmodule RideDispatch.Dispatch.TerminalLifecycleTest do
  use ExUnit.Case, async: true
  import RideDispatch.OfferFixtures
  alias RideDispatch.Dispatch.{StateServer, Store}

  test "terminal commands validate identities and reject non-completable states unchanged" do
    {server, _} = owner()
    {:ok, ride} = Store.create_ride(server, "new", body())
    before = :sys.get_state(server)

    for command <- [&Store.cancel_ride/2, &Store.complete_ride/2] do
      for id <- [nil, 0, "", <<255>>],
          do: assert(command.(server, id) == {:error, :invalid_request})

      assert command.(server, "missing") == :not_found
    end

    assert Store.complete_ride(server, ride.id) == {:error, :invalid_transition}
    assert :sys.get_state(server) == before
  end

  test "REQUESTED cancellation retains pending events and replays its exact original result" do
    {server, _} = owner()
    {:ok, ride} = Store.create_ride(server, "new", body())
    before = :sys.get_state(server)
    assert {:ok, result} = Store.cancel_ride(server, ride.id)
    state = :sys.get_state(server)

    assert result ==
             Map.merge(ride, %{status: :cancelled, assignedDriverId: nil, currentOfferId: nil})

    assert state.rides[ride.id] ==
             Map.put(result, :terminal_receipt, %{
               operation: :cancel,
               rideId: ride.id,
               source_status: :requested,
               offerId: nil,
               driverId: nil,
               original_result: result
             })

    assert state.drivers == before.drivers and state.offers == before.offers

    assert state.pending_events == before.pending_events and
             state.idempotency == before.idempotency

    assert Store.cancel_ride(server, ride.id) == {:ok, result}
    assert Store.complete_ride(server, ride.id) == {:error, :invalid_transition}
    assert :sys.get_state(server) == state
    assert Store.create_ride(server, "new", body()) == {:ok, ride}
  end

  test "MATCHING cancellation preserves closed rejection history and does not release unrelated drivers" do
    {server, ride, offer, _} = reserved()
    assert {:ok, _} = Store.reject_offer(server, ride.id, "A")
    before = :sys.get_state(server)
    assert {:ok, result} = Store.cancel_ride(server, ride.id)
    after_cancel = :sys.get_state(server)

    assert result.status == :cancelled and result.assignedDriverId == nil and
             result.currentOfferId == nil

    assert after_cancel.offers[offer.id] == before.offers[offer.id]
    assert after_cancel.drivers == before.drivers
    assert after_cancel.pending_events == before.pending_events
  end

  for {operation, accepted?} <- [cancel: false, cancel: true, complete: true] do
    test "#{operation} atomically closes accepted=#{accepted?} ownership and retains evidence" do
      {server, ride, offer, _} = reserved()
      if unquote(accepted?), do: assert({:ok, _} = Store.accept_offer(server, ride.id, "A"))
      before = :sys.get_state(server)
      operation = unquote(operation)
      assert {:ok, result} = apply(Store, terminal_command(operation), [server, ride.id])
      state = :sys.get_state(server)
      status = Map.fetch!(%{cancel: :cancelled, complete: :completed}, operation)

      assert result.status == status and result.assignedDriverId == nil and
               result.currentOfferId == nil

      assert state.drivers["A"] == %{before.drivers["A"] | status: :available}
      assert state.offers[offer.id] == %{before.offers[offer.id] | status: status}

      assert state.rides[ride.id].terminal_receipt == %{
               operation: operation,
               rideId: ride.id,
               source_status: before.rides[ride.id].status,
               offerId: offer.id,
               driverId: "A",
               original_result: result
             }

      assert state.pending_events == before.pending_events and
               state.idempotency == before.idempotency

      assert apply(Store, terminal_command(operation), [server, ride.id]) == {:ok, result}
      opposite = Map.fetch!(%{cancel: :complete, complete: :cancel}, operation)

      assert apply(Store, terminal_command(opposite), [server, ride.id]) ==
               {:error, :invalid_transition}

      assert :sys.get_state(server) == state
    end
  end

  test "synthetic terminal receipts must prove cross-record identity, evidence and exclusivity" do
    {server, ride, offer, _} = reserved()
    {:ok, _} = Store.accept_offer(server, ride.id, "A")
    {:ok, _} = Store.complete_ride(server, ride.id)
    state = :sys.get_state(server)
    receipt = state.rides[ride.id].terminal_receipt

    other = %{
      state.rides[ride.id]
      | id: "other",
        status: :driver_assigned,
        assignedDriverId: "A",
        currentOfferId: offer.id
    }

    variants = [
      put_in(state.rides[ride.id].terminal_receipt.offerId, "other"),
      put_in(state.rides[ride.id].terminal_receipt.driverId, "B"),
      put_in(state.rides[ride.id].terminal_receipt.source_status, :driver_assigned),
      put_in(state.rides[ride.id].terminal_receipt.operation, :cancel),
      put_in(state.rides[ride.id].terminal_receipt.original_result.id, "other"),
      put_in(state.rides[ride.id].terminal_receipt.original_result.status, :cancelled),
      put_in(state.offers[offer.id].rideId, "other"),
      put_in(state.offers[offer.id].driverId, "B"),
      put_in(state.offers[offer.id].id, "other"),
      put_in(state.offers[offer.id].status, :cancelled),
      put_in(state.offers[offer.id], Map.delete(state.offers[offer.id], :acceptance_result)),
      put_in(state.offers[offer.id].acceptance_result.currentOfferId, "other"),
      put_in(state.offers[offer.id], Map.put(state.offers[offer.id], :expiration_receipt, %{})),
      put_in(state.rides["other"], other),
      put_in(state.offers["other"], %{state.offers[offer.id] | id: "other", status: :pending})
    ]

    for input <- variants, operation <- [:cancel, :complete] do
      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:terminal_ride, operation, ride.id}, nil, input)
    end

    assert state.rides[ride.id].terminal_receipt == receipt
  end

  test "synthetic false terminal closure never exempts a Driver from active ownership checks" do
    {server, ride, offer, _} = reserved()
    {:ok, _} = Store.accept_offer(server, ride.id, "A")
    {:ok, _} = Store.complete_ride(server, ride.id)
    {other, event} = matching(server, "other")
    state = :sys.get_state(server)
    broken = update_in(state.rides[ride.id], &Map.delete(&1, :terminal_receipt))

    assert {:reply, {:error, {:permanent, :inconsistent_ownership}}, final} =
             StateServer.handle_call({:process_event, event}, nil, broken)

    assert final.rides == broken.rides and final.drivers == broken.drivers and
             final.offers == broken.offers

    assert final.rides[other.id].status == :matching
    assert final.offers[offer.id].status == :completed
  end

  for {operation, accepted?} <- [complete: true, cancel: false, cancel: true] do
    test "live #{operation} accepted=#{accepted?} replay protects reused BUSY Driver and old timers" do
      {server, ride, offer, _} = reserved()

      accepted =
        if unquote(accepted?) do
          {:ok, accepted} = Store.accept_offer(server, ride.id, "A")
          accepted
        end

      command = terminal_command(unquote(operation))
      {:ok, result} = apply(Store, command, [server, ride.id])
      {other, event} = matching(server, "reuse")
      assert {:ok, :processed} = Store.process_event(server, event)
      assert {:ok, other_accepted} = Store.accept_offer(server, other.id, "A")
      before = :sys.get_state(server)
      assert apply(Store, command, [server, ride.id]) == {:ok, result}

      if accepted do
        assert Store.accept_offer(server, ride.id, "A") == {:ok, accepted}
      else
        assert Store.accept_offer(server, ride.id, "A") == {:error, :invalid_transition}
      end

      assert Store.expire_offer(server, offer.id) == {:ok, :ignored}
      assert Store.reject_offer(server, ride.id, "A") == {:error, :invalid_transition}
      assert :sys.get_state(server) == before
      assert before.drivers["A"].status == :busy
      assert before.rides[other.id] == other_accepted
      assert before.offers[other_accepted.currentOfferId].acceptance_result == other_accepted
      assert map_size(before.offers) == 2 and map_size(before.pending_events) == 4
      assert Store.create_ride(server, "original", body()) == {:ok, ride}
    end
  end

  test "synthetic active contradictions and preexisting terminal evidence cannot be overwritten" do
    {server, ride, offer, _} = reserved()
    state = :sys.get_state(server)

    variants = [
      put_in(state.rides[ride.id].assignedDriverId, "B"),
      put_in(state.rides[ride.id].currentOfferId, "missing"),
      put_in(state.drivers["A"].status, :busy),
      put_in(state.offers[offer.id].id, "wrong"),
      put_in(state.offers[offer.id], Map.put(offer, :acceptance_result, %{})),
      put_in(state.rides[ride.id], Map.put(state.rides[ride.id], :terminal_receipt, %{}))
    ]

    for input <- variants do
      assert {:reply, {:error, :inconsistent_ownership}, ^input} =
               StateServer.handle_call({:terminal_ride, :cancel, ride.id}, nil, input)
    end
  end

  test "synthetic terminal replay rejects contradictory current ownership of a reused Driver" do
    {server, ride, _, _} = reserved()
    {:ok, _} = Store.accept_offer(server, ride.id, "A")
    {:ok, _} = Store.complete_ride(server, ride.id)
    {other, event} = matching(server, "other")
    assert {:ok, :processed} = Store.process_event(server, event)
    {:ok, accepted} = Store.accept_offer(server, other.id, "A")
    state = :sys.get_state(server)
    other_offer = state.offers[accepted.currentOfferId]
    third = %{state.rides[other.id] | id: "third", currentOfferId: "third-offer"}
    extra = %{other_offer | id: "third-offer", rideId: "third"}
    broken = state |> put_in([:rides, "third"], third) |> put_in([:offers, "third-offer"], extra)

    assert {:reply, {:error, :inconsistent_ownership}, ^broken} =
             StateServer.handle_call({:terminal_ride, :complete, ride.id}, nil, broken)

    assert Store.complete_ride(server, ride.id) ==
             {:ok, state.rides[ride.id].terminal_receipt.original_result}

    assert :sys.get_state(server) == state
  end

  test "synthetic cross-Ride references cannot authorize release or hide behind terminal closure" do
    {server, ride, offer, _} = reserved()
    state = :sys.get_state(server)
    other = %{state.rides[ride.id] | id: "other", assignedDriverId: "B"}
    broken = put_in(state.rides["other"], other)

    assert {:reply, {:error, :inconsistent_ownership}, ^broken} =
             StateServer.handle_call({:terminal_ride, :cancel, ride.id}, nil, broken)

    {:ok, _} = Store.cancel_ride(server, ride.id)
    {third, event} = matching(server, "third")
    state = :sys.get_state(server)
    broken = put_in(state.rides["other"], other)

    assert {:reply, {:error, {:permanent, :inconsistent_ownership}}, final} =
             StateServer.handle_call({:process_event, event}, nil, broken)

    assert final.rides[third.id].status == :matching
    assert final.drivers == broken.drivers and final.offers == broken.offers
    assert broken.offers[offer.id].status == :cancelled
  end

  test "synthetic malformed retained rejection history cannot authorize unassigned cancellation or replay" do
    {server, ride, offer, _} = reserved()
    {:ok, _} = Store.reject_offer(server, ride.id, "A")
    before = :sys.get_state(server)
    broken = update_in(before.offers[offer.id], &Map.delete(&1, :rejection_receipt))

    assert {:reply, {:error, :inconsistent_ownership}, ^broken} =
             StateServer.handle_call({:terminal_ride, :cancel, ride.id}, nil, broken)

    {:ok, _} = Store.cancel_ride(server, ride.id)
    state = :sys.get_state(server)
    broken = update_in(state.offers[offer.id], &Map.delete(&1, :rejection_receipt))

    assert {:reply, {:error, :inconsistent_ownership}, ^broken} =
             StateServer.handle_call({:terminal_ride, :cancel, ride.id}, nil, broken)
  end

  test "discarded terminal responses replay immutable proof without reading a new clock" do
    for operation <- [:cancel, :complete] do
      {server, ride, _, clock} = reserved()
      assert {:ok, _} = Store.accept_offer(server, ride.id, "A")

      task =
        Task.async(fn ->
          assert {:ok, _} = apply(Store, terminal_command(operation), [server, ride.id])
          :response_lost
        end)

      assert Task.await(task) == :response_lost
      before = :sys.get_state(server)
      original = before.rides[ride.id].terminal_receipt.original_result
      :atomics.put(clock, 1, -999_999)
      assert apply(Store, terminal_command(operation), [server, ride.id]) == {:ok, original}
      assert :sys.get_state(server) == before
    end
  end

  defp terminal_command(:cancel), do: :cancel_ride
  defp terminal_command(:complete), do: :complete_ride
end
