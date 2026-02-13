# Repository Guidelines

## Project Structure & Module Organization
This is an Elixir umbrella project with multiple apps under `apps/`. Core runtime lives in `apps/agent_core`, `apps/ai`, and `apps/coding_agent`; infrastructure apps include `apps/lemon_gateway`, `apps/lemon_router`, `apps/lemon_channels`, and `apps/lemon_control_plane`. Shared primitives are in `apps/lemon_core`. UI clients are in `clients/` with a TUI in `clients/lemon-tui` and a web workspace in `clients/lemon-web` (workspaces `shared`, `server`, `web`). Root configs include `mix.exs`, `mix.lock`, `.formatter.exs`, and `config/config.exs`.

## Build, Test, and Development Commands
Elixir umbrella:
- `mix deps.get` installs Elixir dependencies.
- `mix compile` builds all umbrella apps.
- `mix test` runs all Elixir tests.
- `mix test apps/ai` runs tests for a single app (replace path as needed).
- `mix test --include integration` runs integration tests that depend on external CLIs.

TUI client:
- `cd clients/lemon-tui && npm install` installs dependencies.
- `npm run build` builds the TUI bundle.
- `npm run dev` runs TUI build in watch mode.

Web client:
- `cd clients/lemon-web && npm install` installs workspace deps.
- `npm run dev` starts the web server and frontend.
- `npm run build` builds shared/server/web packages.

Convenience:
- `./bin/lemon-dev` bootstraps deps, builds, and launches the TUI.

## Coding Style & Naming Conventions
- Format Elixir with `mix format` (umbrella uses `.formatter.exs`).
- Keep Elixir file names in `snake_case` and modules in `CamelCase`, following the existing `apps/<app>/lib/<app_name>/` layout.
- TypeScript follows workspace tooling: `eslint` for `clients/lemon-web/web` and `tsc`/`tsup` for builds.

## Testing Guidelines
- Elixir tests live under `apps/<app>/test` and use `*_test.exs` naming.
- Web/TUI tests use Vitest with `*.test.ts` or `*.test.tsx` naming.
- Prefer targeted app-level tests before running the full suite.

## Commit & Pull Request Guidelines
- Recent commit subjects are short, imperative, and sometimes use a `chore:` prefix. Follow that pattern (e.g., `Fix gateway timeout`, `chore: update docs`).
- PRs should include a brief summary, key design notes, and test coverage. Add screenshots or recordings for UI changes in `clients/`.

## Configuration & Secrets
- Project settings live in `.lemon/config.toml`; global settings in `~/.lemon/config.toml`.
- Prefer environment variables for API keys (e.g., `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`). Never commit secrets.

## Docs Navigation & Quality
- Treat this file as a navigation map, not a full manual. Durable implementation details belong in `docs/`.
- Start with `docs/README.md` for the docs index and canonical entry points.
- Keep docs metadata in `docs/catalog.exs` (`owner`, `last_reviewed`, `max_age_days`).
- Run `mix lemon.quality` after docs edits or umbrella dependency changes.
