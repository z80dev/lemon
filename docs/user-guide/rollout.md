# Feature Flag Rollout & Rollback Guide

This document covers the `routing_feedback` and `skill_synthesis_drafts`
feature flags: what states they accept, their shipped defaults, and the
rollback procedure if problems arise.

> **History:** these two flags previously shipped as `"opt-in"` behind a
> quantitative graduation gate (`LemonRouter.RolloutGate`). Both features were
> promoted to `"default-on"` by decision on 2026-08-14 and the gate machinery
> was removed; this guide now documents only states and rollback.

---

## Feature States

The promotion lifecycle is:

```
off ↔ default-on
```

| State | Meaning |
|---|---|
| `"off"` | Feature is disabled. Code is a no-op. |
| `"opt-in"` | Legacy state: behaves like `"off"` unless the caller explicitly opts in. Still parsed for configs written before the 2026-08-14 promotion. |
| `"default-on"` | Feature is enabled unless the operator disables it. |

**Shipped defaults:**

```toml
[features]
session_search         = "default-on"  # memory ingest + session_search/search_memory tools
routing_feedback       = "default-on"  # task fingerprinting + routing feedback recording
skill_synthesis_drafts = "default-on"  # scheduled skill-draft generation
```

All three are on out of the box; each exists as an operator kill switch.

---

## Disabling a Feature (Operator)

To turn a feature off:

```toml
[features]
routing_feedback       = "off"
skill_synthesis_drafts = "off"
```

Or without touching config (no restart needed for env vars):

```bash
export LEMON_FEATURE_ROUTING_FEEDBACK=off
export LEMON_FEATURE_SKILL_SYNTHESIS_DRAFTS=off
```

3. Confirm the feature is inactive:

```bash
mix lemon.doctor
```

4. Before re-enabling, file an issue with: what the problem was, any logs,
   and what action triggered it.

---

## Observing the Learning Loop

There is no gate to evaluate anymore — the flags are on. To inspect what the
loop is actually doing:

- `mix lemon.feedback stats` / `list` / `inspect KEY` — routing feedback store
  totals, per-fingerprint success rates, and confidence annotations.
- `mix lemon.doctor` — the `automation.skill_synthesis` check reports
  synthesis pass counts (`candidates=… generated=… blocked=…`) and warns when
  the scheduled runner looks stalled (no pass for 3× its interval).
- Generated drafts are inert until promoted: review with
  `mix lemon.skill draft review <key>`, promote with
  `mix lemon.skill draft promote <key>`.

---

## See Also

- [`docs/user-guide/adaptive.md`](adaptive.md) — using adaptive features day-to-day
- [`docs/user-guide/memory.md`](memory.md) — memory documents and session search
- `LemonCore.Config.Features` — flag states, defaults, and env-var overrides

*Last reviewed: 2026-08-14*
