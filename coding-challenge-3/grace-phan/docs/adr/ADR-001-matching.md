# ADR-001: Pure nearest-driver matching

Status: Accepted

## Context

AC-04 requires the nearest available driver within a default 2 km radius,
with lexicographic driver-ID tie-breaking. AC-05 and AC-07 require rejected
and timed-out drivers to remain excluded from subsequent attempts for the
same ride, while remaining eligible for other rides.

## Decision

Use the pure `RideDispatch.Dispatch.Matcher.nearest/3` function. It filters
`:available` drivers, valid coordinates, and caller-supplied ride-specific
exclusions; computes distances through `Location.distance_km/2`; applies an
inclusive configurable radius; and selects the minimum `{distance, driver_id}`.
Exactly equal computed distances are resolved by lexicographic string ID,
independently of input order. Driver IDs must be unique.

Return `{:ok, driver}` or `:none`. Invalid pickups and radii return explicit
errors; malformed driver records are ineligible. No input or application state
is mutated. The caller must retain and supply the complete exclusion history.

Haversine uses a spherical Earth radius of 6,371 km and clamps floating-point
roundoff near antipodes. Matching and distance behavior have automated tests,
including radius boundaries and reversed-order ties. Selection is not reservation:
the authoritative owner must eventually select or revalidate and reserve atomically.

## Alternatives

- Sort all candidates: useful for returning a ranked list, but unnecessary for
  selecting one minimum.
- Spatial index or geographic partitioning: can reduce the candidate search,
  but adds indexing and boundary coordination not required by this challenge.
- Road-distance or ETA service: closer to actual travel cost, but adds external
  I/O and differs from the challenge's sufficient Haversine approach.

## Consequences

Selection scans candidates in O(n) time and currently allocates intermediate
lists. It is deterministic for the same valid inputs and needs no infrastructure.
Distances approximate a sphere, not roads or the Earth's ellipsoid; ties use
exact computed equality, not an epsilon. No performance benchmark is claimed.
Reconsider indexing or partitioning when measured candidate counts and matching
latency justify the added complexity.
