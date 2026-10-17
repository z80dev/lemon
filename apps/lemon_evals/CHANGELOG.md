# Changelog

## [Unreleased]

### Fixed

- Isolated paired runtimes allocate ephemeral gateway/router health listeners,
  bind HTTP listeners to loopback and assert disclosure through the current
  `Config.load().agent.tools` schema. Real compiled-runtime offline gates cover
  both profiles, occupied health ports, the production CLI/verifier, and verified
  cleanup and disposal without provider requests.
  The profiling worker also uses the native launch ledger, so its independent
  process group must be proven terminated before trial disposal.
- Campaign admission fails closed after provider/quota/auth or uncertain usage
  failures, preserving the attempted row and a durable stop marker. Per-provider
  work is bounded to eight hours (or a shorter `--run-timeout`), with independent
  bounded process cleanup grace and explicit stop-bound continuation on resume.
  Task-quality checks preserve earlier terminal CLI failures, including transport
  errors after a read-only task mutates its fixture; complete usage cannot admit
  another trial without explicit stop-bound continuation.

- Paired-attempt cleanup can recover the private process store and native launch
  ledger offline without booting a runtime. Recovery uses shared birth-bound
  local group proofs, durably records newly observed members before signalling,
  visits both ledgers on failure, and retains unverified evidence and capacity.
  Fresh private ledgers are configured before boot and checked after boot.
- Recovery retries require a successful host-crash durability barrier immediately
  before signalling even when a previous failed attempt already saved the same
  member witness in DETS.
- Offline process-store recovery accepts the store's list-valued logs and
  preserves them when updating group witnesses; native ledger logs remain maps.
