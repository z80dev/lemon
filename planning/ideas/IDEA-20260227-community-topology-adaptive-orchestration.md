---
id: IDEA-20260227-community-topology-adaptive-orchestration
title: [Industry] Topology-Adaptive Multi-Agent Orchestration Policies
source: industry
source_url: https://arxiv.org/abs/2602.16873
discovered: 2026-02-27
status: proposed
---

# Description
Emerging research and practitioner reports suggest agent-system performance increasingly depends on **orchestration topology selection** (parallel vs sequential vs hierarchical vs hybrid) per task, not only model choice.

# Evidence
- AdaptOrch (arXiv 2602.16873) reports 12–23% gains from task-adaptive topology routing over static single-topology baselines.
- AWS agent-evaluation guidance emphasizes evaluating tool-selection and multi-step orchestration behavior at system level, not just single-model outcomes.
  - https://aws.amazon.com/blogs/machine-learning/evaluating-ai-agents-real-world-lessons-from-building-agentic-systems-at-amazon/

# Lemon Status
- Current state: **partial**
- Gap analysis:
  - Lemon supports rich async patterns (`task`, `agent`, `join wait_all/wait_any`, queue modes), but topology decisions are largely caller-chosen/manual.
  - Missing: explicit policy layer that auto-selects orchestration topology from task attributes, dependency shape, and historical success metrics.

# Value Assessment
- Community demand: **M**
- Strategic fit: **H**
- Implementation complexity: **L**

# Recommendation
**investigate** — High strategic upside for Lemon’s multi-agent positioning; start with policy experiments over existing primitives before adding new runtime types.
