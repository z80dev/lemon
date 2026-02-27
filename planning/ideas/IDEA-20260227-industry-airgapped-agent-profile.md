---
id: IDEA-20260227-industry-airgapped-agent-profile
title: [Industry] Air-Gapped/Offline Deployment Profile for Self-Hosted Agents
source: industry
source_url: https://blog.cloudflare.com/moltworker-self-hosted-ai-agent/
discovered: 2026-02-27
status: proposed
---

# Description
Industry momentum around self-hosted agents is increasing demand for deployment profiles that support restricted/offline environments: pre-bundled dependencies, deterministic startup, and explicit degraded-mode behavior without live internet assumptions.

# Evidence
- Cloudflare’s Moltworker post highlights strong demand for self-hosted assistant infrastructure and secure isolated execution.
- Broader 2026 self-hosted/air-gapped tutorials emphasize offline model/package transfer and strict network boundaries.
- Enterprise buyers increasingly evaluate agent frameworks on operational posture (offline survivability, deterministic bootstrap, and security controls), not just model quality.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon is local-first and self-hostable, but lacks a documented/packaged "air-gapped profile" (artifact bundle + offline bootstrap checklist + degraded runtime policy).
  - No single control-plane surface advertises readiness status for offline-required capabilities.
  - Operator workflow for disconnected upgrades remains fragmented.

# Value Assessment
- Community demand: **M**
- Strategic fit: **H**
- Implementation complexity: **L**

# Recommendation
**investigate** — High strategic leverage for enterprise/self-hosted credibility; start with docs+diagnostics profile before deeper runtime changes.
