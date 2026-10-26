# 🚕 Coding Challenge #3: Ride-Hailing Dispatch Service

## 🎯 Overview

Design and build a simplified **Ride-Hailing Dispatch Service**.

The system receives ride requests from passengers and matches them with available drivers based on their location.

The goal is **not** to build a complete ride-hailing platform.

The goal is to demonstrate how a small dispatch service can be designed correctly today and evolved to support significantly larger scale in the future.

**Timebox: 4-6 hours total.**


---



# 🧩 1. Problem Statement

A passenger wants to request a ride.

The system should:

1. Receive the ride request.
2. Find an available nearby driver.
3. Offer the ride to the driver.
4. Allow the driver to accept or reject the ride.
5. Find another driver if the driver rejects.
6. Prevent a driver from being assigned to multiple rides.
7. Handle duplicate requests/events safely.
8. Maintain a valid ride lifecycle.

Example:

```
Passenger
    |
    | Request Ride
    v
Ride Service
    |
    | Find nearby drivers
    v
Dispatch Service
    |
    | Offer
    v
Driver
    |
    +---- Accept ---> Ride Accepted
    |
    +---- Reject ---> Return to matching; find another driver
```



---



# 📦 2. Scope

The implementation should contain the following components:

```
Ride API
   |
   +---- Ride Management
   |
   +---- Driver Management
   |
   +---- Dispatch / Matching
   |
   +---- Database
   |
   +---- Message Broker
```

A modular monolith is completely acceptable.

The important part is demonstrating that the boundaries could evolve into separate services if required.

For this challenge, a real database and message broker are optional. An in-memory database/repository and in-memory message bus are acceptable when they demonstrate the required behaviour. Docker is not required. If external infrastructure is used, the repository must document how to start it.

Drivers and passengers may be represented by seeded or in-memory records; registration flows are out of scope.



---



# 🗂️ 3. Domain Model

The minimum domain contains:

```
Passenger
Driver
Ride
RideOffer
Location
```

### Driver

```
Driver
------
id
status
latitude
longitude
```

Driver status:

```
OFFLINE
AVAILABLE
OFFERED
BUSY
```

### Ride

```
Ride
----
id
passengerId
pickup
destination
status
assignedDriverId
```

Ride status:

```
REQUESTED
MATCHING
DRIVER_ASSIGNED
DRIVER_ACCEPTED
CANCELLED
COMPLETED
```



---



# ✅ 4. Acceptance Criteria

The following Acceptance Criteria define the required scope.

## AC-01 - Create Ride

The system must provide an API to create a ride.

Example:

```
POST /rides
```

Request:

```
{
  "passengerId": "P001",
  "pickup": {
    "latitude": 10.7769,
    "longitude": 106.7009
  },
  "destination": {
    "latitude": 10.8231,
    "longitude": 106.6297
  }
}
```

Clients must send an `Idempotency-Key` header with each create request:

```http
Idempotency-Key: 7f4d9c2e-ride-request-001
```

### Acceptance

- A unique `rideId` is generated.
- Ride starts in `REQUESTED`.
- Invalid coordinates are rejected.
- `passengerId` is required and must reference a seeded or in-memory passenger record.
- Latitude must be between -90 and 90, and longitude must be between -180 and 180.
- Repeating the same request with the same `Idempotency-Key` returns the original result without creating another ride.
- Reusing an `Idempotency-Key` with a different request is rejected.
- Created ride can be retrieved.



---



# AC-02 - Driver Availability

The system must allow drivers to mark themselves as available or unavailable.

Example:

```
PUT /drivers/{driverId}/availability
```

### Acceptance

- A driver can switch between `OFFLINE` and `AVAILABLE` through the availability API.
- Only `AVAILABLE` drivers can receive offers.
- Creating an offer changes the driver from `AVAILABLE` to `OFFERED`; accepting it changes the driver from `OFFERED` to `BUSY`.
- Rejecting an offer, or cancelling its ride before acceptance, changes the driver from `OFFERED` back to `AVAILABLE`.
- Completing an accepted ride changes the driver from `BUSY` back to `AVAILABLE`.
- `OFFERED` and `BUSY` drivers cannot receive another offer or switch directly to `OFFLINE` through the availability API.
- All other driver status transitions are rejected.



---



# AC-03 - Driver Location

The system must support updating driver location.

Example:

```
PUT /drivers/{driverId}/location
```

### Acceptance

- Driver location can be updated.
- Invalid coordinates are rejected.
- Latest location is stored.
- Driver matching uses the latest known location.



---



# AC-04 - Driver Matching

When a ride is created, the system must find a suitable driver.

For this challenge, use:

**Nearest available driver within a configurable radius.**

Example:

```
Passenger
    |
    +--- Driver A: 0.8 km
    |
    +--- Driver B: 1.5 km
    |
    +--- Driver C: 3.2 km
```

If the maximum radius is 2 km:

```
Driver A -> Candidate
Driver B -> Candidate
Driver C -> Excluded
```

### Acceptance

