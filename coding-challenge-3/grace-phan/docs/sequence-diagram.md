# Lifecycle sequences

These six views describe the **implemented single-VM application**, not a proposed
distributed deployment. Participants abbreviated below resolve to
`RideDispatchWeb.RideController`, `RideDispatch.Rides` and
`RideDispatch.Dispatch.{Store, StateServer, EventDispatcher, ExpirationScheduler, Matcher}`.
Controller → Rides delegation is folded into HTTP for readability. Store and
Matcher are modules; StateServer and the two workers are OTP processes.

`->>` denotes a request/local call, `-->>` its result, and `-)` a nonauthoritative
asynchronous hint. Only Client ↔ HTTP is network traffic. **INSTALL** marks the
complete authoritative state returned from a StateServer callback. No other
process observes partial Ride/Driver/Offer/Event mutation. Store requests hints
after replies; publication occurs in a separate StateServer notification callback.
Hints may be lost, so workers also discover work at startup and on recovery scans.
Post-installation Logger continuations are omitted: they are best-effort
observations, not a transactional audit store. See [architecture](architecture.md).

## 1. Create Ride, dispatch and atomic reservation

```mermaid
sequenceDiagram
    participant C as HTTP Client
    participant H as RideController / Rides
    participant S as Dispatch.Store
    participant O as Dispatch.StateServer
    participant W as Dispatch.EventDispatcher
    participant M as Dispatch.Matcher
    C->>H: POST /rides + Idempotency-Key + Ride body
    H->>S: create_ride(owner, key, body)
    S->>O: Create command
    alt New valid canonical request
        Note over O: INSTALL REQUESTED Ride + RideCreated PENDING + original<br/>result/key
        O-->>S: Original Ride result
    else Same key and canonical request
        O-->>S: Original creation result, no mutation
    else Invalid request or conflicting key
        O-->>S: Controlled error, no mutation
    end
    S-->>H: Command result
    H-->>C: 201 original result, or 400/409 error
    S-)O: Request notification after reply
    O-)W: events_available hint
    Note over W,O: Only committed pending work is actionable, response and<br/>worker timing may overlap
    W->>S: Discover actionable events, process_event(owner, RideCreated ID)
    S->>O: Process RideCreated
    Note over O: INSTALL Ride MATCHING + RideCreated PROCESSED +<br/>dispatch-RideID PENDING
    O-->>S: processed
    S-->>W: processed
    W->>S: Discover and process_event(owner, DispatchRequested ID)
    S->>O: Match and reserve command
    O->>M: nearest(pickup, latest Drivers, options)
    M-->>O: Candidate or :none (no_candidate outcome)
    alt Eligible candidate and consistent ownership
        Note over O: Validate ownership, read reservation clock, INSTALL Driver<br/>OFFERED + Ride DRIVER_ASSIGNED + PENDING Offer + event<br/>PROCESSED
    else No eligible candidate
        Note over O: INSTALL event PROCESSED/no_candidate, Ride stays<br/>MATCHING/unassigned
    else Inconsistent business state
        Note over O: Event fails permanently, no partial reservation
    end
    O-->>S: Processing result
    S-->>W: Processing result
```

Matcher options supply radius and Ride-scoped exclusions.
Creation returns REQUESTED even if a later GET already sees an assignment. With no
candidate, processing creates neither an Offer nor an immediate redispatch loop. A repeated
processed event returns `:already_processed` without business effects. Evidence:
[creation](../test/ride_dispatch/dispatch/ride_store_test.exs),
[reservation](../test/ride_dispatch/dispatch/reservation_test.exs) and
[real dispatcher](../test/ride_dispatch/dispatch/reservation_dispatcher_test.exs).
Technical failure/retry is separate from the successful no-candidate branch.

## 2. Offer acceptance and original-result replay

```mermaid
sequenceDiagram
    participant C as HTTP Client
    participant H as RideController / Rides
    participant S as Dispatch.Store
    participant O as Dispatch.StateServer
    C->>H: POST /rides/R/offers/D/accept (empty body)
    H->>S: accept_offer(owner, R, D)
    S->>O: Acceptance command
    Note over O: Resolve exact identities, reject ambiguous same-pair history<br/>or corrupt evidence
    alt Proven prior success for this Offer, Ride and Driver
        O-->>S: Immutable original accepted Ride, no mutation
    else Exact current PENDING Offer, Ride DRIVER_ASSIGNED, Driver OFFERED
        Note over O: Check exclusivity and trusted now less than expires_at_ms
        alt Valid ownership, evidence and deadline
            Note over O: INSTALL Offer ACCEPTED + immutable acceptance evidence +<br/>Ride DRIVER_ACCEPTED + Driver BUSY
            O-->>S: Accepted Ride
        else Deadline reached or legitimate stale/conflicting operation
            O-->>S: Conflict, no business mutation
        end
    else Missing relationship or corrupted authoritative records
        O-->>S: Not found or invariant error, no mutation
    end
    S-->>H: Result
    H-->>C: 200 success/replay, 404 missing, 409 conflict, 500 invariant error
```

