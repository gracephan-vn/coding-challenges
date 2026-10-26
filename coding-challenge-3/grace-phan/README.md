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
Creation only records pending work. The supervised dispatcher consumes RideCreated and DispatchRequested asynchronously, then atomically reserves an eligible Driver as described below.

The original domain result is stored separately from current Ride state; HTTP
serialization is not stored. GET reads current state, while POST replay reads the
original creation result. The asynchronous HTTP integration test verifies GET becomes MATCHING while an identical POST retry retains the original REQUESTED creation result.

State and idempotency are volatile. A caller timeout does not cancel a command:
retrying with the same key is safe while the owner survives. After owner crash or
restart, keys, Rides and events are lost; a retry can create a new Ride. This is
not crash-durable idempotency or a durable transactional outbox. One mailbox
serializes reads/writes, records grow without eviction, and there are no external
side-effect transactions or multi-node guarantees. Acceptance, rejection, release
and rejection-triggered rematching are implemented below; expiration and
cancellation/completion remain future features. See [AC traceability](docs/ac-traceability.md) for evidence boundaries.


## Asynchronous event processing and reservation (Features #10A/#10B)

Asynchronous processing keeps matching outside the HTTP response lifecycle and
lets pending work survive request completion or dispatcher restart while its owner
remains alive. One supervised `Dispatch.EventDispatcher` starts after the named StateServer,
independently of HTTP. Store operations accept an explicit PID/name for isolated
tests. After a successful create or reject call, the Store wrapper requests a wake-up hint;
creation's atomic callback does not publish events or spawn tasks. Startup and
one-second recovery scans cover missed notifications, including a lost creation
reply. Hints coalesce; only due supported events are selected, one per dispatcher
mailbox turn. A single replaceable timer schedules the next eligible retry or
recovery scan. Unsupported events cannot cause an immediate rescan loop.

`Store.process_event(server, event_id)` handles each event in one authoritative
callback. RideCreated processing installs:

```text
RideCreated PROCESSED + Ride MATCHING + one DispatchRequested PENDING
```

It reuses `Rides.StateMachine.transition/2`. The successor ID is deterministically
`dispatch-{rideId}`, distinct from the Ride and original event. Repeating a
processed event changes nothing; a distinct duplicate for an already-MATCHING
Ride is acknowledged as ignored without another successor. Known later or
terminal Ride states are also ignored without changing the Ride. Missing Rides
or invalid Ride states produce a permanent failed event, without a retry.

DispatchRequested processing reuses the pure Matcher and both State Machines,
selecting from current authoritative Driver coordinates/availability. It installs:

```text
Ride DRIVER_ASSIGNED + assignedDriverId + currentOfferId
Driver OFFERED + one Offer PENDING + DispatchRequested PROCESSED
```

Selection, ownership checks, reservation and acknowledgement share one callback.
Existing pending #10A DispatchRequested events are actionable without reopening
RideCreated. Unknown event types remain pending and excluded from retry scans.
Repeated processed events change nothing; distinct events for a consistently
assigned Ride are acknowledged as ignored. Missing/invalid Rides, invalid pickup,
and contradictory ownership permanently fail the event without changing business
records. A Driver's status alone cannot override conflicting Ride/Offer ownership.

No candidate is a processed `:no_candidate` outcome: the Ride stays MATCHING with
nil assignment/current Offer, and no Offer or redispatch is created. Processing
attempts still increment; no infrastructure retry failure is charged. Future
legitimate redispatch must enqueue a new event identity, never reopen a processed
one. There is no automatic search after availability/location changes.

Offers retain `id`, `rideId`, `driverId`, `status: :pending`, `created_at_ms` and
`expires_at_ms`. IDs use an independent `offer-` prefix and VM-wide unique counter.
`Store.get_offer/2` and `Store.list_offers/1` are read-only queries; the latter sorts
by ID. Retained rejected/expired Offer history supplies permanent Ride-scoped
exclusions; rejection records these outcomes now, while expiration remains future work.

Application configuration `:ride_dispatch, :matching_radius_km` defaults to 2.0
(nonnegative number); `:offer_timeout_ms` defaults to 30_000 (positive integer).
Invalid configuration/clock results reject owner startup. Tests inject these as
StateServer options with a trusted, nonblocking monotonic-millisecond clock.
Reservation reads time immediately before Offer construction, after selection:
`expires_at_ms = reservation_now_ms + offer_timeout_ms`.
`Dispatch.Offer.expired?/2` uses `now_ms >= expires_at_ms`. Integer arithmetic does
not impose fixed-width overflow. Negative monotonic values are valid; timestamps
are not meaningful across VM restarts. Invalid runtime clock readings leave
business state unchanged; discovery returns no actionable work until a later scan.

