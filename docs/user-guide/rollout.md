# Feature Flag Rollout & Rollback Guide

This document covers the `routing_feedback` and `skill_synthesis_drafts`
feature flags: what states they accept, their shipped defaults, and the
rollback procedure if problems arise.

> **History:** these two flags previously shipped as `"opt-in"` behind a
> quantitative graduation gate (`LemonRouter.RolloutGate`). Both features were
> promoted to `"default-on"` by decision on 2026-08-14 and the gate machinery
> was removed. `routing_feedback` returned to off by default in 2026-11, after
> its history was found to override a changed `[defaults] model`; see
> [Adaptive Behavior](adaptive.md#how-it-influences-routing).

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
| `"default-on"` | Feature is enabled unless the operator disables it. `"on"` is accepted as an alias. |

**Shipped defaults:**

```toml
[features]
session_search         = "default-on"  # durable memory ingest/search kill switch
routing_feedback       = "off"         # task fingerprinting + routing feedback (enable with "on")
skill_synthesis_drafts = "default-on"  # scheduled skill-draft generation
```

`session_search` and `skill_synthesis_drafts` are on out of the box and their
flags are operator kill switches; `routing_feedback` must be enabled.

---

## Enabling or Disabling a Feature (Operator)

1. Set the feature in the global `config.toml`:

```toml
[features]
routing_feedback       = "on"
skill_synthesis_drafts = "off"
```

   or set the environment variable for the Lemon process (the environment
   overrides TOML):

```bash
export LEMON_FEATURE_ROUTING_FEEDBACK=on
export LEMON_FEATURE_SKILL_SYNTHESIS_DRAFTS=off
```

2. Restart Lemon (`lemon restart`) so the running process picks it up.

3. Confirm the feature is inactive:

```bash
lemon doctor
```

   With `skill_synthesis_drafts = "off"`, the `automation.skill_synthesis`
   check reports that the synthesis runner is inactive.

4. Before re-enabling, file an issue with: what the problem was, any logs,
   and what action triggered it.

---

## Observing the Learning Loop

There is no gate to evaluate anymore. To inspect what the loop is actually
doing (routing feedback records only while its flag is on):

- `mix lemon.feedback stats` / `list` / `inspect KEY` — routing feedback store
  totals, per-fingerprint success rates, and confidence annotations.
- `mix lemon.doctor` — the `automation.skill_synthesis` check reports
  synthesis pass counts (`candidates=… generated=… blocked=…`) and warns when
  the scheduled runner looks stalled (no pass for 3× its interval).
- Generated drafts are inert until promoted: review with
  `mix lemon.skill draft review <key>`, promote with
  `mix lemon.skill draft publish <key>` (or `lemon skill draft ...`).

---

## See Also

- [`docs/user-guide/adaptive.md`](adaptive.md) — using adaptive features day-to-day
- [`docs/user-guide/memory.md`](memory.md) — memory documents and session search
- `LemonCore.Config.Features` — flag states, defaults, and env-var overrides

*Last reviewed: 2026-11-23*
