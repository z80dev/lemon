# Code Ownership

This document describes how code ownership is organised in the Lemon
repository, how to read `.github/CODEOWNERS`, and the rules that apply
when adding new files. For what each app owns technically, see the guide
table in the root [AGENTS.md](../../AGENTS.md#ownership-and-app-guides).

## Ownership lanes

| Lane | Team alias | Covers |
|------|-----------|--------|
| **runtime** | `@lemon/runtime` | Boot, config, onboarding, doctor, update, gateway |
| **skills** | `@lemon/skills` | `lemon_skills` app and all skill-related tooling |
| **agent** | `@lemon/agent` | `coding_agent`, `lemon_agent`, `lemon_ai` apps |
| **memory** | `@lemon/memory` | `lemon_memory` app, Store and run stores, routing feedback, run outcomes |
| **client** | `@lemon/client` | `clients/tui`, `clients/lemon-browser-node` |
| **release** | `@lemon/release` | `scripts/`, `.github/workflows/` |
| **docs** | `@lemon/docs` | Everything under `docs/` |

> **Single-maintainer mode:** while the project is maintained by `@z80`
> alone, every lane alias resolves to `@z80`.  Replace individual entries
> in `CODEOWNERS` as contributors join each lane.

## Directory-to-owner mapping

```
/bin/**                                                 runtime
/config/**                                              runtime
/apps/lemon_core/lib/lemon_core/runtime/**              runtime
/apps/lemon_core/lib/lemon_core/config/**               runtime
/apps/lemon_cli/lib/lemon_cli/onboarding/**             runtime
/apps/lemon_core/lib/lemon_core/doctor/**               runtime
/apps/lemon_core/lib/lemon_core/update/**               runtime
/apps/lemon_gateway/**                                  runtime
/apps/lemon_core/lib/lemon_core/store.ex                memory
/apps/lemon_core/lib/lemon_core/store/**                memory
/apps/lemon_core/lib/lemon_core/run_store.ex            memory
/apps/lemon_core/lib/lemon_core/run_history_store.ex    memory
/apps/lemon_core/lib/lemon_core/run_outcome.ex          memory
/apps/lemon_core/lib/lemon_core/events/routing_feedback.ex  memory
/apps/lemon_memory/**                                   memory
/apps/lemon_router/lib/lemon_router/routing_feedback*   memory
/apps/lemon_skills/**                                   skills
/apps/coding_agent/**                                   agent
/apps/lemon_agent/**                                    agent
/apps/lemon_ai/**                                       agent
/clients/**                                             client
/scripts/**                                             release
/.github/workflows/**                                   release
/docs/**                                                docs
```

`/apps/lemon_router/**` and `/apps/lemon_control_plane/**` have explicit
entries but no named lane. Every other path (the remaining apps, `products/`,
`installer/`, root files) falls through to the root `*` entry, which
resolves to `@z80`. When two patterns match, the last one in the file wins,
so narrower entries sit after the broader globs that contain them.

## Cross-cutting files

Some files require review from multiple lanes because a change in one
affects another:

| File | Required reviewers |
|------|--------------------|
| `/mix.exs` | runtime, release |
| `/README.md` | docs, runtime |
| `/.github/CODEOWNERS` | release, runtime |
| `/apps/lemon_router/lib/lemon_router/model_selection.ex` | agent, memory |
| `/.github/workflows/**` | release, runtime |

## Escalation rules

1. **Within a lane** — the lane owner approves.
2. **Cross-lane** — all listed owners must approve before merge.
3. **Unowned or disputed file** — escalate to `@z80` (repo admin).
4. **Breaking schema changes** — always require `@z80` sign-off
   regardless of lane ownership.

## New-file policy

> **Rule:** A new file inherits ownership from the nearest directory entry
> in `.github/CODEOWNERS`.

Concretely:

- If you add `apps/lemon_core/lib/lemon_core/runtime/foo.ex`, it is
  automatically owned by the **runtime** lane — no CODEOWNERS change
  needed.
- If you add a file *outside* any existing directory glob (e.g. a new
  top-level app directory), you **must** add an explicit entry to
  `.github/CODEOWNERS` before the PR merges.
- If a file is legitimately cross-cutting, add it explicitly with all
  required owners listed on one line.

## Docs ownership

Docs ownership is recorded only in `CODEOWNERS`. When a docs contributor
assumes ownership of a file, add it there.
