# RideDispatch

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://phoenix.hexdocs.pm/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://phoenix.hexdocs.pm/overview.html
* Docs: https://phoenix.hexdocs.pm
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix

## Ride creation and retrieval (Feature #9)

The application supervises one `Dispatch.StateServer`, seeded with Passenger
`P001`. Drivers initially remain empty. Run `mix test` for regression tests;
`mix test test/ride_dispatch/dispatch/ride_store_test.exs` includes barrier-released
concurrent duplicate and conflicting creation commands without sleeps.

```sh
curl -i -X POST http://localhost:4000/rides \
  -H 'Content-Type: application/json' \
  -H 'Idempotency-Key: 7f4d9c2e-ride-request-001' \
  -d '{"passengerId":"P001","pickup":{"latitude":10.7769,"longitude":106.7009},"destination":{"latitude":10.8231,"longitude":106.6297}}'
```

POST returns **201**, a `Location: /rides/{rideId}` header, and:

```json
{"data":{"rideId":"ride-N","passengerId":"P001","pickup":{"latitude":10.7769,"longitude":106.7009},"destination":{"latitude":10.8231,"longitude":106.6297},"status":"REQUESTED","assignedDriverId":null}}
```

Use `GET /rides/{rideId}` for the current Ride (**200**, or **404** if absent).
Repeat the POST with the same key and equivalent body to receive the original
**201** representation. A different canonical request with that key returns
**409**. Invalid/missing headers or fields, unsupported fields, invalid coordinates
and unknown Passengers on new keys return **400**. Errors use
`{"errors":{"detail":"Bad Request"}}`, `"Not Found"`, or `"Conflict"`.

Strict fields and replaying 201 are design decisions. Only `passengerId`, `pickup`
and `destination` are allowed; each coordinate object requires exactly `latitude`
and `longitude`. No numeric strings or extra fields are accepted. JSON whitespace
and key order do not matter; equal numeric coordinates (10 and 10.0) compare
identically without rounding. Passenger IDs are exact strings. Exactly one
nonblank Idempotency-Key is required, treated as opaque and case-sensitive.
Keys are global across Passengers within the single state owner, with no expiry.

The controller calls `Rides`, then `Dispatch.Store`; the authoritative callback
validates the key and canonical request before checking replay/conflict. Only a
new key checks current Passenger existence. Completed identical retries do not
revalidate mutable Passenger state. Store accepts the same strict string-keyed
request map; one normalizer provides validation at both boundaries.

One callback installs the Ride, idempotency record (canonical request plus original
domain result), and one pending event together. Event shape:
`%{eventId: "event-N", rideId: "ride-N", type: :ride_created, status: :pending}`.
No timestamp is required. Ride/Event IDs use distinct prefixes and a VM-wide
unique counter; uniqueness is not promised across VM restarts. No external I/O,
message publication, task spawning, or matching occurs in the creation callback.
A pending event is neither delivered nor processed: AC-10 remains incomplete.

The original domain result is stored separately from current Ride state; HTTP
serialization is not stored. GET reads current state, while POST replay reads the
original creation result. There is no lifecycle integration yet, so replay after a
real stored status transition is an explicitly deferred integration test.

State and idempotency are volatile. A caller timeout does not cancel a command:
retrying with the same key is safe while the owner survives. After owner crash or
restart, keys, Rides and events are lost; a retry can create a new Ride. This is
not crash-durable idempotency or a durable transactional outbox. One mailbox
serializes reads/writes, records grow without eviction, and there are no external
side-effect transactions or multi-node guarantees. Acceptance/lifecycle
idempotency, dispatch consumption, reservation and offer workflows remain future
features. See [AC traceability](docs/ac-traceability.md) for evidence boundaries.
