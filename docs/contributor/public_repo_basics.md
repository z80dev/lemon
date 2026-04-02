# Public Repo Basics

This document covers the conventions every contributor needs to know when
working in this repository.

## Prerequisites

- Elixir 1.19+ and Erlang/OTP 27+
- Node.js 20+ (for `clients/lemon-tui` and `clients/lemon-web`)
- A configured `~/.lemon/config.toml` with at least one provider API key

## Development setup

```bash
# Install Elixir dependencies
mix deps.get

# Install Node dependencies
cd clients/lemon-tui && npm install
cd clients/lemon-web && npm install
```

## Running locally

```bash
# Start the Lemon runtime in dev mode
./bin/lemon-dev

# Start the TUI client
cd clients/lemon-tui && npm start

# Start the gateway
./bin/lemon-gateway
```

## Running tests

```bash
# All Elixir tests
mix test

# A specific app
mix test apps/lemon_core

# Node/TUI tests
cd clients/lemon-tui && npm test
```

## Code ownership

See `docs/contributor/ownership.md` for the directory-to-owner mapping and
the CODEOWNERS rules.

## Branching and PRs

- Branch off `main` for all work.
- Branch names: `<type>/<short-description>`, e.g. `feat/session-search`.
- PRs require approval from the owners listed in `CODEOWNERS`.
- Cross-cutting changes (e.g. `mix.exs`, shared schemas) require `@z80` sign-off.

## Commit style

This repo uses **Conventional Commits**:

```
<type>(<scope>): <short description>

[optional body]
```

Common types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`.

Scope should be the app name or domain: `lemon_core`, `lemon_skills`,
`agent_core`, `config`, `gateway`, etc.

## Feature flags

New behaviour that spans multiple milestones must be gated behind a feature
flag in `[features]` (see `docs/config.md`).  Do not introduce ad-hoc
`System.get_env` checks for features — use `LemonCore.Config.Features`.

## File ownership rule

New files inherit the owner of their nearest directory entry in
`.github/CODEOWNERS`.  If your new file falls outside any existing glob, add
an explicit entry before the PR merges.  See `docs/contributor/ownership.md`
for details.