Request-shape errors return 400 before business processing. Acceptance replay is
checked before a new-attempt deadline check; late retries can replay a genuine
success. Terminal progression and Driver reuse do not authorize restoring an old
snapshot. Evidence: [Store acceptance](../test/ride_dispatch/dispatch/acceptance_test.exs),
[HTTP acceptance](../test/ride_dispatch_web/controllers/offer_acceptance_test.exs)
and [live terminal reuse](../test/ride_dispatch/dispatch/terminal_lifecycle_test.exs).
Malformed-history fixtures are synthetic corruption tests, not user workflows.

## 3. Rejection and asynchronous rematching

```mermaid
sequenceDiagram
    participant C as Driver A HTTP Client
    participant H as RideController / Rides
    participant S as Dispatch.Store
    participant O as Dispatch.StateServer
    participant W as Dispatch.EventDispatcher
    participant M as Dispatch.Matcher
    C->>H: POST /rides/R/offers/A/reject
    H->>S: reject_offer(owner, R, A)
    S->>O: Reject exact current Offer
    alt First valid rejection, including overdue but still PENDING
        Note over O: Validate exact ownership, time and no contradictory evidence
        Note over O: INSTALL Offer REJECTED + receipt + A AVAILABLE + Ride<br/>MATCHING/cleared + redispatch-OfferID PENDING
        O-->>S: Original matching Ride result
    else Verified historical rejection replay
        O-->>S: Original matching result, no release or new event
    else Accepted, stale, ambiguous or corrupt
        O-->>S: Controlled conflict/invariant error, no mutation
    end
    S-->>H: Result
    H-->>C: 200 original result or sanitized error
    S-)O: Request notification
    O-)W: events_available hint
    W->>S: Discover and process new redispatch event
    S->>O: Atomic matching command
    O->>M: Latest candidates, exclude rejected/expired Drivers for R
    M-->>O: Nearest eligible B or no_candidate
    alt B still eligible with exclusive ownership
        Note over O: INSTALL new PENDING Offer + B OFFERED + Ride DRIVER_ASSIGNED<br/>+ event PROCESSED
    else No eligible Driver
        Note over O: INSTALL event PROCESSED/no_candidate, Ride remains MATCHING
    end
    O-->>S: Processing result
    S-->>W: Result
```

