# Acceptance criterion traceability

Audit date: 2026-10-27. The authoritative [challenge specification](challenge-spec.md)
is byte-for-byte identical to `../coding-challenge-3.md` from this project directory.
Source code defines current APIs; the [implementation guide](implementation-guide.md)
contains both current contracts and future plans. Accepted ADRs record decisions,
not completion certificates.

Status meanings:

- **VERIFIED**: the complete AC is implemented and supported by executed tests.
- **PARTIAL**: supporting components are implemented and tested, but the full AC
  or its integration evidence is incomplete.
- **NOT IMPLEMENTED**: the required workflow is absent; shared infrastructure or
  helper tests do not establish that workflow.
- **UNVERIFIED**: an implementation claim lacks supporting executed tests.

Historical reconciliation evidence before Features #8/#9: `mix compile --warnings-as-errors` and
`mix test` passed during this audit: **82 tests passed**. Those results verify
the assertions in the existing suite, not absent workflows.

Original test references (executed by that historical full-suite run):

- **Location**: [location_test.exs](../test/ride_dispatch/location_test.exs) — 20 tests.
- **Matcher**: [matcher_test.exs](../test/ride_dispatch/dispatch/matcher_test.exs) — 13 tests.
- **Driver state**: [state_machine_test.exs](../test/ride_dispatch/drivers/state_machine_test.exs) — 15 tests.
- **Store**: [store_test.exs](../test/ride_dispatch/dispatch/store_test.exs) — 21 tests.
- **Driver HTTP**: [driver_controller_test.exs](../test/ride_dispatch_web/controllers/driver_controller_test.exs) — 11 tests.
- **Error JSON**: [error_json_test.exs](../test/ride_dispatch_web/controllers/error_json_test.exs) — 2 tests.

Module names below are under `RideDispatch`; controller names are under
`RideDispatchWeb`. HTTP payloads and mappings are described in guide section H.

