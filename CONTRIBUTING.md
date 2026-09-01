# Contributing to Lemon

Thank you for your interest in contributing. Lemon is a BEAM-native platform for
building agents, and the parts that are easiest to extend — channels, engines,
storage, memory — are the parts we most want contributions to. This guide gets
you from a clone to a merged extension.

If you only read one section, read [Your first contribution](#your-first-contribution).

## Before You Start

1. **Run `mix lemon.doctor`** — ensures your environment is set up correctly.
2. **Read `docs/contributor/public_repo_basics.md`** — branching, commit style, feature flags.
3. **Read `docs/contributor/ownership.md`** — code ownership lanes and CODEOWNERS rules.

## Prerequisites

- **Elixir 1.19 / OTP 28.** The umbrella dev build requires Elixir `~> 1.19` (pinned to
  1.19.5 / OTP 28.5 in `.tool-versions`, same as CI). The published packages declare a lower
  `~> 1.15` floor for *consumers*, but building this repo needs 1.19 — 15 of the umbrella apps
  require it, so an older Elixir will fail at compile.
- **A version manager** (`asdf` or `mise`) is the easy way to get that toolchain; the Quick Start
  assumes one is installed. Or install Elixir 1.19.5 / OTP 28 directly.
- **A C toolchain** (`cc`/`gcc` + `make`). The SQLite-backed store compiles `exqlite`'s native
  NIF from C source, so `mix compile` needs a working compiler — `build-essential` on Debian/Ubuntu,
  `base-devel` on Arch, Xcode command-line tools on macOS.

A clean checkout to a green `mix lemon.doctor` is about 2-3 minutes on a warm Hex cache (a
first-ever `mix deps.get` downloads ~73 packages, so budget a little more cold).

## Quick Start

```bash
git clone https://github.com/z80dev/lemon.git
cd lemon
asdf install   # or `mise install` — toolchain is pinned in .tool-versions (Elixir 1.19.5 / OTP 28.5, same as CI)
mix deps.get && mix compile
mix lemon.doctor
```

Full setup: [`docs/user-guide/setup.md`](docs/user-guide/setup.md)

## Development

```bash
scripts/test fast                 # compile with warnings as errors + ExUnit excluding integration
scripts/test path apps/lemon_core/test
scripts/test quality              # lint + architecture boundaries + doc freshness
```

`scripts/test quality` runs the same `mix lemon.quality` lane CI runs, and it is
the gate most PRs need to pass. See [`docs/testing.md`](docs/testing.md) for the
canonical local test lanes and how they map to CI.

## Your first contribution

The best first contribution to Lemon is **a new channel adapter** — a Slack
adapter, an SMS provider, an internal chat bridge. It touches one well-defined
behaviour, it ships with a ready-made compliance suite, and it can live in this
repo or in your own. Here is the whole on-ramp:

1. **Scaffold a project** with the generator, so you have a running agent to
   attach a channel to:

   ```bash
   cd installer && MIX_ENV=prod mix archive.build
   mix archive.install lemon_new-0.1.0.ez
   mix lemon.new my_agent
   ```

2. **Follow the guide.** [Add a channel](docs/getting-started/add-a-channel.md)
   walks from the console loop the generator gives you to a registered
   `LemonChannels.Plugin`, callback by callback. Its companions —
   [Build your first agent](docs/getting-started/build-your-first-agent.md),
   [Add a tool](docs/getting-started/add-a-tool.md), and
   [Persist memory](docs/getting-started/persist-memory.md) — cover the
   neighbouring extension points.

3. **Prove it with the contract kit** (below). A channel adapter that passes
   `LemonPlatformTest.PluginCase` is a channel adapter we can review quickly and
   merge with confidence.

You do not have to contribute the adapter back — the X integration lives in its
own package and registers itself at boot, and yours can too. But if it is
general-purpose, open a PR; it is exactly the contribution this project is shaped
to receive.

## Extension points

Every extension point is a behaviour with a published compliance suite in the
`lemon_platform_test` kit. Implement the behaviour, then run the matching case
against your module — the suite is the specification in executable form, so a
green run is most of what a reviewer needs.

| You want to add | Implement | Compliance suite | Guide |
|-----------------|-----------|------------------|-------|
| A channel (Slack, SMS, chat bridge) | [`LemonChannels.Plugin`](apps/lemon_channels/lib/lemon_channels/plugin.ex) | `LemonPlatformTest.PluginCase` | [Add a channel](docs/getting-started/add-a-channel.md) |
| A storage backend | [`LemonCore.Store.Backend`](apps/lemon_core/lib/lemon_core/store/backend.ex) | `LemonPlatformTest.BackendCase` | — |
| A memory provider | [`LemonMemory.Provider`](apps/lemon_memory/lib/lemon_memory/provider.ex) | `LemonPlatformTest.ProviderCase` | [Persist memory](docs/getting-started/persist-memory.md) |

Each behaviour's moduledoc is the contract in prose; each case's moduledoc
explains what it exercises and why. The built-in implementations are the worked
examples — Telegram/Discord/email for channels, `EtsBackend`/`SqliteBackend` for
storage, `LemonMemory.Providers.Local` for memory.

## Running the contract kit

Add `lemon_platform_test` as a test-only dependency and write a one-file test
that hands your module to the matching case. The suites are parameterized `use`
macros; the options tell the suite what to run and which probes are safe.

```elixir
# test/my_agent/slack_channel_test.exs
defmodule MyAgent.SlackChannelComplianceTest do
  use LemonPlatformTest.PluginCase,
    async: false,
    adapter: MyAgent.SlackChannel,
    deliver_probe: {__MODULE__, :unsupported_payload},
    inbound_fixtures: {__MODULE__, :updates}

  # `:deliver_probe` has no default on purpose: only you know which payload
  # cannot reach a real user. A kind your adapter does not support is the right
  # choice — a compliance suite that posts to a live workspace is worse than none.
  def unsupported_payload(_context), do: # ... an OutboundPayload your adapter rejects
  def updates(_context), do: # ... raw inbound fixtures your normalize_inbound/1 accepts
end
```

```bash
mix test test/my_agent/slack_channel_test.exs
```

The other suites follow the same shape:

```elixir
use LemonPlatformTest.BackendCase,        async: true, backend: MyApp.MyBackend
use LemonPlatformTest.ProviderCase,       async: false, provider: MyApp.MyProvider
```

Look at `apps/lemon_platform_test/test/compliance/` for a runnable example of
each — those are the platform's own implementations held to the same suite you
will run.

## Commit Style (Conventional Commits)

```
<type>(<scope>): <short description>
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`
Scope: app name or domain (`lemon_core`, `lemon_skills`, `config`, etc.)

## Feature Flags

All new non-trivial features must be gated behind a flag in `[features]`.
Use `LemonCore.Config.Features.enabled?/2` — not `System.get_env`.

## Skills and Generated Artifacts

- Skills live in `~/.lemon/agent/skills/` or `<project>/.lemon/skills/`
- Auto-generated skill drafts must go through human review before promotion
- Do not commit skill draft files or personal `~/.lemon/` content

## Pull Requests

- Branch from `main`; branch name: `<type>/<short-description>`
- PRs require approval from the CODEOWNERS of affected files
- Cross-cutting changes (`mix.exs`, shared schemas) require `@z80` sign-off
- `mix lemon.quality` must be green (lint + architecture boundaries + doc freshness)
- Register any new docs files under `docs/` in `docs/catalog.exs`
- **Changed a published package's `lib/`?** Add an entry to that package's
  `CHANGELOG.md` in the same PR — the change is visible to third parties who
  installed it from Hex. A CI job annotates PRs that miss this (advisory, per
  `docs/platform-split.md` §4.4); it does not block the merge, but reviewers do.

The [pull request template](.github/pull_request_template.md) has the full
checklist.

## Reporting Security Issues

See [SECURITY.md](SECURITY.md).

## License

By contributing, you agree your contributions will be licensed under the MIT License.

## Working with coding agents on this repo

These conventions apply when several people or agents work on the tree at once.

### Parallel Work & Git Worktrees

When working on multiple tasks in parallel (either as the same agent or multiple agents), **use git worktrees to avoid file editing conflicts**.
Store all worktrees under `.worktrees/` in the repository root.

#### Workflow:

1. **Create a worktree for each parallel task:**
   ```bash
   mkdir -p .worktrees
   git worktree add .worktrees/task-name -b task-name
   cd .worktrees/task-name
   ```

2. **Work in isolation** — Each worktree is an independent working directory backed by the same repo:
   ```bash
   git status
   ```

3. **Clean up when complete** — After the branch is merged/closed, remove the worktree:
   ```bash
   cd /path/to/main/lemon
   git worktree remove .worktrees/task-name
   git branch -d task-name
   ```

#### Why git Worktrees?

- **No file editing conflicts** — Multiple agents can edit different files simultaneously without stepping on each other
- **Clean build contexts** — Each worktree maintains separate `_build/` and `deps/` as needed
- **Easy cleanup** — Remove worktrees when done without affecting the main checkout

#### Golden Rule:

> **Never have multiple agents editing the same working directory simultaneously.** Always use separate worktrees for parallel tasks.

---

### Agent Team Composition

When spawning agents for parallel work, **match the agent tier to the task complexity**. Don't use Opus for investigation or Sonnet for architectural decisions.

#### Role Model

| Role | Internal Model | External Model | Typical Tasks |
|------|---------------|----------------|---------------|
| Junior/Mid Dev | Sonnet | Kimi | Investigation, plan file creation, test running, config cleanup, doc updates, dependency audits, simple refactors |
| Senior Dev | Opus | — | Complex refactoring, architectural extraction, correctness-critical code, multi-module decomposition |
| Staff Engineer | Codex (MCP) | — | Plan ownership/review, architectural oversight, cross-cutting design decisions, final validation |

#### Guidelines

- **Default to the lowest tier that can do the job** — Use Sonnet for exploration and investigation. Only escalate to Opus when the task involves complex logic, cross-module refactoring, or correctness-critical code.
- **Codex owns plans** — Matches the existing `owner: codex` / `reviewer: codex` convention in the planning system. Codex reviews architectural decisions and validates decomposition strategies.
- **Escalation pattern**: Sonnet investigates → Opus implements → Codex reviews. Not every task needs all three tiers.
- **Kimi for external/security**: Security audits, pre-push hooks, and external review tasks (already established in the pre-push hook workflow).
- **Planning metadata**: `owner:` and `reviewer:` fields in plan YAML front matter should reference these roles (e.g., `owner: codex`, `reviewer: codex`).

#### Spawning Examples

```bash
# Sonnet for investigation (junior/mid)
# Use model: "sonnet" in Task tool or --model sonnet in CLI

# Opus for complex implementation (senior)
# Use model: "opus" in Task tool or default CLI model

# Codex for plan review (staff)
# Use mcp__codex__codex tool with architectural review prompt

# Kimi for security audit (external)
# Use kimi CLI runner for pre-push or security review
```

---
