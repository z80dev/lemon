# Factory changelog

## Unreleased

### Base refresh under continuous work

- The coordinator base refreshed only when no attempt happened to be live, so a
  busy factory kept dispatching new work on a stale `main`. A moved base now holds
  new reservations until live attempts finish, then refreshes and wakes the
  coordinator.

### F-0046 — heavy-work leases and informational write sets

- Concurrent tasks may edit the same files. Optional `write_set` declarations
  are retained as informational snapshots and never refuse or delay admission.
  Removed overlap refusal, lexical scope locks, and the CLI/coordinator override
  mechanism. Existing ledger columns remain migration-safe but are not enforced.
- Sequence work only through explicit dependencies. Review and integration handle
  overlapping edits; integration conflicts return as a repair rebased onto
  current main. Existing runtime, epoch, capacity, same-task live-attempt, budget,
  backlog, and checkout gates remain unchanged.
- Factory-context BEAM lanes in `scripts/test` and checkout setup acquire
  per-project `heavy_beam_slots` kernel leases. Inherited descriptor/token
  validation permits nested work under a live lease; a process-group crash fence
  prevents TTL-based eviction while descendants still run. Waiting for a slot
  has a bounded timeout with diagnostics. Missing runners fail closed inside
  factory context; non-BEAM lanes and non-factory use retain their existing
  behavior. No approved live policy or capacity values are changed.
- Checkout setup enforces execution deadlines inside the lease runner, terminating
  and reaping the actual command group (including TERM-ignoring descendants)
  before returning failure or allowing base restoration. The lease remains held
  until command-group death is confirmed.