| AC | Required behavior | Implemented modules/functions/routes | Relevant automated tests | Status | Remaining work |
|---|---|---|---|---|---|
| AC-01 | Create/retrieve a unique REQUESTED ride; validate passenger and coordinates; require idempotency key, replay original result, reject changed payload | `Rides.create_ride/3`, `Rides.get_ride/2`, `Rides.Request.normalize/1`, `Store.create_ride/3`, `Store.get_ride/2`; atomic StateServer callback; seeded P001; `POST /rides`, `GET /rides/:rideId` | Request tests (3), Ride Store tests (7), Ride HTTP tests (9): coordinates/boundaries, strict fields, passenger validation, unique IDs, retrieval, 201 replay, conflicts and competing duplicates; full suite 116 passed | VERIFIED | Creation contract verified; Feature #10A HTTP test also verifies original POST replay after the real asynchronous MATCHING transition |
| AC-02 | Availability API, OFFERED/BUSY rules and coordinated lifecycle release | Driver State Machine, Store availability/reservation/acceptance/rejection commands and HTTP routes | Real AVAILABLE → OFFERED → BUSY, OFFERED → AVAILABLE on rejection, accepted rejection conflict, released Driver reuse/competition; availability HTTP conflicts | PARTIAL | Implement expire/cancel/complete coordinated release; pure transitions do not complete those workflows |
| AC-03 | Update valid coordinates, reject invalid ones, store and match using latest location | Location, Store.update_driver_location/3, PUT /drivers/:id/location; StateServer passes current Driver records to Matcher | Location/Store/Driver HTTP tests plus reservation latest-location test and Ride HTTP integration prove an update changes selected Driver | VERIFIED | No remaining specified clause; stale-update timestamp detection is not implemented or required |
| AC-04 | Ride-triggered nearest AVAILABLE matching; default/configurable 2 km radius; distance ordering, outside/none/ties; valid coordinates | Location.distance_km/2, Matcher.nearest/3 (minimum `{distance, id}` ordering), Store.process_event/2; authoritative DispatchRequested handler | Pure Matcher/Haversine tests plus reservation default/custom/exact-boundary/just-outside/tie/no-candidate checks and actual asynchronous Ride creation → reservation | VERIFIED | No remaining specified clause; scans approximate spherical distance and no performance claim is made |
| AC-05 | Pending/current-holder Offer lifecycle, coordinated acceptance/rejection, permanent Ride-scoped exclusions, timeout and rematching/release | Atomic reservation, Store.accept_offer/3 and Store.reject_offer/3; exact currentOfferId, immutable Offer-bound evidence; POST /rides/:rideId/offers/:driverId/accept and /reject | Acceptance Store/HTTP plus rejection Store (16), rematching (10), rejection HTTP (10): exact ownership, deadline, late pending rejection, replay, ambiguity, atomic release/event and automatic replacement | PARTIAL | Expiration/scheduler, cancellation/completion and live terminal lifecycle evidence remain absent |
| AC-06 | Explicit Ride lifecycle, invalid/duplicate handling, terminal states and coordinated release/assignment cleanup | Pure Ride State Machine; stored REQUESTED → MATCHING → DRIVER_ASSIGNED → DRIVER_ACCEPTED; rejection returns MATCHING and clears assignment/current Offer atomically | Pure state, reservation/event, acceptance and rejection tests; duplicate rejection never clears replacement ownership; terminal replay uses labeled synthetic callbacks | PARTIAL | Persist expire/cancel/complete workflows and prove release/terminal lifecycle races through legitimate integration |
| AC-07 | Rejection causes rematching; permanent same-Ride exclusions; other-Ride eligibility; no candidate stays MATCHING/nil | Store.reject_offer/3 retains history/releases Driver/clears Ride/enqueues Offer-derived DispatchRequested; existing dispatcher and Matcher use latest authoritative state and history | Live A → B and A/B/C exhaustion; no repeated Driver for same Ride; A reused on unrelated Ride; dynamic availability/location/nearest changes; no-candidate PROCESSED and no search loop | VERIFIED | All AC-07 rejection/rematching clauses verified; timeout-triggered rematching remains under AC-05/06 |
| AC-08 | Demonstrate idempotency for keyed Ride creation, Driver acceptance and Ride state transition; document strategy | Creation records, retained processed events/current ownership, immutable acceptance_result and rejection_receipt; original-result replay | Existing creation/acceptance tests plus competing first/duplicate Rejects, five HTTP Reject callers, lost results, actual queued Store timeout, replay after replacement acceptance/Driver reuse, corrupt receipt/link rejection and synthetic terminal compatibility | VERIFIED | Specified minimum behaviors and rejection extension verified; future expire/cancel/complete commands need idempotency tests. No crash-durable guarantee |
| AC-09 | Identify race, prevent simultaneous offers/accepted Rides for one Driver, test two different competing Rides and document strategy | Single authoritative callback validates reservation/acceptance/rejection and active ownership; BUSY excluded; ADR-002/README | Existing reservation/accepted-Ride races plus barrier-released Accept/Reject and duplicate Reject; two unrelated Rides compete for released A; final Ride/Driver/Offer/Event records and immutable evidence asserted | VERIFIED | Implemented reservation/acceptance/rejection safety verified. Original-loser arbitrary redispatch remains synthetic; expire/cancel/complete races need future integration tests |
| AC-10 | Ride Created → asynchronous dispatch event → Driver matching; README explains async choice, duplicate delivery and failure | One EventDispatcher, atomic event handlers and rejection creating one fresh DispatchRequested; existing discovery/retry framework reused | Existing event/reservation/HTTP suites plus live rematching, missed hints, restart before/after replacement commit, duplicate processing, bounded retry/FAILED and uncertain timeout rechecks; original events unchanged | VERIFIED | Specified async flow and rejection/rematching regression verified; no durable delivery or external-side-effect transaction claim. Remaining Offer lifecycle under AC-05/06 |

## Feature #9 verification

Executed: Request 3 + Ride Store 7 + Ride HTTP 9 tests passed; full suite **116 passed**.
`mix compile --warnings-as-errors`, `mix format --check-formatted`, and `git diff --check` passed.
Tests: [request](../test/ride_dispatch/rides/request_test.exs),
[Ride Store](../test/ride_dispatch/dispatch/ride_store_test.exs),
[Ride HTTP](../test/ride_dispatch_web/controllers/ride_controller_test.exs).
Feature #9's evidence above is historical. Feature #10A now also verifies the
stored REQUESTED → MATCHING transition and post-transition creation replay.

## Feature #10A verification (historical)

