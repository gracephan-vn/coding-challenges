# Ride-Hailing Dispatch Challenge — Agent Instructions

## Source of truth
- `docs/challenge-spec.md` is the authoritative challenge specification.
- Meet all 10 acceptance criteria.
- `docs/implementation-guide.md` provides the chosen implementation approach.
- If guidance conflicts with the challenge, follow the challenge and report the conflict.

## Architecture
- Elixir + Phoenix, API-only, no Ecto.
- Modular monolith with Rides, Drivers, and Dispatch boundaries.
- Functional core for matching, validation, and state transitions.
- One authoritative GenServer-backed in-memory state owner.
- Use `Dispatch.Store` as the public state access boundary.
- Never bypass Store to mutate internal state.
- Keep queries separate from commands.
- Multi-entity state changes must be atomic.
- ETS is a future optimization, not part of the initial implementation.
- The event bus must support asynchronous dispatch.
- Document the limitations of volatile in-memory state.

## TDD
- Work in one small behavioral slice at a time.
- First write a failing test and verify the expected failure.
- Then implement the smallest correct solution.
- Refactor without changing behavior and rerun tests.
- Do not implement future slices unless explicitly requested.
- Do not claim tests passed unless executed successfully.

## Git
- Preserve the competition branch naming convention.
- Never force-push, reset hard, rebase, squash, merge, or open a PR without explicit approval.
- Local commits are permitted only when explicitly authorized by the current task. Push, history rewrites and destructive Git operations always require separate approval.
- Show proposed Git commands and explain their effects.
- Preserve visible Red-Green-Refactor commit history.
- Never commit secrets or generated dependencies.

## Engineering
- Prefer idiomatic Elixir, OTP, and Phoenix conventions.
- Keep controllers thin.
- Enforce invariants at the authoritative state owner.
- Avoid premature abstractions and unnecessary dependencies.
- Make time-dependent behavior deterministic in tests.
- Test concurrent behavior with actual competing processes.
- For architectural changes, explain the rationale, alternatives, and trade-offs.

## Project consistency
Before declaring a feature complete:

- Compare affected public contracts with `docs/challenge-spec.md` and verify relevant code and tests.
- Update only affected documentation and `docs/ac-traceability.md`; distinguish implemented behavior from plans.
- Report discrepancies instead of silently changing accepted architectural decisions.
- Inspect the Git diff and preserve unrelated working-tree changes.

## Efficiency
- Inspect only files relevant to the active task.
- Do not repeatedly reread the entire specification.
- Run focused tests during TDD; run the full suite at appropriate checkpoints.
- Avoid unnecessary web searches, package installations, and tool calls.
- Keep responses concise and report only relevant results.

## Output for each completed slice
1. Behavior addressed and AC reference.
2. RED test and observed failure.
3. GREEN implementation and test result.
4. Refactor and verification.
5. Files changed.
6. Architecture rationale and trade-offs, if applicable.
7. Suggested Git commits.
8. One recommended next slice.

Complete one explicitly assigned behavior group using multiple Red–Green–Refactor cycles. Preserve test-first evidence in Git history. Stop after the behavior group is complete. Never proceed to an unrelated feature.
