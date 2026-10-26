# ADR-002: Single authoritative state owner behind Dispatch.Store

Status: Accepted

## Context

The challenge permits volatile in-memory storage. Future assignments will need
consistent changes across Driver, Ride, and RideOffer records, including
duplicate-safe outcomes. Phase B establishes ownership before those workflows.

## Decision

Use one supervised `RideDispatch.Dispatch.StateServer` GenServer with Maps as
the authoritative state. All application queries and commands go through
`Dispatch.Store`, with an explicit server PID or registered name. StateServer's
message protocol is internal; no generic state replacement or caller-supplied
mutation functions are exposed. Returned Elixir values cannot mutate owned state.
This is an architectural boundary, not a security boundary against arbitrary
code executing inside the same BEAM.

Each business command validates current state and installs its complete update
within one callback. Future multi-entity commands must update all affected records
in that callback, never compose separate public reads and writes. Pure domain
functions supply validation and transition logic. A callback serializes only its
owned state: it provides no automatic transaction for external side effects.

Phase B implements only a Driver map, seeded reads, available-driver listing,
seed validation, and atomic location updates. Production has one named owner;
tests use isolated unnamed supervised instances. Competing-task tests exercise
updates to separate drivers and complete coordinate pairs on the same driver.

**AC-09 reservation safety is NOT implemented or verified in Phase B.**
Architectural acceptance is not proof of future assignment behavior. Ride,
Offer, idempotency, and event collections and their invariants remain future work.
No external database or ETS is used in the current implementation.

## Alternatives

- Direct GenServer calls throughout application code: retain serialization but
  couple callers to internal messages and make storage changes harder.
- ETS-first storage: enables concurrent reads but does not by itself provide
  atomic multi-record business transitions.
- Per-driver processes or geographic partitions: distribute mailbox load but
  require coordination across owners, rides, and partition boundaries.
- Database-backed storage: transactions, constraints, and durable records can
  address persistence and shared-state needs, at the cost of infrastructure,
  migrations, and a different failure model. No Ecto is introduced now.

## Consequences

- Reads and writes contend for one mailbox. `list_available_drivers` scans the
  driver map and sorts results; large lists can delay unrelated calls. Future
  matching in callbacks can also be expensive. Avoid blocking external I/O there.
- A process crash loses volatile runtime state. Supervision restarts from startup
  seeds, not the lost updates. Phase B started with empty seeds; the current
  application seeds Passenger P001 and no Drivers.
- Consistency is single-node and single-owner. Multiple independent owners on
  different nodes would not enforce global uniqueness or reservation safety.
- Concurrent senders have no guaranteed ordering. Whole location updates use
  arrival order; stale-location detection is not implemented. Call timeout does
  not cancel a queued command, and owner failure can make outcomes uncertain.
- Invalid commands leave state unchanged. Tests inject separate PIDs, so no
  shared reset API or global mutable test fixture is needed.
- If measured read contention warrants it, ETS may become an owner-written
  `:protected` read projection behind Store. It is rebuildable, can be stale or
  observed between projection updates, and must never become a second source of
  truth. Critical commands must revalidate authoritative state before committing.

Reconsider this decision when measured mailbox delays or list-scan costs exceed
requirements, when restart data loss becomes unacceptable, or when multi-node
writes are required. Benchmark before adding projections or partitioning; choose
durable storage and coordination explicitly rather than claiming these properties
from supervision or ETS alone.