A is available to **other** Rides. B can move or become unavailable before
processing; only the current authoritative candidates count. Replay never rejects
B's replacement Offer. The replacement event may already be PROCESSED when the
client reads it. Evidence: [rejection/receipt/races](../test/ride_dispatch/dispatch/rejection_test.exs),
[real rematching](../test/ride_dispatch/dispatch/rematching_test.exs) and the
[external demo](../README.md#local-opt-in-demo-and-lifecycle-logs-r2).

## 4. Expiration and rematching

```mermaid
sequenceDiagram
    participant T as Dispatch.ExpirationScheduler
    participant S as Dispatch.Store
    participant O as Dispatch.StateServer
    participant W as Dispatch.EventDispatcher
    participant M as Dispatch.Matcher
    T->>S: expiration_schedule(observed owner PID)
    S->>O: Read pending identities/deadlines and diagnostics
    O-->>S: Trusted now, pending Offers, malformed-record diagnostics
    S-->>T: Schedule snapshot
    Note over T: Next-deadline timer plus recovery scan, owner identity and<br/>timer generation tracked
    T-)T: Wake-up (may be early, late or obsolete)
    T->>S: expire_offer(observed owner PID, exact Offer ID)
    S->>O: Validate Offer and authoritative processing time
    alt Current valid PENDING Offer, now at or beyond deadline
        Note over O: INSTALL EXPIRED Offer + receipt + Driver AVAILABLE + Ride<br/>MATCHING/cleared + redispatch-expired-OfferID PENDING
        O-->>S: ok, expired
    else Before deadline
        O-->>S: error, not_due with deadline, unchanged
    else Verified expired duplicate or valid closed historical Offer
        O-->>S: already_expired or ignored, unchanged
    else Missing Offer or corrupt identity/history
        O-->>S: not_found or controlled invariant error, unchanged
    end
    S-->>T: Result, reconcile uncertain timeouts, back off technical failures
    Note over T: Reschedule early work, bound diagnostics, never interpret<br/>timer as a release
    S-)O: Request notification after successful close
    O-)W: events_available hint
    W->>S: Discover and process expiration-derived redispatch
    S->>O: Match and reserve
    O->>M: Current candidates, exclude expired Driver for this Ride
    M-->>O: Candidate or no_candidate
    Note over O: INSTALL replacement reservation or no_candidate<br/>acknowledgement atomically
    O-->>S: Processing result
    S-->>W: Result
```

The last redispatch path exists only after a successful expiration. An expired
clock deadline alone leaves the old Driver OFFERED; first acceptance at equality
fails, explicit rejection can still win. Old-owner timer work is invalidated on
owner replacement, and no lost state is recreated. Evidence:
[scheduler restart/owner replacement](../test/ride_dispatch/dispatch/expiration_scheduler_test.exs),
[delayed scheduler and rematching](../test/ride_dispatch/dispatch/expiration_rematching_test.exs),
[failures](../test/ride_dispatch/dispatch/expiration_failure_test.exs) and
[corrupt-record isolation](../test/ride_dispatch/dispatch/expiration_diagnostics_test.exs).

## 5. Cancellation and completion

```mermaid
sequenceDiagram
    participant C as HTTP Client
    participant H as RideController / Rides
    participant S as Dispatch.Store
    participant O as Dispatch.StateServer
    participant W as EventDispatcher / ExpirationScheduler
    C->>H: POST /rides/R/cancel or /complete (empty body)
    H->>S: cancel_ride(owner, R) or complete_ride(owner, R)
    S->>O: Terminal business command
    alt Same operation with valid cross-record terminal receipt
        O-->>S: Original terminal result, no mutation or Driver release
    else Eligible first cancellation
        alt REQUESTED or MATCHING, no active ownership
            Note over O: INSTALL CANCELLED Ride + terminal receipt, no Driver touched
        else DRIVER_ASSIGNED with exact PENDING Offer and OFFERED Driver
            Note over O: INSTALL Offer CANCELLED + Driver AVAILABLE + Ride<br/>CANCELLED/cleared + receipt
        else DRIVER_ACCEPTED with exact accepted evidence and BUSY Driver
            Note over O: INSTALL Offer CANCELLED preserving acceptance + Driver<br/>AVAILABLE + Ride CANCELLED/cleared + receipt
        end
        O-->>S: Original cancelled Ride
    else Eligible completion from DRIVER_ACCEPTED
        Note over O: Validate exact accepted ownership and exclusivity
        Note over O: INSTALL Offer COMPLETED preserving acceptance + Driver<br/>AVAILABLE + Ride COMPLETED/cleared + receipt
        O-->>S: Original completed Ride
    else Opposite terminal operation, invalid state or corruption
        O-->>S: Conflict or invariant error, no partial changes
    end
    S-->>H: Result
    H-->>C: 200 success/replay or sanitized error
    Note over O: Existing events and immutable Offer history retained, no<br/>redispatch from terminal commands
    W->>S: Later pending event or old exact-Offer expiration command
    S->>O: Validate current terminal history
    alt Proven terminal closure
        Note over O: Event acknowledged ignored, expiration ignored, no ownership<br/>change
        O-->>S: Safe result
    else Corrupt terminal evidence
        O-->>S: Controlled invariant failure, not guessed success
    end
    S-->>W: Result
```

Historical Driver status may now be OFFERED/BUSY for another Ride. Replay validates
closure evidence and current relationships rather than requiring that Driver to
remain AVAILABLE. Pending events are retained and safely consumed, not deleted.
Evidence: [terminal Store/reuse](../test/ride_dispatch/dispatch/terminal_lifecycle_test.exs),
[real worker terminal safety](../test/ride_dispatch/dispatch/terminal_dispatch_test.exs)
and [HTTP lifecycle](../test/ride_dispatch_web/controllers/ride_lifecycle_test.exs).

## 6. Competing Rides and duplicate delivery

```mermaid
sequenceDiagram
    participant A as Caller for MATCHING Ride R001
    participant B as Caller for MATCHING Ride R002
    participant S as Dispatch.Store
    participant O as Dispatch.StateServer
    Note over A,O: Two pending dispatch events, one AVAILABLE Driver D001, no<br/>other eligible Driver
    par Competing calls
        A->>S: process_event(owner, E001)
        S->>O: E001 command
    and
        B->>S: process_event(owner, E002)
        S->>O: E002 command
    end
    Note over O: Arrival order is nondeterministic, example below assumes<br/>E001 first
    Note over O: E001 checks latest state, INSTALL R001 assigned + D001<br/>OFFERED + O001 PENDING + E001 PROCESSED
    O-->>S: E001 processed
    S-->>A: processed
    Note over O: E002 sees D001 already owned, INSTALL E002<br/>PROCESSED/no_candidate, R002 stays MATCHING
    O-->>S: E002 processed
    S-->>B: processed
    A->>S: Reprocess E001
    S->>O: E001 command
    O-->>S: already_processed, no new Offer or transition
    S-->>A: already_processed
    Note over A,O: Final: one active Offer/Driver owner, both event outcomes<br/>recorded, losing Ride unassigned
```

Reversing arrival order reverses the winner, not the invariant. GenServer
serialization is the mechanism, while **final-state assertions** establish the
business guarantee. [Reservation tests](../test/ride_dispatch/dispatch/reservation_test.exs)
use barrier-released callers; [acceptance](../test/ride_dispatch/dispatch/acceptance_test.exs),
[expiration races](../test/ride_dispatch/dispatch/expiration_concurrency_test.exs)
and [terminal races](../test/ride_dispatch/dispatch/terminal_concurrency_test.exs)
extend evidence through acceptance, release and reuse. The real dispatcher
serializes its own calls; it is not described as issuing simultaneous callbacks.
These guarantees stop at this single authoritative owner, not a distributed cluster.
