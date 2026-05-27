# Migrating From Hermes

Lemon includes a focused Hermes import path for moving user-owned data from an
existing Hermes home into a Lemon home. The migration is intentionally
preview-first: inspect the report, resolve conflicts, then apply.

## Command

From the Lemon repo:

```bash
mix lemon.hermes.audit
mix lemon.hermes.migrate --dry-run
mix lemon.hermes.migrate --yes
```

Common options:

| Option | Purpose |
|---|---|
| `--source PATH` | Hermes home. Defaults to `~/.hermes`. |
| `--target PATH` | Lemon home. Defaults to `~/.lemon`. |
| `--workspace-dir PATH` | Lemon assistant workspace. Defaults to `<target>/agent/workspace`. |
| `--preset user-data` | Import user data. This is the default. |
| `--preset full --migrate-secrets` | Include the allowlisted secret import path. |
| `--overwrite` | Replace conflicting target files. Existing files are copied into the migration backup area first. |
| `--skill-conflict skip` | Treat an existing skill folder as a conflict. This is the default. |
| `--skill-conflict rename` | Import conflicting skills as `<name>-hermes-import`. |
| `--no-backup` | Skip the pre-migration zip backup. |

Use `mix lemon.hermes.audit --json` when you need a machine-readable
compatibility report for automation or support review. The audit is read-only
and reports each known Hermes surface as `compatible`, `gated`, `partial`,
`unsupported`, `missing`, or `error`.

The task always builds a preview before applying. Without `--yes`, it prompts
before writing. If conflicts are present, it refuses to apply unless
`--overwrite` is set.

## What Imports

| Hermes data | Lemon destination |
|---|---|
| `SOUL.md` | `<target>/agent/workspace/SOUL.md` |
| `memories/MEMORY.md` | Compact `<target>/agent/workspace/MEMORY.md`; overflow goes to `memory/topics/hermes-imported-memory.md` |
| `memories/USER.md` | Compact `<target>/agent/workspace/USER.md`; overflow goes to `memory/topics/hermes-imported-user_profile.md` |
| `skills/*/SKILL.md` | `<target>/agent/skill/<skill-name>/SKILL.md` |
| `config.yaml` model/provider base URLs | Compatible `[defaults]` and `[providers.*]` entries in `<target>/config.toml` |
| `.env` allowlisted secrets | Lemon encrypted secrets, only with `--migrate-secrets` |
| `state.db` sessions/messages | Searchable Lemon memory documents in `<target>/store/memory.sqlite3` |
| Known unmapped files | Archived under `<target>/migration/hermes/<timestamp>/archive/` for manual review |

Imported Hermes sessions become durable recall records. They are searchable via
Lemon memory tools, but they are not exact replay/resume records for the old
Hermes runtime.

## Safety Model

Each apply writes a report directory:

```text
<target>/migration/hermes/<timestamp>/
  report.json
  summary.md
  backups/
  archive/
```

Before applying, the Mix task also creates a zip backup at:

```text
<target>/backups/pre-hermes-migration-<timestamp>.zip
```

Secret values are never written to reports. The secret importer only reads known
Hermes environment variable names and writes them through `LemonCore.Secrets`.
If the local Lemon secrets master key is not available, those items are reported
as errors and the rest of the migration continues.

## Current Gaps

The migration maps the compatible, high-value Hermes surfaces first. It does not
yet fully translate Hermes cron jobs, gateway bindings, provider pools, MCP
servers, plugin state, checkpoints, browser state, or exact run-history replay.
Those files are either skipped or archived for manual review so the migration
does not silently invent unsafe Lemon config.
