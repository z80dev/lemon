# Adaptive Feature Rollout Guide

This document describes the promotion process for adaptive features
(`routing_feedback` and `skill_synthesis_drafts`), the measurable gates that
must pass before a feature is enabled by default, and the rollback procedure
if problems arise.

---

## Feature States

All adaptive features start at `:off`. The promotion lifecycle is:

```
off → opt-in → default-on
```

| State | Meaning |
|---|---|
| `"off"` | Feature is disabled. Code is a no-op. |
| `"opt-in"` | Feature is available but must be explicitly enabled. Canary/early adopter phase. |
| `"default-on"` | Feature is enabled unless the operator disables it. |

**Current state:**

```toml
[features]
routing_feedback       = "opt-in"   # not enabled by default until gates pass
skill_synthesis_drafts = "opt-in"   # not enabled by default until gates pass
```

---

## Enabling a Feature (Operator)

To opt in to an adaptive feature before it reaches `"default-on"`:

```toml
[features]
routing_feedback       = "default-on"
skill_synthesis_drafts = "default-on"
```

Restart the runtime after changing `~/.lemon/config.toml`.

Verify with `mix lemon.doctor` that the feature is active.

---

## Rollback Procedure

If an enabled feature causes problems, disable it immediately:

1. Edit `~/.lemon/config.toml`:
   ```toml
   [features]
   routing_feedback       = "off"
   skill_synthesis_drafts = "off"
   ```

2. Restart the runtime:
   ```bash
   ./bin/lemon-gateway
   # or for TUI
   ./bin/lemon-dev
   ```

3. Confirm the feature is inactive:
   ```bash
   mix lemon.doctor
   ```

4. File an issue before re-enabling. Include: what the problem was, any logs,
   and what action triggered the issue.

---

## Routing Feedback Gates

The `routing_feedback` feature is ready for `"default-on"` when all gates pass.
Gates are evaluated via `LemonCore.RolloutGate.evaluate_routing_from_store/2`.

| Gate | Threshold | What it measures |
|---|---|---|
| `min_sample_size` | 20 runs | Minimum recorded feedback entries |
| `min_success_rate` | 0.60 (60%) | Aggregate success rate across fingerprints |
| `max_failure_rate` | 0.20 (20%) | Aggregate non-success rate across fingerprints |

### How to check

```elixir
alias LemonCore.{RoutingFeedbackStore, RolloutGate}

{:ok, stats} = RoutingFeedbackStore.store_stats()
{:ok, fingerprints} = RoutingFeedbackStore.list_fingerprints()
RolloutGate.evaluate_routing_from_store(stats, fingerprints)
# => {:pass, [...]} or {:fail, [...]}
```

### What to watch for

- **Low sample size**: the system hasn't run enough tasks yet. Keep using it with
  `routing_feedback = "opt-in"` to accumulate data.
- **Low success rate**: the model selection is not improving outcomes. Check whether
  the wrong models are being tracked, or whether the baseline is naturally low for
  your use cases.
- **High failure rate**: too many runs are failing. Investigate the failure patterns
  via `mix lemon.feedback report` before promoting.

---

## Skill Synthesis Gates

The `skill_synthesis_drafts` feature is ready for `"default-on"` when all gates pass.
Gates are evaluated via `LemonCore.RolloutGate.evaluate_synthesis_from_run/1`.

| Gate | Threshold | What it measures |
|---|---|---|
| `min_candidates_processed` | 5 | Pipeline has processed at least 5 memory candidates |
| `max_draft_block_rate` | 0.50 (50%) | Fraction of candidates blocked by audit |
| `min_generated_rate` | 0.20 (20%) | Fraction of candidates that produce a stored draft |

### How to check

```elixir
alias LemonSkills.Synthesis.Pipeline
alias LemonCore.RolloutGate

{:ok, result} = Pipeline.run(:agent, "my-agent-id", max_docs: 50)
RolloutGate.evaluate_synthesis_from_run(result)
# => {:pass, [...]} or {:fail, [...]}
```

### What to watch for

- **High block rate**: the audit engine is blocking many candidates. This usually
  means the memory documents contain noisy or low-quality content. Review recent
  runs for patterns.
- **Low generation rate**: candidates are being selected but not producing drafts.
  Common causes: documents already have matching drafts (`:already_exists`), or
  `DraftStore.put/2` is failing.

---

## Promotion Checklist

Before setting a flag to `"default-on"` in the codebase:

- [ ] All gate checks return `{:pass, ...}` on representative data
- [ ] Feature has been running in `"opt-in"` mode for at least one week
- [ ] No open issues tagged with the feature's flag name
- [ ] `mix lemon.quality` passes
- [ ] Rollback procedure tested at least once on a development setup
- [ ] CHANGELOG.md updated

---

## See Also

- [`docs/user-guide/adaptive.md`](adaptive.md) — using adaptive features day-to-day
- [`docs/user-guide/memory.md`](memory.md) — memory documents and session search
- `LemonCore.RolloutGate` — module documentation and gate thresholds

*Last reviewed: 2026-03-16*
