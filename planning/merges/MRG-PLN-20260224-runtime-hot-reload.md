---
plan_id: PLN-20260224-runtime-hot-reload
status: ready_to_land
prepared_at: 2026-02-24
prepared_by: janitor
---

# Merge Record: Runtime Hot-Reload System for BEAM Modules and Extensions

## Summary

This merge record captures completion of `PLN-20260224-runtime-hot-reload` through M8.
The runtime reload stack and `system.reload` control-plane endpoint are implemented and validated.

## Delivered

- `Lemon.Reload` module for module/extension/app/system reload workflows
- Global lock orchestration for system reload path
- Telemetry events for reload start/stop/exception
- `system.reload` JSON-RPC method and schema integration
- Tests for reload core and control-plane method
- Operator-facing documentation in `docs/runtime-hot-reload.md`

## Validation

- `mix test apps/lemon_core/test/lemon_core/reload_test.exs` ✅ (14 tests)
- `mix test apps/lemon_control_plane/test/lemon_control_plane/methods/system_reload_test.exs` ✅ (10 tests)

## Related

- Plan: `planning/plans/PLN-20260224-runtime-hot-reload.md`
- Review: `planning/reviews/RVW-PLN-20260224-runtime-hot-reload.md`
