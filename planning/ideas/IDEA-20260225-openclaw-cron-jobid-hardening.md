---
id: IDEA-20260225-openclaw-cron-jobid-hardening
title: [OpenClaw] Canonical jobId Handling and Validation for cron.runs
source: openclaw
source_commit: 259d86335378
discovered: 2026-02-25
status: proposed
---

# Description
OpenClaw landed a cron hardening patch for `cron.runs` path handling (`259d86335378`), focusing on stricter `jobId` parsing/validation and server-path consistency across schema, validators, and method handlers.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon's `cron` tool already supports `id` and `jobId` aliases at tool level.
  - Control-plane `cron.runs` schemas/methods are stricter around `id`, creating potential mismatch between user-facing aliases and RPC-layer expectations.
  - Opportunity to standardize canonicalization + validation across all cron entry points (`run`, `runs`, `update`, `remove`) and return consistent error payloads.

# Investigation Notes
- Complexity estimate: **S**
- Value estimate: **M**
- Open questions:
  1. Should RPC schemas accept both `id` and `jobId` everywhere, with one canonical internal key?
  2. Should mismatched alias usage return warnings for migration instead of hard errors?
  3. Are there existing clients depending on `id`-only validation behavior?

# Recommendation
**investigate** — Small hardening task that can prevent edge-case failures and keep cron ergonomics consistent across tool and RPC layers.