- Only available drivers are considered.
- The default maximum radius is 2 km; implementations may make it configurable.
- Drivers outside the radius are excluded.
- Drivers can be ordered by distance.
- The nearest suitable driver is selected. If drivers are equidistant, the driver with the lexicographically smallest `driverId` is selected.
- No driver is selected when no suitable driver exists.

A simple Haversine distance calculation is sufficient. Coordinates are valid decimal latitude/longitude pairs; invalid or missing values are rejected before matching.



---



# AC-05 - Ride Offer

The selected driver receives a ride offer.

Example:

```
Ride R001
    |
    v
Driver D001
    |
    +---- ACCEPT
    |
    +---- REJECT
```

### Acceptance

- Creating an offer sets the ride to `DRIVER_ASSIGNED`, stores the offered driver in `assignedDriverId`, and sets that driver to `OFFERED`. This is a pending offer, not an accepted ride.
- Only the driver holding the current offer can accept or reject it.
- Acceptance sets the ride to `DRIVER_ACCEPTED` and the driver to `BUSY`.
- Rejection returns the ride to `MATCHING`, clears `assignedDriverId`, and returns the driver to `AVAILABLE`.
- A driver who rejects a ride cannot receive another offer for that same ride; this exclusion is permanent for that ride, but does not exclude the driver from other rides.
- An offer has a configurable response timeout, with a default of 30 seconds. If the driver does not respond before it expires, the offer is treated as rejected, the driver returns to `AVAILABLE`, and the ride returns to `MATCHING`.
- Rejection causes the system to attempt another eligible driver.

Example endpoints:

```
POST /rides/{rideId}/offers/{driverId}/accept
POST /rides/{rideId}/offers/{driverId}/reject
POST /rides/{rideId}/cancel
POST /rides/{rideId}/complete
```

The passenger or an authorised client triggers cancellation while the ride is in `REQUESTED`, `MATCHING`, or `DRIVER_ASSIGNED`. The driver or ride service triggers completion after the trip has been accepted. Cancelling a pending offer returns its driver from `OFFERED` to `AVAILABLE`; cancelling an accepted ride returns its driver from `BUSY` to `AVAILABLE`.



---



# AC-06 - Ride State Machine

The ride lifecycle must be explicitly implemented.

Minimum lifecycle:

```
REQUESTED ---> MATCHING ---> DRIVER_ASSIGNED ---> DRIVER_ACCEPTED ---> COMPLETED
                  ^                 |
                  +----- Reject ----+
```

Each rejection returns the ride to `MATCHING` so another eligible driver can be offered the ride. If none remains, the ride stays in `MATCHING` with no `assignedDriverId`.

Cancellation:

```
REQUESTED --------> CANCELLED
MATCHING ---------> CANCELLED
DRIVER_ASSIGNED --> CANCELLED
DRIVER_ACCEPTED --> CANCELLED
```

### Acceptance

- Valid transitions succeed.
- Invalid transitions are rejected.
- Duplicate transitions are safely handled.
- State changes, including clearing `assignedDriverId` on rejection, are persisted.
- A timeout follows the same state transition as rejection: `DRIVER_ASSIGNED` to `MATCHING`, with `assignedDriverId` cleared and the driver returned to `AVAILABLE`.
- `CANCELLED` and `COMPLETED` are terminal ride states. A driver is `AVAILABLE` after either outcome.

Example:

```
COMPLETED → DRIVER_ASSIGNED
```

must be rejected.



---



# AC-07 - Rematching

If a driver rejects a ride, the system must attempt to find another driver.

Example:

```
Ride R001
    |
    v
Driver D001
    |
    X REJECT
    |
    v
Find next driver
    |
    v
Driver D002
    |
    ✓ ACCEPT
```

### Acceptance

- Drivers who reject a ride are excluded from all subsequent matching attempts for that ride, even if they become available again. They remain eligible for other rides.
- Another available driver can be selected.
- The same driver is not repeatedly selected for that ride.
- If no eligible drivers remain, the ride stays in `MATCHING` with no `assignedDriverId`.



---



# AC-08 - Idempotency

The system must safely handle duplicate requests/events.

For example:

```
RideCreated(R001)
RideCreated(R001)
RideCreated(R001)
```

must not create three rides.

Similarly:

```
DriverAccepted(R001, D001)
DriverAccepted(R001, D001)
```

must not produce an invalid state.

### Acceptance

The solution must demonstrate idempotency for at least:

- Ride creation using an `Idempotency-Key`
- Driver acceptance
- Ride state transition

The implementation strategy must be documented.



---



# AC-09 - Concurrent Driver Assignment

Two dispatch operations may run at the same time.

Example:

```
Ride R001 ----> Worker A ----+
                             +----> Driver D001
Ride R002 ----> Worker B ----+
```

The system must prevent:

```
Driver D001
    |
    +---- Ride R001
    |
    +---- Ride R002
```

from happening simultaneously.

### Acceptance

