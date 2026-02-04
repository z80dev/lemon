# OpenClaw Parity Status (as of 2026-02-04)

This document summarizes our current parity status with OpenClaw. It replaces the root-level parity blueprint and review notes.

## Scope and Definition
Parity here means we match OpenClaw’s **gateway method/event surface** and the operational contracts described in `parity.md` (required vs optional methods/events, schema validation, and transport-agnostic behavior). Optional methods are considered **surface-compatible** unless we explicitly decide to require full functional backends.

## Implemented
- Parity umbrella apps are present and wired into the repo:
  - `lemon_core` (event/bus/store/telemetry primitives)
  - `lemon_router` (routing, approvals, run orchestration)
  - `lemon_channels` (adapter registry, outbox, chunking, rate limiting, dedupe)
  - `lemon_control_plane` (WS/HTTP server, authz, method registry, schemas)
  - `lemon_skills` (skill install/update plumbing)
  - `lemon_automation` (cron/heartbeats)
- Control-plane method registry includes the required parity surface plus the optional parity methods.
- Control-plane schema validation exists for parity methods.
- JSONL store supports parity tables and dynamic table discovery on startup.
- Outbox rate limiting is enforced via `consume/2` and has a re-queue test to ensure delivery after throttling.

## Implemented but Conditional (Optional Parity Methods)
These methods exist and are callable, but require external configuration or integrations to be fully functional:
- `browser.request` requires a paired, online browser node.
- `tts.convert` depends on platform TTS or configured providers (OpenAI/ElevenLabs keys); unsupported platforms return not-implemented errors.
- `update.run` performs update checking via a configured manifest URL and downloads updates to a pending location; it does not perform a full install beyond download + optional restart.
- `usage.cost` reads usage totals from the `:usage_data` store and returns stub values when no tracking is configured.

## What’s Still Missing / Open Decisions
- **Optional parity functionality:** We need to decide whether optional parity methods must be **fully functional** or if surface-compatibility is sufficient. If functionality is required, we need real backends for browser automation, TTS, update installation, and usage accounting.
- **End-to-end parity verification:** There is no single integration suite that proves parity end-to-end (method surface, WS event sequencing, approvals, sessions, channel inbound/outbound). Targeted unit tests exist, but full parity verification is still incomplete.

## Current Status
We are **close to parity** on the required surface. The remaining work is primarily:
1. Decide and document the expected functional depth for optional parity methods.
2. Add end-to-end parity verification tests (or a formal verification checklist if tests are impractical).
