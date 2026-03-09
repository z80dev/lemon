# Quality Harness

Lemon now uses a multi-layer quality harness:

1. Docs quality checks (ownership, freshness, broken local links)
2. Architecture boundary checks (direct umbrella dependency policy)
3. Coverage and compile gates (`mix test --cover`, Vitest coverage, warnings-as-errors)
4. Production dependency audits for shipped Node clients (`npm audit --omit=dev --audit-level=high`)
5. Coding eval harness (deterministic, statistical, and workflow checks)
6. Entropy cleanup scan/prune for `docs/agent-loop/runs`

## Commands

```bash
# Docs + architecture checks
mix lemon.quality
mix lemon.architecture.docs --check

# Umbrella test coverage
mix test --cover --exclude integration

# Coding eval harness
mix lemon.eval
mix lemon.eval --iterations 50

# Cleanup scan (dry-run)
mix lemon.cleanup

# Cleanup with deletion
mix lemon.cleanup --apply --retention-days 21
```

## Eval Classes

`mix lemon.eval` runs:

- `deterministic_contract`: required built-in tool surface is present with no duplicates
- `statistical_stability`: repeated tool-registry snapshots remain stable across N iterations
- `read_edit_workflow`: end-to-end read/edit/read tool workflow on a temp file

## CI Gate

Quality checks are wired in `.github/workflows/quality.yml` so pull requests fail when the quality harness fails.
The architecture dependency table in `docs/architecture_boundaries.md` is generated from the canonical policy in `LemonCore.Quality.ArchitecturePolicy`; refresh it with `mix lemon.architecture.docs`.

Current hard gates include:

- `mix compile --warnings-as-errors`
- `mix test --cover --exclude integration`
- Vitest coverage runs for `clients/lemon-web`, `clients/lemon-tui`, and `clients/lemon-browser-node`
- `npm audit --omit=dev --audit-level=high` for shipped Node clients
- `mix lemon.quality`, duplicate-test checks, and eval harness runs
