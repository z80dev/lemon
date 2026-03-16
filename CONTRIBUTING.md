# Contributing to Lemon

Thank you for your interest in contributing. This document covers the basics.

## Before You Start

1. **Run `mix lemon.doctor`** — ensures your environment is set up correctly.
2. **Read `docs/contributor/public_repo_basics.md`** — branching, commit style, feature flags.
3. **Read `docs/contributor/ownership.md`** — code ownership lanes and CODEOWNERS rules.

## Quick Start

```bash
git clone https://github.com/z80dev/lemon.git
cd lemon
mix deps.get && mix compile
mix lemon.doctor
```

Full setup: [`docs/user-guide/setup.md`](docs/user-guide/setup.md)

## Development

```bash
mix test                   # all tests
mix test apps/lemon_core   # one app
mix lemon.quality          # lint + architecture boundaries + doc freshness
```

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
- Register any new docs files in `docs/catalog.exs`

## Reporting Security Issues

See [SECURITY.md](SECURITY.md).

## License

By contributing, you agree your contributions will be licensed under the MIT License.
