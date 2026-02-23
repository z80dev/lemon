---
id: IDEA-20260224-openclaw-cron-web-ui-parity
title: Web UI cron edit parity with full run history and compact filters
source: openclaw
source_commit: 77c3b142a
discovered: 2026-02-24
status: proposed
---

# Description
OpenClaw significantly enhanced their Web UI cron management with full edit parity, comprehensive run history, and compact filters. This provides a much better user experience for managing scheduled jobs.

Key features:
- Full cron edit parity (create, edit, delete with full feature support)
- All-jobs run history view
- Compact filters for job management
- Data-driven agents tools catalog with provenance
- Enhanced UI components for cron management

Files changed:
- run-log.ts, service.ts, service/ops.ts (backend cron operations)
- cron-validators.test.ts, schema/cron.ts (validation)
- server-methods/cron.ts, server.cron.test.ts (API)
- UI components: cron.ts, cron.test.ts, presenter.ts
- Styling: components.css

# Lemon Status
- Current state: Lemon has basic cron support via lemon_automation app
- Gap: Web UI cron management is minimal compared to OpenClaw's comprehensive implementation

# Investigation Notes
- Complexity estimate: L
- Value estimate: M (DX improvement)
- Open questions:
  - What is the current state of Lemon's web UI for cron?
  - Does lemon_automation expose enough APIs for rich cron management?
  - How much of this is UI-only vs requiring backend changes?

# Recommendation
defer - Nice-to-have DX improvement. Current cron functionality works; this is a polish feature that can wait until core stability work is complete.

# References
- OpenClaw commit: 77c3b142a
- Related: OpenClaw commit 9e1b13bf4 (data-driven agents tools catalog)
