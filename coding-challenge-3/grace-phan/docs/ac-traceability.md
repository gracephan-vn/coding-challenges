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
| AC-02 | Availability API, OFFERED/BUSY rules and coordinated lifecycle release | Driver State Machine, Store availability/reservation/acceptance commands and HTTP routes | Real AVAILABLE → OFFERED → BUSY, wrong-holder rejection, exclusive reservation and real OFFERED/BUSY availability HTTP conflicts; pure release transitions | PARTIAL | Implement reject/expire/cancel/complete coordinated release; supporting pure transitions do not complete those workflows |
| AC-03 | Update valid coordinates, reject invalid ones, store and match using latest location | Location, Store.update_driver_location/3, PUT /drivers/:id/location; StateServer passes current Driver records to Matcher | Location/Store/Driver HTTP tests plus reservation latest-location test and Ride HTTP integration prove an update changes selected Driver | VERIFIED | No remaining specified clause; stale-update timestamp detection is not implemented or required |
| AC-04 | Ride-triggered nearest AVAILABLE matching; default/configurable 2 km radius; distance ordering, outside/none/ties; valid coordinates | Location.distance_km/2, Matcher.nearest/3 (minimum `{distance, id}` ordering), Store.process_event/2; authoritative DispatchRequested handler | Pure Matcher/Haversine tests plus reservation default/custom/exact-boundary/just-outside/tie/no-candidate checks and actual asynchronous Ride creation → reservation | VERIFIED | No remaining specified clause; scans approximate spherical distance and no performance claim is made |
| AC-05 | Pending/current-holder Offer lifecycle, coordinated acceptance/rejection, permanent Ride-scoped exclusions, timeout and rematching/release | Atomic reservation and Store.accept_offer/3; exact currentOfferId; immutable acceptance evidence; POST /rides/:rideId/offers/:driverId/accept | Acceptance Store (18) and HTTP (10) tests cover identities, active ownership, deadline equality, expired-but-held reservation, replay, ambiguity and concurrent duplicates | PARTIAL | Reject/expiration/scheduler, rematching, cancellation/completion and live terminal lifecycle evidence remain absent |
| AC-06 | Explicit Ride lifecycle, invalid/duplicate handling, terminal states and coordinated release/assignment cleanup | Pure Ride State Machine; stored REQUESTED → MATCHING → DRIVER_ASSIGNED → DRIVER_ACCEPTED; Store replay intercepts duplicate acceptance before pure transitions | Pure state tests, reservation/event tests, acceptance Store/HTTP; terminal replay uses labeled synthetic callbacks and never mutates terminal state | PARTIAL | Persist reject/expire/cancel/complete workflows and prove release, assignment cleanup and lifecycle races through legitimate integration |
| AC-07 | Rejection causes rematching; permanent same-Ride exclusions; other-Ride eligibility; no candidate stays MATCHING/nil | Reservation derives exclusions from retained rejected/expired Offers and passes them to Matcher; no-candidate acknowledgement | Pure Matcher and synthetic callback history tests verify Ride scope, another Driver, exhaustion and no new Offer; live no-candidate Store tests | PARTIAL | Real reject/timeout commands must record history, release Driver, clear assignment and enqueue a fresh dispatch event; automatic rematching is absent |
| AC-08 | Demonstrate idempotency for keyed Ride creation, Driver acceptance and Ride state transition; document strategy | Canonical creation records; retained processed events/current ownership; accepted Offer retains accepted_at_ms and original Ride acceptance_result | Creation tests plus duplicate event/Ride transitions; ten barrier-released acceptance callers, five HTTP callers, discarded-response and late replay; malformed receipts rejected; synthetic terminal compatibility clearly labeled | VERIFIED | All specified minimum behaviors have executed evidence and README strategy. Future reject/expire/cancel/complete commands still need their own idempotency tests; no crash-durable guarantee |
| AC-09 | Identify race, prevent simultaneous offers/accepted Rides for one Driver, test two different competing Rides and document strategy | Single authoritative callback validates reservation/acceptance and all active ownership; BUSY excluded by Matcher; ADR-002 and README | Existing 20 live reservation race runs, 10 pending-to-accepted two-Ride runs, accept-versus-other-dispatch contention, concurrent identical acceptance and real dispatcher BUSY exclusion; final Rides/Driver/Offers/Events asserted | VERIFIED | Required pending/accepted assignment safety verified for implemented workflows. Original-loser fresh redispatch is synthetic because no trigger exists; future release/rematch races require integration tests |
| AC-10 | Ride Created → asynchronous dispatch event → Driver matching; README explains async choice, duplicate delivery and failure | One supervised EventDispatcher; Store discovery/process/fail APIs; atomic RideCreated and DispatchRequested handlers | Event Store (6), EventDispatcher (10), reservation (22), reservation dispatcher (10), Ride HTTP (11 total): full async flow, historical handoff, competing callers, restart, recovery, retries/exhaustion and timeout rechecks | VERIFIED | Specified event-driven matching flow verified; Offer lifecycle remains under AC-05/06/07/08/09. No durable delivery or external-side-effect transaction claim |

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

## Feature #11 verification

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
No rejection, expiration, cancellation, completion, rematching, scheduler,
authentication infrastructure or new dependency was added.

## Evidence boundaries and documentation gaps

- Driver HTTP tests use raw JSON through the Endpoint parser. Malformed JSON
  syntax is checked with `assert_error_sent`; parsed invalid fields are checked
  separately. Original conflict mapping uses a protocol fixture; Feature #10B also verifies
  real OFFERED HTTP conflicts after reservation and Feature #11 verifies real BUSY
  conflicts after acceptance. Ambiguity/stale/invariant response mapping also uses
  an explicitly labeled response-only protocol fixture, with real validation in
  StateServer callback tests.
- Production has one named StateServer, with seeded Passenger P001 and initially empty Drivers/Rides/events. Tests inject isolated
  supervised PIDs through trusted `conn.private[:dispatch_store]`; no global
  application-environment mutation or per-request StateServer is used. Seeds
  accept only offline/available Drivers. No live-state test backdoor exists.
- Accepted [ADR-001](adr/ADR-001-matching.md), [ADR-002](adr/ADR-002-concurrency.md)
  and [ADR-003](adr/ADR-003-event-processing.md) remain unchanged in #10B/#11. ADR-002's Phase B scope is historical. Single-mailbox
  contention, scans/sorting, volatile restart loss, single-owner/node limits,
  timeout uncertainty, and stale future ETS projections remain documented limits.
- Additional evaluation deliverables are incomplete: `README.md` now documents Ride creation, replay and volatile-state limits; full workflow documentation remains incomplete; `architecture.md` and `sequence-diagram.md` are empty. Ride/event
  correlated observability, the full scaling explanation, and runnable workflow
  documentation remain future work. The guide's target diagram/roadmap and
  Accepted ADRs do not complete these deliverables.
- The guide's historical scalar Ride example is not the actual API or TDD history.
  The implemented pure Ride State Machine accepts a map. Future lifecycle
  signatures remain provisional; creation/query and event-processing APIs are implemented.