Full `mix test`: **133 passed**. Event Store: 6 tests; EventDispatcher: 10 tests;
Ride HTTP: 10 tests including the new async GET/current versus POST/original test.
`mix compile --warnings-as-errors`, `mix format --check-formatted`, and
`git diff --check` passed. Event tests:
[event_store_test.exs](../test/ride_dispatch/dispatch/event_store_test.exs),
[event_dispatcher_test.exs](../test/ride_dispatch/dispatch/event_dispatcher_test.exs).
No claims/leases, matching, reservation, external broker or new dependencies.
Timeout paths use controlled timeout signals around real processing outcomes;
worker crash tests kill real dispatcher processes before and after commit.
Owner replacement tests demonstrate volatile state loss and reconnect behavior.
Unsupported pending work is excluded from actionable selection but remains queryable.

## Feature #10B verification (historical)

Executed: reservation **22 passed**, reservation dispatcher **9 passed**; focused
Store/event/Location/Matcher/Driver and Ride State Machine/HTTP regressions:
**153 passed**. Full `mix test`: **165 passed**. Compilation with warnings as
errors, formatting and `git diff --check` passed.

Tests: [reservation](../test/ride_dispatch/dispatch/reservation_test.exs),
[reservation dispatcher](../test/ride_dispatch/dispatch/reservation_dispatcher_test.exs),
[Ride HTTP](../test/ride_dispatch_web/controllers/ride_controller_test.exs).
Meaningful RED failures preceded query/configuration, reservation, no-candidate
and exclusion, ownership, deadline/clock, actionable discovery and defensive
failure-path implementations. Existing Matcher and dispatcher properties also
received passing regression tests; no artificial RED history was reconstructed.

Mandatory regressions: expired-but-PENDING Offer retains ownership; distinct
synthetic event IDs produce one current Offer in either processing order; delayed
pending work gets a full timeout from reservation time, with before/at/after
expiration predicate checks. Synthetic callback fixtures are separate from live
concurrency and HTTP evidence. No production mutation fixtures were introduced.
Two defensive P2 audit findings (malformed event identity/metadata and mismatched
Driver map identity) were reproduced RED and fixed GREEN. No unresolved P0/P1
finding was identified. Unknown unsupported events remain pending; #10A pending
DispatchRequested work becomes supported without reopening RideCreated.

## Feature #11 verification (historical)

Executed: [acceptance Store tests](../test/ride_dispatch/dispatch/acceptance_test.exs)
**18 passed**; [HTTP acceptance tests](../test/ride_dispatch_web/controllers/offer_acceptance_test.exs)
**10 passed**. The reservation dispatcher suite now has 10 tests, including
async reservation → acceptance → BUSY exclusion. Focused Store/state-machine/
reservation/event/HTTP regressions **156 passed**; full `mix test` **194 passed**.
Compilation with warnings as errors, formatting and diff checks passed.

Meaningful RED/GREEN groups cover first acceptance, exact identity/ownership,
processing-time deadline, immutable replay, ambiguity/stale attempts, synthetic
terminal replay, HTTP route/contracts and audit failures. Passing concurrency
regressions were committed honestly without reconstructing RED history.

Acceptance changes only the exact Ride/Driver/Offer together. It creates no Event
or Offer and leaves creation idempotency unchanged. Receipt validation precedes
new-attempt clock checks; equality expires first attempts while successful late
replay changes nothing. Same-pair history is conservatively ambiguous; URL Driver
identity does not authenticate the network caller. All success/error schemas use
existing envelopes. Raw malformed JSON and unread nonempty bodies are tested.

Actual live evidence: ten competing Store callers, five competing HTTP callers,
ten two-Ride pending-to-accepted races, acceptance competing with another Ride's
dispatch, real dispatcher BUSY exclusion and real BUSY HTTP availability conflict.
Two terminal-state compatibility tests use standalone snapshots: no live terminal
or release workflow is claimed. A fresh event for the original losing Ride is
synthetic; replaying its acknowledged event is explicitly not another match.
Discarded responses model lost results, not a real TCP disconnect.

P2 audit gaps in malformed receipt/state handling, broken active-state classification,
conflicting prior success and unparsed HTTP bodies were reproduced with failing tests and fixed. No unresolved
P0/P1 finding was identified. Accepted ADRs and original specification are unchanged.
At that checkpoint no rejection, expiration, cancellation, completion, rematching,
scheduler, authentication infrastructure or new dependency was added.

