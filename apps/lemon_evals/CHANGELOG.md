# Changelog

## [Unreleased]

### Fixed

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
