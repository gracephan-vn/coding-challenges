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
Creation only records pending work. The supervised dispatcher now consumes RideCreated asynchronously as described below; Driver matching remains unimplemented and AC-10 incomplete.

The original domain result is stored separately from current Ride state; HTTP
serialization is not stored. GET reads current state, while POST replay reads the
original creation result. The asynchronous HTTP integration test verifies GET becomes MATCHING while an identical POST retry retains the original REQUESTED creation result.

State and idempotency are volatile. A caller timeout does not cancel a command:
retrying with the same key is safe while the owner survives. After owner crash or
restart, keys, Rides and events are lost; a retry can create a new Ride. This is
not crash-durable idempotency or a durable transactional outbox. One mailbox
serializes reads/writes, records grow without eviction, and there are no external
side-effect transactions or multi-node guarantees. Acceptance and broader lifecycle idempotency, DispatchRequested consumption, reservation and offer workflows remain future features. See [AC traceability](docs/ac-traceability.md) for evidence boundaries.


## Asynchronous event processing (Feature #10A)

One supervised `Dispatch.EventDispatcher` starts after the named StateServer,
independently of HTTP. Store operations accept an explicit PID/name for isolated
tests. After a successful create call, the Store wrapper requests a wake-up hint;
creation's atomic callback does not publish events or spawn tasks. Startup and
one-second recovery scans cover missed notifications, including a lost creation
reply. Hints coalesce; only due supported events are selected, one per dispatcher
mailbox turn. A single replaceable timer schedules the next eligible retry or
recovery scan. Unsupported events cannot cause an immediate rescan loop.

`Store.process_event(server, event_id)` performs this complete transition within
one callback:

```text
RideCreated PROCESSED + Ride MATCHING + one DispatchRequested PENDING
```

It reuses `Rides.StateMachine.transition/2`. The successor ID is deterministically
`dispatch-{rideId}`, distinct from the Ride and original event. Repeating a
processed event changes nothing; a distinct duplicate for an already-MATCHING
Ride is acknowledged as ignored without another successor. Known later or
terminal Ride states are also ignored without changing the Ride. Missing Rides
or invalid Ride states produce a permanent failed event, without a retry.

`DispatchRequested` has no handler in 10A: it remains pending, unchanged and
visible through `Store.list_events/1` and `Store.get_event/2`. It is excluded from
`list_actionable_events/1` and retry scheduling. Feature #10B must introduce its
handler using the same atomic processing command, preserving these pending
records rather than reopening acknowledged RideCreated events.

There are no claims, leases, or separate acknowledgements. Event records remain
in the authoritative `pending_events` map after processing/failure. Attempt count
defaults to zero until first processing/failure; `next_attempt_at` uses monotonic
milliseconds and defaults to immediate eligibility. Completed records carry an
outcome; failed records carry a sanitized reason.

Definite worker-side exceptions or retryable results use
`Store.fail_event(server, id, observed_attempts, :processing_failed)`. StateServer
checks the observed attempt version before accounting for failure, avoiding
repeated failure reports consuming attempts. Three attempts total are allowed,
with one-second then two-second backoff; exhaustion is retained as failed.
Production processing calls Store directly; a startup processing-function option
outside the owner allows deterministic fault injection in tests. No caller-supplied
mutation callback is installed in StateServer.

A Store timeout is uncertain, not a processing failure. The dispatcher rereads the
event before retrying and never consumes a failure attempt for a timeout. A worker
crash before processing leaves pending work for restart; a crash after commit
finds the event already processed. When a registered owner is replaced, the
dispatcher reconnects; the old owner's volatile work is lost. This mechanism
provides duplicate-safe local transitions, not durable or exactly-once delivery.

Tests use isolated owners/dispatchers, fake monotonic time, process barriers and
telemetry message assertions without sleeps. Run:

```sh
mix test test/ride_dispatch/dispatch/event_store_test.exs test/ride_dispatch/dispatch/event_dispatcher_test.exs test/ride_dispatch_web/controllers/ride_controller_test.exs
```

AC-08 remains partial (Driver acceptance and broader lifecycle idempotency),
AC-09 still requires reservation and two different competing Rides, and AC-10
remains partial until asynchronous Driver matching and its failure/duplicate
handling are implemented. Event scans and retained records still contend for
one mailbox and grow in memory; no throughput or durable recovery is promised.
