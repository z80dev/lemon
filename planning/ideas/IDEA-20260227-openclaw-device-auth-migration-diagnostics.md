---
id: IDEA-20260227-openclaw-device-auth-migration-diagnostics
title: [OpenClaw] Device Auth Migration Diagnostics and Guided Recovery
source: openclaw
source_commit: cb9374a2a10a
discovered: 2026-02-27
status: proposed
---

# Description
OpenClaw shipped stronger diagnostics around device-auth v2 migration, focusing on clearer root-cause visibility and actionable remediation when auth state is stale or mismatched.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon has robust auth and pairing surfaces (`LemonControlPlane.Auth.*`, token store, pairing methods), but migration-grade diagnostics are spread across logs and app-specific flows.
  - Missing a unified “auth diagnostics report” that explains why a node/device/token path is failing and what exact recovery step is recommended.
  - Opportunity to reduce support/debug loops for OAuth/device-token transitions and rotated credentials.

# Investigation Notes
- Complexity estimate: **S**
- Value estimate: **M**
- Open questions:
  1. Should diagnostics be exposed as a new control-plane method (e.g., `auth.diagnose`) or folded into existing `diag` flows?
  2. Which auth paths are highest priority (operator token, node token, OAuth providers, channel adapter auth)?
  3. What redaction policy is required so diagnostics remain safe in shared logs?

# Recommendation
**proceed** — This is a low-to-medium effort reliability win that should improve onboarding and incident recovery for auth/pairing issues.
