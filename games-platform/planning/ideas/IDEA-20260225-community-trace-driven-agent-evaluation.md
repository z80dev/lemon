---
id: IDEA-20260225-community-trace-driven-agent-evaluation
title: [Community] Trace-Driven Agent Evaluation with Degradation Alerts and HITL Audits
source: industry
source_url: https://aws.amazon.com/blogs/machine-learning/evaluating-ai-agents-real-world-lessons-from-building-agentic-systems-at-amazon/
discovered: 2026-02-25
status: proposed
---

# Description
Industry practice is moving from single-model metrics to end-to-end **agent trace evaluation**: measuring tool selection quality, multi-step reasoning, error recovery, and continuous degradation detection with periodic human audits.

# Evidence
- AWS describes large-scale agent deployments requiring trace-based, framework-agnostic evaluation pipelines.
- The post emphasizes continuous quality monitoring, failure-mode analysis, and notification rules for performance drift.
- Human-in-the-loop audit loops are treated as a core requirement for trustworthy production agent systems.

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon has strong runtime telemetry, run history, and introspection surfaces.
  - ROADMAP already has a "structured benchmark harness" idea, but does not yet define a trace-scoring/evaluation framework with degradation alerting and scheduled HITL quality audits.
  - Opportunity: elevate existing observability into an evaluation product surface (scoring rubrics + automated drift detection + review workflows).

# Value Assessment
- Community demand: **M**
- Strategic fit: **H**
- Implementation complexity: **M**

# Recommendation
**investigate** — High strategic alignment with Lemon’s long-running agent goals; likely best as a staged effort building on existing introspection artifacts.
