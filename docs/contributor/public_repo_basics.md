# Public Repo Basics

This document covers the conventions every contributor needs to know when
working in this repository. The authoritative contributor guide is the root
[AGENTS.md](../../AGENTS.md); app-specific invariants live in each
`apps/<app>/AGENTS.md`.

## Prerequisites

- Elixir 1.19.5+ and Erlang/OTP 28.5+ (pinned in `.tool-versions`)
- A C toolchain (`cc`/`gcc` + `make`); the SQLite store compiles a native NIF
- Bun 1.3.14+ (for `clients/tui`)
- Node.js 24 LTS+ (for `clients/lemon-browser-node` and the `docs/` site)
- At least one configured provider for manual runs; `./bin/lemon setup` writes
  `~/.lemon/config.toml` and stores credentials in the encrypted secret store

## Development setup

```bash
# Install Elixir dependencies and compile
mix deps.get
mix compile

# First-run setup and environment check
./bin/lemon setup
./bin/lemon doctor

# Install TUI dependencies
cd clients/tui && bun install
```

## Running locally

```bash
# Interactive terminal (TUI); starts a background runtime if none is healthy
./bin/lemon

# Explicit foreground runtime, or a managed background one
./bin/lemon start
./bin/lemon daemon

# TUI attached to a shared runtime (boots and owns one if none is up)
./bin/lemon-tui

# Messaging runtime only (gateway, router, channels) from source
./bin/lemon-gateway
```

`./bin/lemon --help` lists the remaining commands. Source and packaged runtimes
share `LemonCli.CommandRegistry`; see the [CLI guide](../user-guide/cli.md).

## Running tests

Run Elixir checks from the umbrella root, never from `apps/<app>`: the umbrella
suites share one BEAM. `scripts/test` is the canonical runner and CI uses the
same lanes (see [testing](../testing.md)):

```bash
scripts/test help                          # list lanes
scripts/test premerge                      # changed-file checks + affected tests
scripts/test fast                          # warnings-as-errors compile + ExUnit (no integration)
scripts/test quality                       # format, credo, guards, docs links, architecture
scripts/test clients                       # TUI and browser-node checks
scripts/test path apps/lemon_core/test --seed 1   # one path, pass-through to mix test
```

For the TUI alone: `cd clients/tui && bun run check && bun run lint && bun test`.
Use `mix format` on changed Elixir files. Do not run overlapping umbrella
builds from concurrent workers.

## Code ownership

See [ownership](ownership.md) for the lane-to-directory mapping and the
CODEOWNERS rules.

## Branching and PRs

- Branch off `main` for all work. Use a separate git worktree under
  `.worktrees/` for each concurrent editing task.
- Branch names: `<type>/<short-description>`, e.g. `feat/session-search`.
- PRs require approval from the owners listed in `CODEOWNERS`.
- Cross-cutting changes (e.g. `mix.exs`, shared schemas) require `@z80` sign-off.
- `scripts/test quality` must be green, including `mix lemon.quality`
  ([architecture boundaries](../architecture_boundaries.md)).
- Update the canonical documentation for changed behavior and the relevant
  changelog for user-visible changes; do not copy the change into root/app
  guides unless an operational invariant changed. Build the site with
  `npm --prefix docs run build`; `scripts/verify_docs_site` checks the built
  site's internal links.

## Commit style

This repo uses **Conventional Commits**:

```
<type>(<scope>): <short description>

[optional body]
```

Common types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.

Scope should be the app name or domain: `lemon_core`, `lemon_skills`,
`lemon_agent`, `config`, `gateway`, etc.

## Feature flags

New non-trivial behaviour must be gated behind a flag in `[features]` (see
[config reference](../config.md)). Do not introduce ad-hoc `System.get_env`
checks for features — call `LemonCore.Config.Features.enabled?/2`.

## File ownership rule

New files inherit the owner of their nearest directory entry in
`.github/CODEOWNERS`. If your new file falls outside any existing glob, add
an explicit entry before the PR merges. See [ownership](ownership.md) for
details.