## Feature #12 verification

Executed [rejection Store tests](../test/ride_dispatch/dispatch/rejection_test.exs):
**16 passed**; [rematching/recovery tests](../test/ride_dispatch/dispatch/rematching_test.exs):
**10 passed**; [rejection HTTP tests](../test/ride_dispatch_web/controllers/offer_rejection_test.exs):
**10 passed**. Focused acceptance/rejection/rematching/HTTP **64 passed**;
full `mix test` **230 passed**. Compile warnings-as-errors, format and diff checks passed.

Rejection installs Ride MATCHING/unassigned, Driver AVAILABLE, Offer REJECTED with
immutable receipt and exactly one `redispatch-{offerId}` event together. Isolated
Store assertions observe PENDING; live tests allow real asynchronous progression
to PROCESSED and verify the exact event, historical receipt and replacement ownership.
Replay validates linked PENDING/PROCESSED/FAILED event identity without mutation,
including after B acceptance or A reuse elsewhere. Strict route bodies, sanitized
errors and private owner isolation remain intact. Stale A acceptance after B
accepts now returns a real HTTP 409; malformed acceptance evidence remains an invariant.

Barrier-released duplicate Rejects, Accept/Reject competition (plus both ordered
outcomes), duplicate redispatch processing and two unrelated Rides competing for
released A assert final authoritative records. Dynamic candidate tests block only
the dispatcher boundary, then update location/availability through Store before
processing. Successive rejections demonstrate permanent Ride-scoped exclusion and
exhaustion with no immediate search/retry loop. Technical failures remain distinct:
backoff/attempt limits, retained FAILED records, successful retry and receipt replay
after failure are tested. Worker restarts before/after commit and missed hints recover.

An actual default Store call timeout is exercised with an isolated suspended owner;
its queued rejection subsequently commits, and retry returns the same receipt.
Dispatcher timeout branches use controlled signals around real processing, not
elapsed network timeouts. Lost HTTP responses are modeled by discarding results.
Terminal progression/replay remains labeled callback compatibility evidence, not
implemented cancellation/completion/expiration. No new mutation backdoors,
infrastructure, dependencies or Accepted ADR changes. No unresolved P0/P1 found.

## Evidence boundaries and documentation gaps

- Driver HTTP tests use raw JSON through the Endpoint parser. Malformed JSON
  syntax is checked with `assert_error_sent`; parsed invalid fields are checked
  separately. Original conflict mapping uses a protocol fixture; Feature #10B also verifies
  real OFFERED HTTP conflicts after reservation and Feature #11 verifies real BUSY
  conflicts after acceptance. Ambiguity/invariant response mapping also uses
  an explicitly labeled response-only protocol fixture, with real validation in
  StateServer callback tests. Feature #12 proves stale acceptance HTTP 409 through
  live rejection → rematching → replacement acceptance.
- Production has one named StateServer, with seeded Passenger P001 and initially empty Drivers/Rides/events. Tests inject isolated
  supervised PIDs through trusted `conn.private[:dispatch_store]`; no global
  application-environment mutation or per-request StateServer is used. Seeds
  accept only offline/available Drivers. No live-state test backdoor exists.
- Accepted [ADR-001](adr/ADR-001-matching.md), [ADR-002](adr/ADR-002-concurrency.md)
  and [ADR-003](adr/ADR-003-event-processing.md) remain unchanged in #10B/#11/#12. ADR-002's Phase B scope is historical. Single-mailbox
  contention, scans/sorting, volatile restart loss, single-owner/node limits,
  timeout uncertainty, and stale future ETS projections remain documented limits.
- Additional evaluation deliverables are incomplete: `README.md` now documents Ride creation, replay and volatile-state limits; full workflow documentation remains incomplete; `architecture.md` and `sequence-diagram.md` are empty. Ride/event
  correlated observability, the full scaling explanation, and runnable workflow
  documentation remain future work. The guide's target diagram/roadmap and
  Accepted ADRs do not complete these deliverables.
- The guide's historical scalar Ride example is not the actual API or TDD history.
  The implemented pure Ride State Machine accepts a map. Future lifecycle
  signatures remain provisional; creation/query and event-processing APIs are implemented.
