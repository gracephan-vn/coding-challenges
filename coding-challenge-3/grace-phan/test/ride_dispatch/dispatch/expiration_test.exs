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
end
