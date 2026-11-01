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
| AC-01 | Create/retrieve a unique REQUESTED ride; validate passenger and coordinates; require idempotency key, replay original result, reject changed payload | `Rides.create_ride/3`, `Rides.get_ride/2`, `Rides.Request.normalize/1`, `Store.create_ride/3`, `Store.get_ride/2`; atomic StateServer callback; seeded P001; `POST /rides`, `GET /rides/:rideId` | Request tests (3), Ride Store tests (7), Ride HTTP tests (9): coordinates/boundaries, strict fields, passenger validation, unique IDs, retrieval, 201 replay, conflicts and competing duplicates; Feature #9 checkpoint full suite 116 passed (later historical checkpoints below) | VERIFIED | Creation contract verified; Feature #10A HTTP test also verifies original POST replay after the real asynchronous MATCHING transition |
| AC-02 | Availability API, OFFERED/BUSY rules, coordinated rejection/cancellation/completion release; reject all other transitions | Driver State Machine; Store availability/reservation/acceptance/rejection/expiration/cancel/complete; Driver and Ride HTTP routes | Existing state/Driver HTTP suites plus live pending/accepted cancellation, completion, Driver reuse and ten terminal race groups; full suite 310 passed | VERIFIED | Specified clauses supported; availability API is distinct from internal lifecycle actions. No caller authentication or durability claim |
| AC-03 | Update valid coordinates, reject invalid ones, store and match using latest location | Location, Store.update_driver_location/3, PUT /drivers/:id/location; StateServer passes current Driver records to Matcher | Location/Store/Driver HTTP tests plus reservation latest-location test and Ride HTTP integration prove an update changes selected Driver | VERIFIED | No remaining specified clause; stale-update timestamp detection is not implemented or required |
| AC-04 | Ride-triggered nearest AVAILABLE matching; default/configurable 2 km radius; distance ordering, outside/none/ties; valid coordinates | Location.distance_km/2, Matcher.nearest/3 (minimum `{distance, id}` ordering), Store.process_event/2; authoritative DispatchRequested handler | Pure Matcher/Haversine tests plus reservation default/custom/exact-boundary/just-outside/tie/no-candidate checks and actual asynchronous Ride creation → reservation | VERIFIED | No remaining specified clause; scans approximate spherical distance and no performance claim is made |
| AC-05 | Current-holder pending Offer, acceptance/rejection, permanent Ride exclusion, configurable 30s timeout and another-driver attempt; example terminal APIs | Atomic reservation/acceptance/rejection/expiration; ExpirationScheduler; cancel_ride/2 and complete_ride/2; all specified example routes | Existing Offer/rematching/timeout suites plus terminal Store/HTTP closure, immutable acceptance evidence, reuse and stale-timer tests; clause matrix below | VERIFIED | Offer closure and terminal routes now have live evidence. Path Driver identity is not caller authentication |
| AC-06 | Explicit valid/invalid/duplicate lifecycle; persisted transitions and assignment cleanup; timeout release; terminal states | Existing pure state machine and atomic Store commands through terminal completion/cancellation; pointers cleared and terminal receipts retained | Pure transition matrix; live Store/HTTP terminal transitions/replay, event/timer safety, Driver reuse, ordered and competing races | VERIFIED | Specified lifecycle complete within volatile single-owner storage; independent submission audit remains separate |
| AC-07 | Rejection causes rematching; permanent same-Ride exclusions; other-Ride eligibility; no candidate stays MATCHING/nil | Rejection and expiration retain Offer history, release Driver, clear Ride and enqueue distinct Offer-derived DispatchRequested events; existing Matcher/dispatcher reused | Existing rejection exhaustion plus real expiration A → B, latest eligibility changes, no-candidate result and A reused by another Ride; stale O001 work preserves O002 and both BUSY Drivers | VERIFIED | Rejection/rematching clauses remain verified; timeout-triggered rematching now has live integration evidence. No continuous location/availability search loop |
| AC-08 | Keyed creation, Driver acceptance and Ride transition idempotency; documented strategy | Existing receipts plus immutable Ride terminal_receipt; original domain snapshots and cross-record proof | Existing idempotency regressions; terminal replay after Driver reuse, competing duplicates, preserved creation/acceptance/rejection/expiration results, malformed proof rejection | VERIFIED | Terminal idempotency now has live evidence; same surviving authoritative state required, no crash-durable guarantee |
| AC-09 | Prevent simultaneous Offers/accepted Rides for one Driver; prove two competing Rides and document strategy | Single StateServer atomic reservation and lifecycle release; validated historical closure and current ownership | Existing competing two-Ride suites plus terminal race groups, release-versus-reservation, no double release, old command replay after R002 accepted, final-state assertions | VERIFIED | Arbitrary redispatch of an acknowledged losing Ride remains absent; terminal release never reopens it automatically. Single-node guarantee |
| AC-10 | Ride Created → asynchronous dispatch → Driver matching; explain async, duplicate delivery and failure | Existing EventDispatcher/ExpirationScheduler and Store atomic event commands; terminal proof before stale-work acknowledgement | Existing async/recovery suites plus real dispatcher pending creation/dispatch/backoff after cancellation, scheduler old-work safety, unchanged event accounting | VERIFIED | No durable delivery or hard real-time SLA. Terminal commands retain events; no new event pipeline or terminal redispatch |

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

