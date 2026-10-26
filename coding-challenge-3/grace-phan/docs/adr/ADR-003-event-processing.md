# ADR-003: Asynchronous in-memory event processing

Status: Accepted

## Context

AC-08 and AC-10 require duplicate-safe asynchronous dispatch. Ride creation
already records pending events atomically. Processing must survive dispatcher
restart while the authoritative owner remains alive, without partial business
updates or premature acknowledgement. [ADR-002](ADR-002-concurrency.md) governs
state ownership; this decision governs event consumption and recovery.

## Decision

Use one supervised [EventDispatcher](../../lib/ride_dispatch/dispatch/event_dispatcher.ex),
independent of HTTP, operating through [Dispatch.Store](../../lib/ride_dispatch/dispatch/store.ex).
`Store.process_event/2` delegates one complete business transition to
[StateServer](../../lib/ride_dispatch/dispatch/state_server.ex): RideCreated becomes
processed, its REQUESTED Ride becomes MATCHING, and one pending DispatchRequested
is installed together. No external I/O, publication or task spawning occurs in
that callback. No leased claims or separate acknowledgement command is needed
for these short, local transitions.

Wake-up hints provide prompt discovery; startup and bounded recovery scans cover
missed hints. Authoritative event state determines eligibility. Unsupported events
remain pending and queryable, excluded from actionable scans and retry accounting
until their handler exists. DispatchRequested consumption belongs to Feature #10B;
acknowledged RideCreated events need not reopen.

Retained processed records and current Ride checks prevent duplicate transitions
and successor emission. Permanent inconsistencies fail immediately. Definite
retryable worker failures use bounded backoff and version-checked failure accounting,
ending in a retained failure record. A Store timeout has an uncertain outcome:
reread authoritative state before retrying, without charging a failure attempt.
Dispatcher restart rediscovers work; owner loss destroys all runtime records.
This does not promise durable or exactly-once delivery. AC-10 remains PARTIAL
until asynchronous Driver matching and its duplicate/failure handling exist.

## Alternatives

- Leased claims: support work outside the owner or multiple consumers, but add
  expiry and fencing complexity unnecessary for the current atomic handler.
- Polling only: simpler notification wiring, but makes normal latency depend on
  the scan interval. Hints retain recovery scanning as a fallback.
- External broker: can provide durable delivery with suitable configuration, but
  adds infrastructure and does not itself make business updates atomic.

## Consequences

Reads, event scans and mutations contend for one mailbox. Retained history grows
in memory; dispatcher supervision provides no recovery after volatile state loss.
Consistency remains single-node. Reconsider this choice when measured scan or
mailbox costs become unacceptable, durable recovery or multi-node writes are
required, or handlers need external side effects or multiple consumers.

[Event Store tests](../../test/ride_dispatch/dispatch/event_store_test.exs) cover
atomicity, competing callers, unsupported work and retry limits.
[Dispatcher tests](../../test/ride_dispatch/dispatch/event_dispatcher_test.exs)
cover wake-ups, recovery, crash windows and timeout rechecks;
[Ride HTTP tests](../../test/ride_dispatch_web/controllers/ride_controller_test.exs)
cover original-result replay after asynchronous transition. Operational contracts
and retry policy remain in the [implementation guide](../implementation-guide.md).