A deadline passing does not close a pending Offer or release its Driver. Only an
explicit rejection or future expiration command may release it. There is no
expiration scheduler, cancellation or completion; rematching occurs after rejection,
with no continuous search loop.

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
mix test test/ride_dispatch/dispatch/reservation_test.exs test/ride_dispatch/dispatch/reservation_dispatcher_test.exs test/ride_dispatch/dispatch/event_store_test.exs test/ride_dispatch/dispatch/event_dispatcher_test.exs test/ride_dispatch_web/controllers/ride_controller_test.exs
```

The reservation tests barrier-release two different Ride callers against one Driver
for 20 runs and inspect both Rides, Driver, all Offers and Events. Another test
competes a real dispatcher with a Store caller; the dispatcher itself remains a
single consumer. Synthetic callback fixtures cover distinct event IDs for one Ride,
terminal/inconsistent state and rejected/expired history; these are explicitly
separate from live integration evidence. Timeout tests use controlled timeout
signals before/after real Store processing, rather than an elapsed network timeout.

Feature #10B recorded 165 passing full-suite tests. Event, Driver, Ride and history
scans contend for one mailbox and retained records grow in memory; no throughput,
cross-node consistency or durable recovery is promised.

## Offer acceptance (Feature #11)

```sh
curl -i -X POST http://localhost:4000/rides/{rideId}/offers/{driverId}/accept \
  -H 'Accept: application/json'