Historical checkpoint (before Feature #14). Executed **37 focused tests** and full `mix test`: **267 passed**. Compilation
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

## Feature #14 verification

Executed **42 focused tests** and full `mix test`: **310 passed**. Compilation
with warnings as errors, formatting and diff checks passed. Historical counts
above describe their original checkpoints; their suites also pass in this full run.

- [Terminal Store](../test/ride_dispatch/dispatch/terminal_lifecycle_test.exs): **16 tests** —
  four cancellation sources, accepted completion, exact receipts, immutable Offer
  history, original-result replay, discarded-response retry and live Driver reuse. Labeled callback corruption
  cases cover wrong Ride/Driver/Offer identities, unsupported source, false closure,
  conflicting acceptance evidence, original-result corruption, foreign references,
  contradictory reused ownership and malformed retained rejection history.
- [Concurrency](../test/ride_dispatch/dispatch/terminal_concurrency_test.exs): **10 tests** —
  each runs both deterministic orders and barrier-released callers, three times:
  Cancel/Accept, Cancel/Reject, Cancel/Expire, Cancel/Dispatch, Cancel/Cancel,
  Complete/Complete, Complete/Cancel, Complete/Accept, Complete/Expire and
  Complete/reservation for R002. Final Ride/Driver/Offer/Event records are asserted.
- [Worker integration](../test/ride_dispatch/dispatch/terminal_dispatch_test.exs): **5 tests** —
  real dispatcher boundaries for pending RideCreated, DispatchRequested and backoff;
  cancellation preserves terminal state and safe attempt accounting. A real scheduler
  receives obsolete timer work after Driver reuse. Corrupt terminal event/discovery
  evidence is explicitly callback-level; valid workflows use real isolated owners.
- [HTTP](../test/ride_dispatch_web/controllers/ride_lifecycle_test.exs): **11 tests** —
  all cancellation source states; completion → live Driver reuse → replay/old
  acceptance/expiration; current GET/original POST replay; no body/JSON `{}`;
  unsupported/non-object/unparsed/malformed JSON; conflict/not-found/invariant
  envelopes and inability of external query parameters to select a test owner.

### AC-02 / AC-05 / AC-06 clause reconciliation

The clause identifiers below follow specification order. Status applies to the
required behavior, not to unrelated submission deliverables or authentication.

| AC / clause | Implementation and executed evidence | Result |
|---|---|---|
| 02.1 OFFLINE ↔ AVAILABLE via API | Driver HTTP availability test; Store availability and pure transitions | VERIFIED |
| 02.2 Only AVAILABLE receives Offer | Matcher/reservation tests, real OFFERED/BUSY exclusion and terminal reuse races | VERIFIED |
| 02.3 Offer → OFFERED; acceptance → BUSY | Reservation/acceptance Store, HTTP and dispatcher suites | VERIFIED |
| 02.4 Rejection or pending cancellation → AVAILABLE | Rejection/rematching suites; pending cancellation Store/HTTP and Cancel/Reject race | VERIFIED |
| 02.5 Accepted completion → AVAILABLE | Live completion Store/HTTP then A reserved and accepted on R002 | VERIFIED |
| 02.6 OFFERED/BUSY cannot receive another Offer or go OFFLINE | Driver state matrix, real reservation/acceptance HTTP conflicts, competing assignments and terminal races | VERIFIED |
| 02.7 Other transitions rejected | Driver action/source matrix and unsupported-action tests; Store guards | VERIFIED |
| 05.1 Pending Offer sets Ride DRIVER_ASSIGNED, assignedDriverId and Driver OFFERED | Reservation/dispatcher and Ride HTTP suites | VERIFIED |
| 05.2 Only exact current offered Driver accepts/rejects | Acceptance/rejection ownership, wrong-holder, stale and ambiguity tests | VERIFIED |
| 05.3 Acceptance → DRIVER_ACCEPTED/BUSY | Live acceptance and HTTP suites; immutable receipt | VERIFIED |
| 05.4 Rejection → MATCHING/nil/AVAILABLE | Live rejection, HTTP and async rematching suites | VERIFIED |
| 05.5 Permanent same-Ride rejection exclusion, other-Ride eligibility | Rejection exhaustion/scoped history, Driver reuse and existing Matcher tests | VERIFIED |
| 05.6 Configurable timeout default 30s; expiration releases and rematches | Policy tests, 37 expiration tests, actual supervised scheduler and EventDispatcher rematching | VERIFIED |
| 05.7 Rejection attempts another eligible Driver | Real A → B dispatcher rematching, dynamic eligibility and no-candidate tests | VERIFIED |
| 05 example terminal routes and pending/accepted release paragraph | Both POST routes, four cancellation source states and accepted completion via Store/HTTP | VERIFIED |
| 06.1 Valid transitions succeed | Pure Ride matrix plus all legitimate stored lifecycle transitions and HTTP terminal routes | VERIFIED |
| 06.2 Invalid transitions rejected | Pure matrix, Store guards, HTTP conflicts and opposite-terminal operations | VERIFIED |
| 06.3 Duplicates safely handled | Pure duplicate rejection and receipt-proven Store replay; competing terminal duplicates | VERIFIED |
| 06.4 Persist transitions and clear assignment on rejection | Existing live rejection; terminal Store/HTTP reads; nil assignment/current Offer after close | VERIFIED |
| 06.5 Timeout matches rejection transition and release | Expiration Store/scheduler/rematching and delayed-scheduler ownership tests | VERIFIED |
| 06.6 CANCELLED/COMPLETED terminal; Driver available after each | Atomic releases, real reuse, pending event/timer safety, terminal race final-state assertions | VERIFIED |

Terminal Offers use CANCELLED/COMPLETED without erasing successful acceptance
fields. Ride-bound receipts record exact source identities and original result;
status/shape alone never proves closure. Historical Driver availability is not
required, but its new ownership must be consistent. Original creation, acceptance,
rejection and expiration replay remain covered through terminal progression.
Terminal commands create no Offer or event and preserve existing event history.
Valid stale events are processed as `incompatible_ride_state`; invalid proof fails
permanently. Expiration ignores only proven terminal closure. No new infrastructure,
production fixture mutation API or Accepted ADR/specification change was introduced.

All AC-01 through AC-10 rows are VERIFIED against the specified behaviors and
executed evidence. This does not claim final submission readiness: the independent
submission audit, remaining evaluation documentation and non-AC deliverables are
separate. Volatile state, retained-history growth, single-owner/node guarantees,
no caller authentication and lack of crash durability remain explicit limitations.

## Evidence boundaries and documentation gaps

- Driver HTTP tests use raw JSON through the Endpoint parser. Malformed JSON
  syntax is checked with `assert_error_sent`; parsed invalid fields are checked
  separately. Original conflict mapping uses a protocol fixture; Feature #10B also verifies
  real OFFERED HTTP conflicts after reservation and Feature #11 verifies real BUSY
  conflicts after acceptance. Ambiguity/invariant response mapping also uses
  an explicitly labeled response-only protocol fixture, with real validation in
  StateServer callback tests. Feature #12 proves stale acceptance HTTP 409 through
  live rejection → rematching → replacement acceptance.
- Feature #14 adds live terminal workflows; only deliberately malformed history and selected callback compatibility checks remain synthetic.
- Production has one named StateServer, with seeded Passenger P001 and initially empty Drivers/Rides/events. Tests inject isolated
  supervised PIDs through trusted `conn.private[:dispatch_store]`; no global
  application-environment mutation or per-request StateServer is used. Seeds
  accept only offline/available Drivers. No live-state test backdoor exists.
- Accepted [ADR-001](adr/ADR-001-matching.md), [ADR-002](adr/ADR-002-concurrency.md)
  and [ADR-003](adr/ADR-003-event-processing.md) remain unchanged in #10B/#11/#12/#13. ADR-002's Phase B scope is historical. Single-mailbox
  contention, scans/sorting, volatile restart loss, single-owner/node limits,
  timeout uncertainty, and stale future ETS projections remain documented limits.
- R2 supplies local provisioning and lifecycle observability with an executable
  external HTTP demo. R3 adds the architecture/component view, six sequences,
  scaling analysis and reviewer Quick Start; these documentation deliverables do
  not add business behavior or independently re-audit the AC labels.
- The guide's historical scalar Ride example is not the actual API or TDD history.
  The implemented pure Ride State Machine accepts a map. Lifecycle Store/HTTP
  APIs are implemented through Feature #14; historical proposed signatures are
  not a substitute for current source contracts.

## Submission remediation R2 — demo and correlated observability

No business AC row is promoted or redefined. Previously recorded test counts
remain historical. R2 verification: **321 full-suite tests**, **10 focused tests**
(`demo_test.exs`: 2; `lifecycle_logging_test.exs`: 8), compilation with warnings as
errors, format check and whitespace check passed.

- **F3:** explicit development-only `RIDE_DISPATCH_DEMO=true` runtime configuration;
  default production/test Driver seeds stay empty. P001 and deterministic AVAILABLE
  D001/D002/D003 pass existing seed validation. Pure Matcher and isolated Store
  tests prove ordering, radius exclusion and reset. An **external HTTP listener**
  additionally completed create → D001 reject → D002 accept → complete, and repeated
  successfully after full restart. Old Ride lookup returned 404 before the second run.
- **F2:** post-installation StateServer continuation emits semantic logs with explicit
  Ride/Driver/Offer/Event identity; creation is not processing, replay is not another
  transition, and no-candidate is not technical failure. Captured external logs link
  RideCreated to dispatch, reservation, rejection/redispatch, acceptance and completion.
  Read-only Store queries confirmed final receipts, Driver release and three processed
  events. Network duplicates replayed; stale acceptance returned 409 and logged a conflict.
- **Evidence boundaries:** retry/fault/timeout cases use real isolated workers with
  existing controlled injection; corruption protection is explicitly synthetic.
  Semantic metadata assertions and authoritative final-state checks complement the
  external demo; no fault injection was exposed through HTTP. Scheduler diagnostics
  retain suppression. Logging tests run serialized and restore Logger configuration.
- Logs are best effort, not durable/exactly-once; crash windows, single-owner/node
  limits, volatile state, history growth and no caller authentication remain.
  R2 changes no specification, Accepted ADR, state machine or dependency lockfile.

## Submission remediation R3 — documentation verification

Documentation-only remediation at baseline `c7155123fe13bb72a5f94b37883b7ba2e2cbcc05`.
No business AC status is promoted or re-audited; source, tests, configuration,
lockfile, specification and Accepted ADRs remain unchanged.

- F1: [architecture](architecture.md) documents actual module/process boundaries,
  one-owner state, atomic commands, receipts, supervision, recovery and logging;
  [six sequences](sequence-diagram.md) show creation/matching, acceptance,
  rejection/rematching, expiration/rematching, terminal closure and competing Rides.
- F6: architecture analysis distinguishes current scan/validation costs from
  proposed 100k read/index/retention optimizations and 1m distributed coordination.
  It identifies authoritative Driver reservation, transaction/outbox boundaries,
  stale-projection handling and retry/recovery costs; no benchmarks are claimed.
- F7: README Quick Start, actual runtime requirements, API table, troubleshooting
  and links replace generator boilerplate. The complete R2 demo section is retained
  byte-for-byte. Narrow guide corrections remove empty-document claims, nonexistent
  context paths and implied command correlation fields, preserving historical counts.
- R3 execution (2026-10-29): `mix deps.get` succeeded without lockfile changes;
  `mix test` **321 passed**; compile warnings-as-errors, format check and
  `git diff --check` passed. Elixir **1.20.4**, OTP **29.1.2**. This used the existing
  development checkout, **not a fresh isolated checkout** or compatibility matrix.
- Markdown parsed and relative links/anchors checked. The architecture diagram,
  six sequence diagrams and corrected existing guide overview parsed/rendered with
  Mermaid CLI **12.0.0** and installed Chrome; visual previews were reviewed.
  Tooling/build images stayed in `/tmp`, with no project dependency added.
- The README Python block ran against a real Phoenix listener on port 4000:
  create 201 → D001 assignment → reject 200 → D002 assignment → accept 200 →
  complete 200; D002 AVAILABLE via the existing availability command. Stale D001
  acceptance returned 409; duplicate completion and creation replayed original
  results. Captured logs linked `ride-1`, `event-1`, `dispatch-ride-1`, `offer-2`,
  `redispatch-offer-2`, `offer-3` and D001/D002, with one completion success and
  separate replay records. This is external HTTP evidence, not synthetic state.
- **Remaining security finding:** `mix hex.audit` exited **1**, reporting locked
  Bandit **1.14.0**, HIGH **EEF-CVE-2026-116078 / GHSA-pxjf-g536-7r93**.
  The [maintainer advisory](https://github.com/mtrudel/bandit/security/advisories/GHSA-pxjf-g536-7r93)
  (published 2026-10-28) covers versions `>= 0.3.1, < 1.14.1`, patched in **1.14.1**:
  HTTP/2 body-frame memory amplification. Dependency remediation is outside R3;
  the lockfile is preserved. No other advisory was reported by this invocation.

R3 documentation completion is not overall submission readiness. The new security
finding needs a separately authorized dependency correction and regression check.

**Subsequent R3.1 closure (2026-11-01):** commit `ebb4b94` upgraded Bandit from
1.14.0 to **1.14.1**. The previously verified post-remediation `mix hex.audit`
completed successfully. The historical R3 finding above is therefore **closed**;
its original result remains preserved as evidence of the earlier lockfile.
That audit result applies to the advisory data available at verification time,
not a guarantee against future vulnerabilities.
