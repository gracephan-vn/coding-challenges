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
| AC-02 | Availability API, OFFERED/BUSY rules and coordinated lifecycle release | Driver State Machine, Store availability/reservation/acceptance/rejection/expiration commands and existing HTTP routes | Real OFFERED → AVAILABLE on rejection/expiration; overdue reservation remains exclusive until a valid close; accepted BUSY ownership survives stale expiration; released Driver reuse/competition | PARTIAL | Implement cancel/complete coordinated release; pure transitions do not complete those workflows |
| AC-03 | Update valid coordinates, reject invalid ones, store and match using latest location | Location, Store.update_driver_location/3, PUT /drivers/:id/location; StateServer passes current Driver records to Matcher | Location/Store/Driver HTTP tests plus reservation latest-location test and Ride HTTP integration prove an update changes selected Driver | VERIFIED | No remaining specified clause; stale-update timestamp detection is not implemented or required |
| AC-04 | Ride-triggered nearest AVAILABLE matching; default/configurable 2 km radius; distance ordering, outside/none/ties; valid coordinates | Location.distance_km/2, Matcher.nearest/3 (minimum `{distance, id}` ordering), Store.process_event/2; authoritative DispatchRequested handler | Pure Matcher/Haversine tests plus reservation default/custom/exact-boundary/just-outside/tie/no-candidate checks and actual asynchronous Ride creation → reservation | VERIFIED | No remaining specified clause; scans approximate spherical distance and no performance claim is made |
| AC-05 | Pending/current-holder Offer lifecycle, coordinated acceptance/rejection, permanent Ride-scoped exclusions, timeout and rematching/release | Atomic reservation/acceptance/rejection; Store.expire_offer/2, Store.expiration_schedule/1 and supervised ExpirationScheduler; exact currentOfferId and retained receipts | Existing acceptance/rejection tests plus Feature #13's 37 tests: exact expiration identity, early/equal/late deadlines, immutable proof, scheduler discovery/restart, delayed execution and actual asynchronous replacement | PARTIAL | Cancellation/completion and their live terminal lifecycle evidence remain absent; automatic expiration is implemented and tested |
| AC-06 | Explicit Ride lifecycle, invalid/duplicate handling, terminal states and coordinated release/assignment cleanup | Pure Ride State Machine; stored REQUESTED → MATCHING → DRIVER_ASSIGNED → DRIVER_ACCEPTED; rejection/expiration atomically return MATCHING and clear both assignment pointers | Existing state/lifecycle tests plus expiration Store/concurrency/rematching tests; terminal compatibility and corruption cases remain labeled synthetic callbacks | PARTIAL | Persist cancel/complete workflows and prove terminal release/races through legitimate integration |
| AC-07 | Rejection causes rematching; permanent same-Ride exclusions; other-Ride eligibility; no candidate stays MATCHING/nil | Rejection and expiration retain Offer history, release Driver, clear Ride and enqueue distinct Offer-derived DispatchRequested events; existing Matcher/dispatcher reused | Existing rejection exhaustion plus real expiration A → B, latest eligibility changes, no-candidate result and A reused by another Ride; stale O001 work preserves O002 and both BUSY Drivers | VERIFIED | Rejection/rematching clauses remain verified; timeout-triggered rematching now has live integration evidence. No continuous location/availability search loop |
| AC-08 | Demonstrate idempotency for keyed Ride creation, Driver acceptance and Ride state transition; document strategy | Existing creation/acceptance/rejection evidence plus immutable expiration_receipt and linked redispatch event | Full existing regressions; competing expiration calls create one receipt/event; replay after replacement acceptance/Driver reuse; real queued Store timeout and controlled scheduler timeout rechecks; corrupted proofs rejected | VERIFIED | Specified minimum behaviors and rejection/expiration extensions verified; cancel/complete commands still need idempotency tests. No crash-durable guarantee |
| AC-09 | Identify race, prevent simultaneous offers/accepted Rides for one Driver, test two different competing Rides and document strategy | Single authoritative callback coordinates reservation/acceptance/rejection/expiration; status alone never releases an overdue reservation | Existing two-Ride reservation/acceptance/released-Driver races; ordered and barrier-released Expire/Accept, Expire/Reject and Expire/Expire; delayed scheduler proves another Ride cannot take overdue A; final records asserted | VERIFIED | Implemented assignment/close safety remains verified. Arbitrary redispatch of an already-acknowledged losing Ride is still not a public workflow; cancel/complete races remain future work |
| AC-10 | Ride Created → asynchronous dispatch event → Driver matching; README explains async choice, duplicate delivery and failure | One EventDispatcher and one nonauthoritative ExpirationScheduler; expiration atomically creates redispatch-expired-{offerId}; existing event processing/retry framework reused | Existing event suites plus actual scheduled expiration → asynchronous replacement, missed hints, both workers' restart windows, one-for-one owner replacement, no-candidate versus technical retry and duplicate safety | VERIFIED | Specified async flow and expiration/rematching regressions verified; no durable delivery, hard real-time SLA or external-side-effect transaction claim. Remaining lifecycle under AC-05/06 |

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

