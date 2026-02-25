# Review: Debt Phase 13 Client CI Parity and Dependency Governance

## Plan ID
PLN-20260222-debt-phase-13-client-ci-parity-governance

## Review Date
2026-02-26

## Reviewer
janitor

## Summary
Milestones M1-M11 are now complete. This final slice closed M8/M10/M11 by fixing lemon-web audit vulnerabilities, aligning client Vitest/@types/node versions, and documenting dependency-tooling governance decisions.

## Scope Reviewed
- `clients/lemon-web/package-lock.json`
- `clients/lemon-tui/package.json`
- `clients/lemon-tui/package-lock.json`
- `clients/lemon-browser-node/package.json`
- `clients/lemon-browser-node/package-lock.json`
- `clients/lemon-web/shared/package.json`
- `clients/lemon-web/server/package.json`
- `planning/plans/PLN-20260222-debt-phase-13-client-ci-parity-governance.md`

## Validation
```bash
cd clients/lemon-tui && npm run lint && npm run typecheck && npm test && npm run build
cd clients/lemon-browser-node && npm run lint && npm run typecheck && npm test && npm run build
cd clients/lemon-web && npm --workspace shared run test && npm --workspace server run test && npm --workspace web run test
cd clients/lemon-web && npm run typecheck && npm run build && npm audit --audit-level=high
mix test apps/lemon_services/test
```

## Quality Checklist
- [x] lemon-web high/moderate audit findings remediated (`npm audit --audit-level=high` clean)
- [x] Vitest aligned to `^4.0.18` across TS client packages
- [x] `@types/node` aligned to `^24.10.1` where used
- [x] Client lint/typecheck/test/build checks pass for touched packages
- [x] Plan milestones and progress log updated

## Notes
A broad `mix test` run was also attempted and surfaced pre-existing failures in `apps/lemon_channels/test/lemon_channels/adapters/telegram/transport_topic_test.exs` unrelated to this TS-client slice.

## Recommendation
Approve and move to `ready_to_land`.