- The race condition is identified.
- The implementation prevents the same driver from holding two simultaneous offers or accepted rides.
- If both rides target the same driver, only one can create an offer for that driver; the other remains in `MATCHING` or tries another eligible driver.
- A concurrency test demonstrates this behaviour with two different rides competing for the same driver.
- The chosen concurrency strategy is documented.

Possible approaches:

- Optimistic concurrency
- Database constraint
- Atomic update
- Lock
- Distributed lock

For this challenge, a simple database-based approach is sufficient.



---



# AC-10 - Event-Driven Dispatch

The dispatch process should use asynchronous communication.

For example:

```
Ride API
   |
   | RideCreated
   v
Message Broker
   |
   v
Dispatch Handler
   |
   v
Find Driver
   |
   v
Create Ride Offer
```

A real message broker is **optional**.

Participants may use:

- RabbitMQ
- Kafka
- Redis Streams
- Azure Service Bus
- AWS SQS
- In-memory message bus

### Acceptance

The solution must demonstrate:

```
Ride Created
     ↓
Dispatch Event
     ↓
Driver Matching
```

The README must explain:

- Why asynchronous processing was chosen.
- What happens if the message is delivered twice.
- What happens if processing fails.



---



# 📋 5. Additional Evaluation Requirements

The following required work is assessed under the scoring categories below.

## Testing & Validation

The solution must include automated tests.

Minimum required coverage:

### Matching

- Nearest driver selected.
- Driver outside radius excluded.
- Offline driver excluded.
- Busy driver excluded.
- No driver available.

### Driver Status

- `AVAILABLE` becomes `OFFERED` when an offer is created.
- Rejection or cancellation before acceptance returns `OFFERED` to `AVAILABLE`.
- Acceptance changes `OFFERED` to `BUSY`; completion returns `BUSY` to `AVAILABLE`.
- Invalid driver status transitions are rejected.

### State Machine

- Valid transition.
- Invalid transition.
- Duplicate transition.
- Rejection transitions `DRIVER_ASSIGNED` back to `MATCHING` and clears `assignedDriverId`.

### Rematching

- Driver rejection.
- Second driver selected.
- Rejected driver excluded from subsequent offers for the same ride.

### Concurrency

- Two concurrent rides cannot offer or assign the same driver simultaneously.

### Idempotency

- Duplicate ride creation.
- Duplicate driver acceptance.



---



## System Architecture

The participant must provide a system architecture diagram.

The participant must explain the reasoning.



---



## Scalability & Performance Design

The implementation does **not** need to operate at massive scale.

However, the participant must explain how the design would evolve from:

```
1,000 drivers
        ↓
100,000 drivers
        ↓
1,000,000 drivers
```

The design should discuss:

- Driver location storage
- Matching performance
- Database scaling
- Message broker scaling
- Dispatch worker scaling
- Caching
- Partitioning

### Acceptance

The participant must identify at least:

- 3 potential bottlenecks.
- 3 scaling strategies.
- 2 architectural trade-offs.



---



## Observability

The implementation must provide basic observability.

At minimum, logs should allow an engineer to trace a ride using:

```
rideId
driverId
eventId
```

### Acceptance

An engineer should be able to answer:

"What happened to ride R001?" by following the application logs.



---



## Documentation & Communication

The repository must contain:

```
README.md

docs/
├── architecture.md
├── sequence-diagram.md
└── adr/
    ├── ADR-001-matching.md
    └── ADR-002-concurrency.md
```

The README must explain:

- How to run the application.
- How to run tests.
- Architecture.
- Matching strategy.
- Concurrency strategy.
- Idempotency strategy.
- Event-driven approach.
- Scalability considerations.
- Known limitations.



---



# 🏆 6. Scoring

The challenge is scored out of **100 points**.

Acceptance Criteria are a fundamental part of the scoring.

**A solution cannot receive a high score simply because it has a sophisticated architecture if the required ACs are not satisfied.**

| **Category**                      | **Points** |
| --------------------------------- | ---------- |
| Acceptance Criteria               | 35         |
| System Architecture               | 20         |
| Distributed Systems & Concurrency | 15         |
| Testing & Validation              | 15         |
| Scalability & Performance Design  | 5          |
| Observability                     | 5          |
| Documentation & Communication     | 5          |
| **Total**                         | **100**    |

Concurrency is intentionally assessed in three related places: Acceptance Criteria (AC-09), Distributed Systems & Concurrency, and Testing & Validation. These categories evaluate different evidence: the required behaviour, the chosen protection strategy, and the automated proof. The same concurrency implementation may support all three categories, but the points are not automatic duplicates; each category must satisfy its own criteria.

---



# 🚫 7. What Is NOT Required

To keep the challenge focused, participants do **not** need to implement:

- Payment processing
- Surge pricing
- Authentication
- User registration
- Driver registration
- Full trip management
- Real-time WebSocket communication
- Multi-region deployment
- Kubernetes
- Cloud deployment
- Production-grade geospatial infrastructure
- Machine learning
- Traffic/ETA calculation
- Mobile applications
- Admin dashboard

These may be discussed as future extensions.