## Feature #12 verification (historical)

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

## Feature #13 verification

Executed **37 focused tests** and full `mix test`: **267 passed**. Compilation
with warnings as errors, formatting and diff checks passed. Focused evidence:

- [Expiration Store](../test/ride_dispatch/dispatch/expiration_test.exs): **12 tests** —
  identity, deadline equality/negative time, atomic release/event, receipt replay,
  closed evidence, scheduling diagnostics and labeled corruption/terminal fixtures.
- [Scheduler](../test/ride_dispatch/dispatch/expiration_scheduler_test.exs): **8 tests** —
  startup, actual deadline timer, hints/scans, configuration, restart before/after
  commit and owner replacement using application child specifications.
- [Diagnostics](../test/ride_dispatch/dispatch/expiration_diagnostics_test.exs): **4 tests** —
  synthetic callback owners cover malformed-record isolation, bounded logging and
  fingerprint/reminder reconsideration; global-clock recovery uses a real owner.
- [Failures](../test/ride_dispatch/dispatch/expiration_failure_test.exs): **4 tests** —
  local backoff/cooldown, early rescheduling, uncertain-outcome reconciliation and
  an actual queued Store timeout proving processing-time clock reads.
- [Concurrency](../test/ride_dispatch/dispatch/expiration_concurrency_test.exs): **3 tests** —
  ordered and barrier-released Accept/Reject/Expire calls, final-state assertions
  and exactly one immutable expiration receipt/event under competing duplicates.
- [Rematching](../test/ride_dispatch/dispatch/expiration_rematching_test.exs): **6 tests** —
  delayed scheduler plus real late HTTP Accept, continued reservation exclusivity,
  actual A → B replacement, A reuse elsewhere, current eligibility, no-candidate,
  technical retry, dispatcher restart and labeled malformed-history callbacks.

`Store.expire_offer/2` commits the EXPIRED Offer, AVAILABLE Driver, MATCHING Ride
with nil assignment/current Offer, immutable receipt and exactly one
`redispatch-expired-{offerId}` event together. Isolated atomic assertions observe
PENDING; live observations may see the event already PROCESSED. Linked FAILED
events still support proven expiration replay without another event.

The application retains `:one_for_one` and permanent workers. Actual supervised
replacement tests verify StateServer changes PID while EventDispatcher and
ExpirationScheduler survive; old-owner work remains pinned to the old PID, and
local timer/retry/diagnostic state is cleared before rediscovery. Lost owner state
is not restored. Scheduler/dispatcher restart tests keep the owner alive.

Malformed-record and terminal tests use explicit synthetic snapshots/callback
owners, never a production mutation API. Scheduler timeout branches use controlled
signals around real Store outcomes; the separate Store timeout is elapsed and real.
Bounded diagnostic suppression is not corruption repair. Transient expiration
failures use 1s/2s backoff then a reminder-interval cooldown before another bounded
round; subsequent redispatch uses the unchanged EventDispatcher retry semantics.
No arbitrary sleeps prove correctness. Cancellation/completion remain absent;
AC-02/05/06 remain PARTIAL. AC-07/08/09/10 retain VERIFIED after these regressions.
The authoritative specification and Accepted ADR decisions are unchanged.

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
  and [ADR-003](adr/ADR-003-event-processing.md) remain unchanged in #10B/#11/#12/#13. ADR-002's Phase B scope is historical. Single-mailbox
  contention, scans/sorting, volatile restart loss, single-owner/node limits,
  timeout uncertainty, and stale future ETS projections remain documented limits.
- Additional evaluation deliverables are incomplete: `README.md` now documents Ride creation, replay and volatile-state limits; full workflow documentation remains incomplete; `architecture.md` and `sequence-diagram.md` are empty. Ride/event
  correlated observability, the full scaling explanation, and runnable workflow
  documentation remain future work. The guide's target diagram/roadmap and
  Accepted ADRs do not complete these deliverables.
- The guide's historical scalar Ride example is not the actual API or TDD history.
  The implemented pure Ride State Machine accepts a map. Future lifecycle
  signatures remain provisional; creation/query and event-processing APIs are implemented.
