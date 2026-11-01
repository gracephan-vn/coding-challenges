# RideDispatch

An API-only ride-hailing dispatch service: create a Ride, reserve the nearest
available Driver, accept/reject/expire an Offer, rematch, cancel or complete.
Phoenix exposes JSON APIs; one authoritative GenServer owns in-memory state.
Supervised workers handle asynchronous dispatch and Offer deadlines. No database
or external broker is required.

## Quick Start

From the repository root, enter the project directory:

```sh
cd coding-challenge-3/grace-phan
mix deps.get
mix compile --warnings-as-errors
mix test
mix phx.server
```

Normal development startup listens on **http://127.0.0.1:4000** with Passenger
P001 and **no Drivers**. This is an API, not an HTML homepage. For the reproducible
matching demo, stop that server and start instead:

```sh
RIDE_DISPATCH_DEMO=true MIX_ENV=dev mix phx.server
```

Then run the [demo walkthrough](#local-opt-in-demo-and-lifecycle-logs-r2) in another
terminal. Demo state is volatile and recreated from seeds after restart.

### Prerequisites

- Elixir with Mix and a compatible Erlang/OTP installation. `mix.exs` declares
  Elixir `~> 1.17`; the R3 verification environment is **Elixir 1.20.4 / OTP 29.1.2**.
  The project does not pin an OTP minimum or claim a tested version matrix.
- Hex for dependency resolution (`mix local.hex` if not installed). Phoenix is a
  locked project dependency; no global Phoenix generator is needed. `mix.lock`
  locks Phoenix 1.8.16 and Bandit **1.14.1**, updated from 1.14.0 by the R3.1
  security hotfix. The earlier R1 upgrade to 1.14.0 and
  [R3 security verification record](docs/ac-traceability.md#submission-remediation-r3--documentation-verification)
  describe the historical lockfile before R3.1.
- Python 3 only for the copy/paste HTTP demo below. No Node toolchain, database,
  Docker service, broker or local secret is required for development/tests.

## Reviewer map

- [Architecture, ownership, failure boundaries and scaling analysis](docs/architecture.md)
- [Six lifecycle/concurrency sequence diagrams](docs/sequence-diagram.md)
- [Acceptance-criteria evidence and historical test results](docs/ac-traceability.md)
- [Implementation guide and historical TDD checkpoints](docs/implementation-guide.md)
- Accepted decisions: [matching](docs/adr/ADR-001-matching.md),
  [concurrency](docs/adr/ADR-002-concurrency.md),
  [event processing](docs/adr/ADR-003-event-processing.md)
- [Authoritative challenge specification](docs/challenge-spec.md)

## Local opt-in demo and lifecycle logs (R2)

After installing the project's dependencies (`mix setup`), start a fresh local
server from this directory:

```sh
RIDE_DISPATCH_DEMO=true MIX_ENV=dev mix phx.server 2>&1 | tee /tmp/ride-dispatch-demo.log
```

The API listens on **127.0.0.1:4000** (override with `PORT`). The root URL is not a
demo UI; use the API below. `RIDE_DISPATCH_DEMO` accepts unset/`false` (no demo
Drivers), or exactly `true` in development only. Invalid values, or `true` in
production/test, fail startup. This is local demonstration provisioning, not a
production registration mechanism. Tests continue to use isolated owners.

Passenger **P001** exists. Demo Drivers all start **AVAILABLE**, with no Offers:

| Driver | Latitude | Longitude | Distance from pickup |
|---|---:|---:|---|
| D001 | 10.7769 | 106.7009 | 0 km; first choice |
| D002 | 10.7819 | 106.7009 | Approximately 0.56 km; replacement |
| D003 | 10.8169 | 106.7009 | Approximately 4.45 km; outside default 2 km radius |

The ordinary StateServer seed validation and Matcher apply. Pickup is
`10.7769, 106.7009`; destination below is `10.78, 106.71`. Offer response time is
still **30 seconds**, so run the entire following block promptly in a second
terminal. It uses Python 3's standard library as an HTTP client, prints actual
responses, and polls GET with a five-second bound for asynchronous assignment:

```sh
python3 - <<'PY'
import json, urllib.request, urllib.error, time
base='http://127.0.0.1:4000'
def req(method,path,body=None,headers=None):
    data=None if body is None else json.dumps(body).encode()
    request=urllib.request.Request(base+path,data=data,method=method,headers={'Content-Type':'application/json',**(headers or {})})
    try:
        with urllib.request.urlopen(request,timeout=5) as response: code,response_body=response.status,response.read()
    except urllib.error.HTTPError as response: code,response_body=response.code,response.read()
    result=json.loads(response_body)
    print(method,path,code,json.dumps(result),flush=True)
    return code,result
body={'passengerId':'P001','pickup':{'latitude':10.7769,'longitude':106.7009},'destination':{'latitude':10.78,'longitude':106.71}}
code,created=req('POST','/rides',body,{'Idempotency-Key':'r2-demo'})
assert code==201
ride=created['data']['rideId']
def assigned(driver):
    deadline=time.monotonic()+5
    while time.monotonic()<deadline:
        code,result=req('GET','/rides/'+ride)
        if result['data']['status']=='DRIVER_ASSIGNED' and result['data']['assignedDriverId']==driver: return
        time.sleep(0.05)
    raise AssertionError('assignment not observed: '+driver)
assigned('D001')
assert req('POST',f'/rides/{ride}/offers/D001/reject')[0]==200
assigned('D002')
assert req('POST',f'/rides/{ride}/offers/D002/accept')[0]==200
# Legitimate stale A request: must conflict, never be logged as successful acceptance.
assert req('POST',f'/rides/{ride}/offers/D001/accept')[0]==409
code,completed=req('POST',f'/rides/{ride}/complete')
assert code==200 and completed['data']['status']=='COMPLETED'
assert req('POST',f'/rides/{ride}/complete')==(code,completed)
assert req('POST','/rides',body,{'Idempotency-Key':'r2-demo'})==(201,created)
assert req('GET','/rides/'+ride)==(200,completed)
# Existing availability command is idempotent for an AVAILABLE Driver and rejects BUSY.
code,driver=req('PUT','/drivers/D002/availability',{'available':True})
assert code==200 and driver['data']['status']=='AVAILABLE'
print('EXTERNAL DEMO PASS',ride,flush=True)
PY
```

Expected responses use the existing `{"data": {...}}` envelope: creation **201
REQUESTED**, rejection **200 MATCHING**, acceptance **200 DRIVER_ACCEPTED**,
completion **200 COMPLETED**. GET reflects current state, while completed retries
return original results. The deliberately stale D001 acceptance returns **409**
`{"errors":{"detail":"Conflict"}}`. The final PUT is the existing idempotent
availability command: it succeeds unchanged when D002 is AVAILABLE and conflicts
if still BUSY/OFFERED; it is not a new Driver-query endpoint.

There is no HTTP Offer-query endpoint. GET Ride exposes `assignedDriverId` and
status, enough for this route-based workflow. For read-only Offer/receipt/event
inspection, start the same demo with `iex -S mix phx.server` instead of
`mix phx.server`, then use the returned Ride ID:

```elixir
alias RideDispatch.Dispatch.{Store, StateServer}
Store.get_ride(StateServer, "ride-1") # use the actual ID
Store.get_driver(StateServer, "D002")
Store.list_offers(StateServer)
Store.list_events(StateServer)
```

Stop the server with Ctrl+C and restart the same command to repeat from initial
seeds. All runtime Rides, Offers, receipts and events are volatile; no state is
restored, and generated IDs are not promised to remain identical across restarts.

**Correlation and commit boundary.** Store lifecycle commands preserve their
public results and request a StateServer `handle_continue` observation. OTP has
installed the new authoritative state before that continuation emits Logger
records; business callbacks perform no log publication. The continuation reads
only relevant identity/outcome fields from the completed command. No second
business-state owner or event queue is introduced. HTTP response lines can appear
before the corresponding lifecycle log; correlate identities rather than assuming
that adjacent lines belong to one request.

Semantic records include `ride.created`, `event.enqueued`,
`ride.matching_started`, `dispatch.requested`, `dispatch.matching`,
`offer.reserved`, `dispatch.processed`, `dispatch.no_candidate`,
`offer.accepted/rejected/expired`, and `ride.cancelled/completed`.
`dispatch.matching` records a completed selection, not a speculative candidate.
Metadata includes `rideId`, `driverId`, `eventId`, `offerId`, `outcome` and attempts
when available. `causedByEventId` links RideCreated processing to the newly enqueued
dispatch; rejection/expiration logs identify the **new** redispatch event. Its
processing carries the same eventId, even when a different Driver is selected.
Both formatters include the metadata; workers pass identity explicitly.

`operation.replayed` is not another transition. `operation.rejected` records
business conflicts; `operation.failed` records invariant/clock failures.
`event.retry_scheduled` / `event.processing_failed` and
`expiration.retry_scheduled` distinguish technical failures from no-candidate.
Store call timeouts log `operation.uncertain`; worker `*.timeout_reconciled`
diagnostics report authoritative rechecks, including still-uncertain outcomes.
Only actual due checks emit debug `scheduler.expiration_check`; recovery scans
are quiet and malformed-record diagnostics retain bounded suppression.
Lifecycle records contain no request bodies, idempotency keys or full state maps. Unsafe/oversized
identifier strings are omitted from lifecycle metadata rather than interpolated.

This is **best-effort in-process logging**, not a durable or exactly-once audit log.
Owner/application crashes may lose state or a post-commit log; Logger backpressure
can add mailbox latency. Logs neither determine business truth nor replace receipts.

**Executed R2 evidence:** the external network workflow above passed, then passed
again after a full server restart. One captured run linked `ride-1`, `event-1`,
`dispatch-ride-1`, D001/`offer-2`, `redispatch-offer-2`, and D002/`offer-3`.
Read-only Store inspection confirmed a completed Ride, D001/D002 AVAILABLE,
rejected offer-2 with receipt, completed offer-3 with acceptance evidence, and
three processed events. Duplicate completion/creation emitted replay records;
stale acceptance emitted a rejection, with no extra success record.
Separately, isolated tests cover worker retry, timeout reconciliation, no-candidate,
expiration/cancellation logging, competing duplicates and corruption safety:
**10 focused demo/logging tests and 321 full-suite tests passed** at R2.
Technical fault injection is in-process test evidence, not a claimed network outage.

## API contracts

All success responses use `{"data": {...}}`; errors use
`{"errors":{"detail":"..."}}`. Ride JSON contains `rideId`, `passengerId`,
`pickup`, `destination`, uppercase `status` and `assignedDriverId`. Private Offer
pointers and receipts are not returned in HTTP Ride JSON.

| Method / route | Request | Success |
|---|---|---|
| `POST /rides` | Exactly one nonblank `Idempotency-Key` header; `passengerId`, `pickup`, `destination` JSON as in demo | 201 original REQUESTED result and `Location: /rides/{rideId}` |
| `GET /rides/:rideId` | None | 200 current Ride |
| `PUT /drivers/:id/availability` | `{"available":true}` or false | 200 Driver with `id`, `status`, `latitude`, `longitude` |
| `PUT /drivers/:id/location` | `{"latitude":10.78,"longitude":106.70}` | 200 updated Driver |
| `POST /rides/:rideId/offers/:driverId/accept` | No body or `{}` | 200 original DRIVER_ACCEPTED result |
| `POST /rides/:rideId/offers/:driverId/reject` | No body or `{}` | 200 original MATCHING result |
| `POST /rides/:rideId/cancel` | No body or `{}` | 200 original CANCELLED result |
| `POST /rides/:rideId/complete` | No body or `{}` | 200 original COMPLETED result |

Creation accepts only the documented fields and exact coordinate objects. Latitude
must be numeric in [-90,90], longitude in [-180,180]; strings are invalid.
Integer/float coordinate equivalents canonicalize equally, without geographic
rounding. Same key/canonical payload replays the original creation result even
after lifecycle progression; different payload conflicts. Unknown Passenger on a
new request is 400. Lifecycle endpoints reject unsupported fields and unparsed
nonempty bodies. Driver-update endpoints validate required values but ignore extra
fields. Invalid JSON is rejected before business processing.

Lifecycle success/replay is 200; malformed requests are 400, unknown resources or
absent Offer relationships 404, valid state/ownership/expiry/ambiguity conflicts
409, and corrupted authoritative evidence or invalid trusted clock 500. Errors are
sanitized. Driver IDs in paths identify the Offer holder, **not an authenticated
network caller**. No Driver/Passenger creation, Offer query or expiration HTTP API
is implemented.

## Lifecycle, duplicate and failure semantics

- RideCreated processing moves REQUESTED → MATCHING and atomically enqueues
  DispatchRequested. Matching uses latest authoritative coordinates/availability,
  default radius **2 km**, Haversine distance and lexicographic Driver-ID ties.
- Reservation atomically installs Ride DRIVER_ASSIGNED, Driver OFFERED, one PENDING
  Offer and event acknowledgement. It is not acceptance. Accept changes them to
  DRIVER_ACCEPTED / BUSY / ACCEPTED, preserving exact Offer-bound evidence.
- Rejection and expiration release the Driver, clear assignment, retain history
  and create one Offer-derived redispatch event. Rejected/expired Drivers remain
  excluded for that Ride, but can serve another Ride. Redispatch uses current
  eligibility; no candidate leaves MATCHING/unassigned with a processed
  `no_candidate` event, not an infinite search or infrastructure retry.
- Offer timeout defaults to **30,000 ms**. Expired iff trusted monotonic
  `now_ms >= expires_at_ms`; first acceptance at equality fails. A delayed timer
  does not itself release an OFFERED Driver. Explicit rejection remains permitted
  while the overdue Offer is current/PENDING. The scheduler performs the close.
- Cancellation supports REQUESTED, MATCHING, DRIVER_ASSIGNED and DRIVER_ACCEPTED.
  Completion requires DRIVER_ACCEPTED. Terminal closure releases exact ownership,
  clears Ride pointers and marks the historical Offer CANCELLED/COMPLETED while
  retaining successful acceptance evidence. Pending events/old timers cannot
  reopen a terminal Ride or release a Driver already reused elsewhere.
- Identity-proven retries return immutable original results, not current Ride
  state; GET returns current state. Accept/reject routes cannot distinguish
  multiple historical Offers for the same Ride/Driver pair, so ambiguous histories
  conflict. Terminal status alone is not proof of a successful operation.
- One dispatcher uses startup discovery, hints and recovery scans. Supported
  pending events survive worker restart while StateServer survives. Technical
  event failures use bounded attempts/backoff (three attempts, 1 s / 2 s delays),
  then FAILED retention. Unsupported events remain pending. Store timeouts are
  uncertain outcomes, reconciled against authoritative evidence.
- One scheduler uses next-deadline timers and recovery scans (default 1,000 ms).
  Exact-Offer commands validate ownership/time, isolate corrupt records, bound
  diagnostics and invalidate old-owner work. Scans are recovery, not a real-time
  deadline guarantee. See [failure details](docs/architecture.md#asynchronous-delivery-clocks-and-failure-boundaries).

## Developer commands and troubleshooting

Run from the project directory; do not export demo mode into test commands:

```sh
mix test
mix test test/ride_dispatch/dispatch/reservation_test.exs test/ride_dispatch/dispatch/terminal_concurrency_test.exs
mix test test/ride_dispatch/demo_test.exs test/ride_dispatch/dispatch/lifecycle_logging_test.exs
mix compile --warnings-as-errors
mix format --check-formatted
mix hex.audit
git diff --check
```

Tests use isolated StateServers, controlled clocks and barrier/worker coordination.
Pure tests, Store/HTTP integration, real asynchronous workers and synthetic corrupt
history fixtures are distinguished in [traceability](docs/ac-traceability.md).
The demo above uses an external HTTP listener; it is not merely Phoenix.ConnTest.
Historical counts remain labelled by feature/remediation checkpoint. AI-assisted
implementation used explicit RED → GREEN groups and reviewed local commits; this
R3 change is documentation-only, not new TDD or an independent submission audit.

- **No assignment:** normal startup has no Drivers. Use the explicit demo, valid
  pickup and a fresh restart; D003 is outside the radius. Updates to availability
  or location do not automatically redispatch an already exhausted matching event.
- **Port already in use:** stop the old server or set `PORT=4001`; update the demo
  client's `base` accordingly. Ctrl+C stops the volatile demo; restart resets it.
- **409 during a slow manual demo:** the Offer may have reached its 30-second
  deadline or been rematched. Use GET Ride and correlated logs; run the complete
  bounded-polling block on fresh seeds instead of assuming a fixed delay is enough.
- **Configuration:** only `RIDE_DISPATCH_DEMO`, `PORT` and normal Phoenix runtime
  variables described in `config/runtime.exs` are environment switches here.
  Matching radius, Offer timeout and scheduler scan interval use application keys
  `:matching_radius_km`, `:offer_timeout_ms`, `:offer_expiration_scan_interval_ms`;
  startup validates them. No undocumented environment aliases are implied.
- **Logs:** use the demo's `tee` command, then search the returned Ride ID in
  `/tmp/ride-dispatch-demo.log`. Correlation includes event/Offer/Driver identities;
  HTTP responses and post-installation logs may interleave. Hex audit needs access
  to current advisory metadata; a network failure is not a clean security result.

## Limits and future work

One StateServer provides single-node atomicity; it is a mailbox/CPU bottleneck.
StateServer/VM restart loses runtime state, receipts and non-durable events. Worker
restart recovery is not crash durability. Monotonic timestamps are meaningful
only in their VM lifetime. Retained histories grow without bounds; logging is
best effort, not an exactly-once audit trail. Authentication/authorization, durable
storage and multi-node reservation are not implemented.

[Scaling scenarios](docs/architecture.md#scalability-and-performance-design)
explain 1k/100k/1m Drivers, indexes, retention and durable distributed coordination.
They are proposals, not benchmarks or deployed infrastructure. The architecture
and six sequences describe the current system; historical ADR feature-state notes
retain their original context.