```

An empty body or `{}` is accepted; no Offer ID or Idempotency-Key is required.
Unsupported fields, parsed non-object JSON and nonempty unparsed bodies return
400. Path identifiers select the Ride/Driver; body/query fields cannot override
them, set owner time, or choose a test StateServer. Driver identity in the URL is
an ownership selector, not authentication of the network caller.

`Rides.accept_offer(server, ride_id, driver_id)` delegates to
`Store.accept_offer/3`. It returns `{:ok, original_accepted_ride}`, `:not_found`, or
`{:error, reason}`. One StateServer callback validates exact `currentOfferId`, map
identities, Ride/Driver/Offer links and absence of conflicting active ownership,
checks trusted monotonic processing time, and applies both existing State Machines:

```text
Ride DRIVER_ACCEPTED + Driver BUSY + Offer ACCEPTED
assignedDriverId/currentOfferId preserved; no new Offer or Event
```

First acceptance requires `now_ms < expires_at_ms`. Equality is expired. Failure
leaves all state unchanged, including the expired-but-unreleased reservation.
Invalid clock/deadline state produces a controlled error. On success the exact
Offer retains immutable `accepted_at_ms` and `acceptance_result` (the original
accepted Ride snapshot). Receipt identity, successful timestamp and immutable Ride
fields must agree; DRIVER_ACCEPTED/BUSY status alone is insufficient evidence.

HTTP first success and verified replay both return 200 using the existing public
Ride `data` schema, with `status: "DRIVER_ACCEPTED"` and its `assignedDriverId`.
Replay returns that original domain result before new-attempt clock/deadline
checks, changes nothing and never reapplies transitions. GET returns current
state; POST /rides still replays its original REQUESTED creation result.
Other responses use the existing `errors.detail` envelope: 400 malformed request,
404 unknown resources/absent Offer relationship, 409 wrong Driver, expired/stale
or ambiguous request, and 500 inconsistent ownership/evidence or invalid clock.

The Ride/Driver-only route cannot identify different historical attempts involving
the same pair. Conservatively, multiple Offers for that pair return
`:ambiguous_offer` without mutation; history for other Drivers is allowed unless
it contradicts successful acceptance ownership. This is an approved API policy,
not an additional challenge requirement. No generic idempotency framework is used.

Future lifecycle commands must retain the receipt when closing an accepted Offer.
Synthetic callback tests verify replay after COMPLETED/CANCELLED, including cleared
current identity and a Driver subsequently BUSY on another Ride. These are
compatibility fixtures, not implemented terminal lifecycle workflows. Stale
requests without successful evidence conflict; replay never resurrects state.
Retries after uncertain/lost responses are safe while the owner survives; receipts
are lost with all other runtime state after owner crash. Tests discard completed
responses to model loss; no real network-disconnection guarantee is claimed.

Historical Feature #11 verification: 18 acceptance Store tests, 10 HTTP acceptance tests;
156 focused regressions and **194 full-suite tests passed**. Compilation with
warnings as errors, formatting and diff checks passed. Run:

```sh
mix test test/ride_dispatch/dispatch/acceptance_test.exs test/ride_dispatch_web/controllers/offer_acceptance_test.exs test/ride_dispatch/dispatch/reservation_dispatcher_test.exs
```

Barrier-released duplicate Store and HTTP callers preserve one receipt. Ten live
two-Ride reservation races continue through acceptance; another Ride cannot take
the BUSY Driver. Acceptance also competes directly with another Ride's dispatch,
and real asynchronous dispatcher tests preserve accepted ownership. Final Ride,
Driver, Offer and Event records are asserted. Redispatch of the original losing
Ride uses a synthetic new-event fixture: no generic manual redispatch command exists.

AC-08's specified creation/acceptance/transition idempotency and AC-09's concurrent
assignment requirements are VERIFIED with these tests and documented strategies.
Feature #12 extends this evidence to rejection/rematching below. Expiration,
cancellation and completion remain absent; AC-02/05/06 remain PARTIAL. See
[AC traceability](docs/ac-traceability.md) for the evidence boundaries.

## Offer rejection and automatic rematching (Feature #12)

`POST /rides/{rideId}/offers/{driverId}/reject` accepts no body or `{}`, with no
Offer ID or Idempotency-Key. `Rides.reject_offer/3` delegates to
`Store.reject_offer(server, ride_id, driver_id)`, returning
`{:ok, original_matching_ride}`, `:not_found`, or `{:error, reason}`. HTTP success
and verified replay both return **200** with the existing Ride `data` envelope,
`status: "MATCHING"` and `assignedDriverId: null`. GET always returns current state.
Malformed/unsupported fields, non-object JSON and unparsed nonempty bodies return
**400**; unknown resources/absent relationship **404**; wrong holder, accepted,
stale or ambiguous operations **409**; corrupt invariants/trusted time **500**.
Errors retain sanitized `errors.detail`; URL Driver identity is not authentication.

The single callback validates exact current Offer/storage identity, linked
Ride/Driver ownership, active uniqueness, absence of contradictory acceptance
evidence and timestamps, then applies both `:reject_offer` State Machine actions:

```text
Ride MATCHING + assignedDriverId/currentOfferId nil
Driver AVAILABLE + original Offer REJECTED
one DispatchRequested PENDING, eventId = "redispatch-" <> offer.id
```

The Offer retains immutable `rejection_receipt` fields `offerId`, `rideId`,
`driverId`, `rejected_at_ms`, `redispatch_event_id` and `original_result` (the
matching Ride snapshot). Event-ID collision rejects the entire command. Replay
requires matching receipt/storage identities, valid original result and the linked
DispatchRequested record; its status may be PENDING, PROCESSED or FAILED. It never
releases a Driver again, alters replacement ownership, rewrites receipts or creates
another event, including after replacement acceptance or Driver reuse elsewhere.
Failed rematching does not undo rejection. Multiple Offers for the same Ride/Driver
pair are conservatively ambiguous because the route has no Offer ID.

Late rejection at/after the deadline is an approved policy while the Offer remains
current PENDING with valid reservation ownership. Trusted processing time must be
an integer no earlier than Offer creation; no automatic expiration or implicit
release occurs from a passed deadline alone. Previously accepted Offers cannot be
rejected. A closed unaccepted historical Offer is classified before new-acceptance
exclusivity checks: stale A acceptance after B accepts returns **409**, while
malformed acceptance evidence still returns a controlled invariant failure.

After commit, Store sends only a wake-up hint. The existing dispatcher consumes
the replacement event using latest authoritative locations/availability, configured
radius and deterministic ties. Rejected Drivers remain excluded for that Ride
forever, but may serve unrelated Rides. A successful no-candidate attempt is
PROCESSED with `:no_candidate` and increments attempts for that processing call,
without charging an infrastructure failure or creating a new event. Technical
failures retain bounded retry/backoff/FAILED behavior;
timeouts remain uncertain and require authoritative rechecks. Missed hints and
worker restart are recovered by scanning while the owner survives.

Atomic Store tests run without a dispatcher and observe the new event PENDING.
Live HTTP/dispatcher observations can already see it PROCESSED; exact identity,
history and business effects remain required. Original creation and rejection
responses remain unchanged even when current Ride state progresses.

Executed: **16 rejection Store**, **10 rematching/recovery**, **10 rejection HTTP**
tests; **64** focused acceptance/rejection/rematching/HTTP tests and **230** full
suite tests passed. Compile warnings-as-errors, format and diff checks passed.
Tests prove A → B, latest candidate changes, exhaustion and other-Ride eligibility,
competing duplicate Rejects, ordered and competing Accept/Reject, two unrelated
Rides competing for released A, exactly-one events, restart before/after commit,
technical failure versus no candidate, and replay after an actual queued Store
call timeout. Dispatcher timeout signals remain controlled simulations; discarded
HTTP responses do not simulate a real TCP disconnect. Terminal replay is tested
only with labeled callback fixtures, not live lifecycle commands.

```sh
mix test test/ride_dispatch/dispatch/rejection_test.exs test/ride_dispatch/dispatch/rematching_test.exs test/ride_dispatch_web/controllers/offer_rejection_test.exs
```

AC-07 is VERIFIED for its rejection/rematching clauses; AC-08/09/10 regressions
remain green. One mailbox, history scans/retention, volatile owner loss and
single-node limits remain. Expiration, cancellation and completion are future
work; their races and live terminal replay must be tested when implemented.
