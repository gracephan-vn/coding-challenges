# Acceptance criterion traceability

Audit date: 2026-10-26. The authoritative [challenge specification](challenge-spec.md)
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

No complete AC is currently VERIFIED. `mix compile --warnings-as-errors` and
`mix test` passed during this audit: **82 tests passed**. Those results verify
the assertions in the existing suite, not absent workflows.

Test references (all executed by that full-suite run):

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
| AC-01 | Create/retrieve a unique REQUESTED ride; validate passenger and coordinates; require idempotency key, replay original result, reject changed payload | `Location.valid?/1` supplies reusable coordinate validation only. No Ride collection, passenger seeds, create/query commands, or `/rides` routes | Location; no Ride creation/retrieval/idempotency tests | PARTIAL | Implement passenger reference checks, Ride creation and retrieval, IDs, request validation, idempotency, and HTTP integration |
| AC-02 | Availability API; only AVAILABLE gets offers; OFFERED/BUSY transitions and release rules; reject other transitions | `Drivers.StateMachine.transition/2`; `Store.set_driver_availability/3`; StateServer atomic callback; `PUT /drivers/:id/availability`; Matcher filters available drivers | Driver state, Store, Driver HTTP, Matcher. Real OFFLINE/AVAILABLE HTTP updates and repeated requests pass. Offered/busy rejection uses callback fixtures; HTTP 409 uses a response-only protocol fixture | PARTIAL | Integrate real offer/accept/reject/cancel/complete workflows and test unavailable drivers through those workflows; no live offered/busy HTTP scenario yet |
| AC-03 | Update valid driver coordinates, reject invalid ones, store latest location, and match using latest location | `Location.valid?/1`; `Store.update_driver_location/3`; StateServer atomic callback; `PUT /drivers/:id/location` | Location, Store, Driver HTTP verify updates, boundaries, rejected-input state preservation, and stored results. Matcher uses coordinates supplied to it | PARTIAL | Connect matching to authoritative current Driver records and test HTTP/Store location updates changing the selected driver |
| AC-04 | When a ride is created, match nearest available driver within default/configurable 2 km radius; exclude outside radius; order by distance and break equal-distance ties by lexicographic ID; handle none | `Location.distance_km/2`; pure `Dispatch.Matcher.nearest/3` with `radius_km: 2.0`, minimum `{distance, id}`, and `:none` | Location and Matcher cover Haversine, eligibility, radius boundary/just outside, custom radius, reversed-input exact ties, empty/all-ineligible candidates, and invalid coordinates | PARTIAL | Ride-triggered dispatch, authoritative latest-state integration, and end-to-end matching evidence. Pure candidate selection does not reserve a driver |
| AC-05 | Pending offer records, current-driver accept/reject, coordinated Ride/Driver updates, permanent per-ride rejection exclusion, configurable 30s timeout, rematch/cancel/complete | Driver state actions model Driver-side transitions; Matcher accepts caller-supplied excluded IDs. No RideOffer records, current-offer checks, timeout scheduler, or lifecycle endpoints | Driver state and Matcher cover supporting state rules/exclusion filtering only | PARTIAL | Implement and test atomic offer lifecycle, identity/deadline checks, timeouts, exclusion persistence, rematching, cancellation, and completion |
| AC-06 | Explicit Ride lifecycle; valid/invalid/duplicate transitions; persisted assignment cleanup on reject/timeout; terminal CANCELLED/COMPLETED states and driver release | Pure `Rides.StateMachine.transition(ride_map, action)` returns `{:ok, updated_ride}`, `{:error, :invalid_transition}`, or `{:error, :invalid_state}`. Implements matching start, offer creation/acceptance/rejection/timeout, completion, and cancellation from all four active states; only `:status` changes. No Ride storage | [Ride state tests](../test/ride_dispatch/rides/state_machine_test.exs): 15 passed; full suite: 97 passed after Feature #8. Cover valid/invalid transitions, terminals, field preservation, deterministic results, and malformed states. Design choice: repeating an applied action is rejected when its source state no longer applies; no command-history deduplication | PARTIAL | Atomic Store integration must persist transitions, clear `assignedDriverId` on rejection/timeout, release Drivers, validate current offers/deadlines/ownership, and safely handle stale duplicate commands. Pure transition tests do not verify these multi-entity or end-to-end requirements |
| AC-07 | After rejection, rematch another eligible driver; exclusion is permanent for that ride, local to that ride; no candidates leaves MATCHING/nil | Pure Matcher accepts `excluded_driver_ids`; exclusions apply only to that call; Matcher stores no Ride history | Matcher tests rejected/timed-out IDs, repeated selection attempts with supplied exclusions, other-ride eligibility, and no candidates | PARTIAL | Persist exclusions per Ride, trigger rematching, and verify real Ride remains MATCHING with no assignment when exhausted |
| AC-08 | Duplicate-safe Ride creation with key, driver acceptance, and Ride transitions; documented strategy | No Ride idempotency records or required commands. Repeated availability succeeds unchanged but is outside these required duplicate scenarios | No required AC-08 tests; repeated availability tests do not establish AC-08 | NOT IMPLEMENTED | Implement atomic idempotency records and duplicate-safe acceptance/transitions; test replay and key/payload conflicts |
| AC-09 | Identify race; prevent one driver holding two offers/accepted rides; two distinct rides compete in a real concurrency test; document strategy | Store/StateServer single-owner foundation and Accepted ADR-002; no reservation or Ride/Offer collections | Store uses barrier-released competing Driver location/availability callers; no two-Ride assignment test | NOT IMPLEMENTED | Atomic multi-entity reservation and real two-Ride competing-process test. Existing concurrent updates do not prove reservation safety |
| AC-10 | RideCreated → asynchronous dispatch event → matching; explain async choice, duplicate delivery, processing failure | Phoenix.PubSub is supervised infrastructure only; no RideCreated producer, event queue, or dispatch consumer | No event-driven dispatch tests | NOT IMPLEMENTED | Implement asynchronous dispatch and duplicate/failure handling, with tests and README explanations |

## Evidence boundaries and documentation gaps

- Driver HTTP tests use raw JSON through the Endpoint parser. Malformed JSON
  syntax is checked with `assert_error_sent`; parsed invalid fields are checked
  separately. Conflicts are response-mapping evidence from a protocol fixture,
  not a real offered/busy lifecycle scenario.
- Production has one named StateServer, initially empty. Tests inject isolated
  supervised PIDs through trusted `conn.private[:dispatch_store]`; no global
  application-environment mutation or per-request StateServer is used. Seeds
  accept only offline/available Drivers. No live-state test backdoor exists.
- Accepted [ADR-001](adr/ADR-001-matching.md) and [ADR-002](adr/ADR-002-concurrency.md)
  remain unchanged. ADR-002's Phase B scope is historical. Single-mailbox
  contention, scans/sorting, volatile restart loss, single-owner/node limits,
  timeout uncertainty, and stale future ETS projections remain documented limits.
- Additional evaluation deliverables are incomplete: `README.md` is Phoenix
  boilerplate; `architecture.md` and `sequence-diagram.md` are empty. Ride/event
  correlated observability, the full scaling explanation, and runnable workflow
  documentation remain future work. The guide's target diagram/roadmap and
  Accepted ADRs do not complete these deliverables.
- The guide's historical Ride State Machine example is not an existing module
  or a record of the first actual TDD cycle. Future Store/Ride/Event signatures
  are provisional, not current public APIs.
