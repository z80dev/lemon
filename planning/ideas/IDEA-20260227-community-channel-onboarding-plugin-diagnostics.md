---
id: IDEA-20260227-community-channel-onboarding-plugin-diagnostics
title: [Community] Channel Onboarding Plugin Diagnostics and Guided Recovery
source: community
source_url: https://github.com/openclaw/openclaw/issues/24781
discovered: 2026-02-27
status: proposed
---

# Description
Community reports show repeated onboarding failures where users select a channel, provide credentials, and then hit a generic "plugin not available" dead-end. Demand is growing for guided diagnostics and concrete recovery steps during channel setup.

# Evidence
- OpenClaw issue #24781: fresh VPS onboarding fails at Discord setup with "discord plugin not available" despite valid flow completion.
- Recent community threads (Reddit + Discord/AnswerOverflow) show users repeatedly confused by channel availability vs permissions vs install state.
- Practical impact: blocks first-run activation and increases churn during initial setup.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon has setup/wizard primitives but limited channel-specific failure taxonomy surfaced to end users.
  - Recovery guidance is not consistently generated from install/auth/runtime diagnostics in a single onboarding UX path.
  - No clearly standardized "doctor for channel onboarding" experience across adapters.

# Value Assessment
- Community demand: **H**
- Strategic fit: **H**
- Implementation complexity: **M**

# Recommendation
**proceed** — High first-run conversion and support-load payoff; implement capability-aware preflight checks + actionable remediation hints in onboarding flow.
