# Migrating From Hermes

Lemon includes a focused Hermes import path for moving user-owned data from an
existing Hermes home into a Lemon home. The migration is intentionally
preview-first: inspect the report, resolve conflicts, then apply.

## Command

The command works in packaged installs and source checkouts. From a source
checkout, prefix the examples with `./bin/`:

```bash
lemon migrate hermes audit
lemon migrate hermes --dry-run
lemon migrate hermes --yes
./bin/lemon migrate hermes audit
./bin/lemon migrate hermes --dry-run
./bin/lemon migrate hermes --yes
```

Common options:

| Option | Purpose |
|---|---|
| `--source PATH` | Hermes home. Defaults to `$HERMES_HOME`, then `~/.hermes`. |
| `--target PATH` | Lemon home. Defaults to `~/.lemon`. |
| `--workspace-dir PATH` | Lemon assistant workspace. Defaults to `<target>/agent/workspace`. |
| `--preset user-data` | Import user data. This is the default. |
| `--preset full --migrate-secrets` | Include the allowlisted secret import path. |
| `--overwrite` | Replace conflicting target files. Existing files are copied into the migration backup area first. |
| `--skill-conflict skip` | Treat an existing skill folder as a conflict. This is the default. |
| `--skill-conflict rename` | Import conflicting skills as `<name>-hermes-import`. |
| `--no-backup` | Skip the pre-migration zip backup. |

Use `lemon migrate hermes audit --json` when you need a machine-readable
compatibility report for automation or support review. The audit is read-only
and reports each known Hermes surface as `compatible`, `gated`, `partial`,
`unsupported`, `missing`, or `error`.

The command always builds a preview before applying. Without `--yes`, it prompts
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
| `$HERMES_HOME/honcho.json` or `~/.honcho/config.json` | Supported settings in `[honcho]`; API key in Lemon encrypted secrets with `--preset full --migrate-secrets` |
| `.env` allowlisted secrets | Lemon encrypted secrets, only with `--migrate-secrets` |
| `state.db` sessions/messages | Searchable Lemon memory documents in `<target>/store/memory.sqlite3` |
| Known unmapped files | Archived under `<target>/migration/hermes/<timestamp>/archive/` for manual review |

Imported Hermes sessions become durable recall records. They are searchable via
Lemon memory tools, but they are not exact replay/resume records for the old
Hermes runtime.

## Honcho Configuration

The importer selects `<source>/honcho.json` if present, otherwise
`~/.honcho/config.json`. The profile-local file wins as a whole; it does not
inherit missing fields or credentials from the global file. A malformed local
file is an error, not permission to import a different profile's global settings.
Honcho config is never copied into the plaintext migration archive.

Within the selected file, the active `hosts.<host>` block overrides top-level
values. The host comes from `HERMES_HONCHO_HOST` in the source `.env`, a named
`profiles/<name>` source (`hermes_<name>`), or `defaultHost` / `hermes` for the
default profile. Other host blocks are reported as `unsupported`, not imported.
Missing workspace and AI peer settings retain Hermes's host-name defaults.

| Hermes key | Lemon `[honcho]` key |
|---|---|
| `baseUrl` (`base_url`) | `base_url` |
| `environment`, `workspace` | `environment`, `workspace` |
| `peerName`, `aiPeer` | `user_peer`, `ai_peer` |
| `recallMode`, `sessionStrategy` | `recall_mode`, `session_strategy` |
| `contextTokens`, `contextCadence`, `dialecticCadence` | `context_tokens`, `context_cadence`, `dialectic_cadence` |
| `dialecticReasoningLevel`, `dialecticMaxChars` | `reasoning_level`, `dialectic_max_chars` |
| `messageMaxChars`, `saveMessages`, `observationMode`, `enabled` | `message_max_chars`, `save_messages`, `observation_mode`, `enabled` |
| `timeout` (`requestTimeout`), in seconds | `timeout_ms`, converted to milliseconds |
| `apiKey` | Encrypted `HONCHO_API_KEY` secret; config stores only `api_key_secret = "HONCHO_API_KEY"` |

The normal `user-data` preview includes supported non-secret settings. API keys
are reported as `gated` until both `--preset full` and `--migrate-secrets` are
supplied. Preview never writes config or secrets. Existing differing Honcho
settings, credential references, and an existing `HONCHO_API_KEY` secret are
conflicts unless `--overwrite` is set.

Unsupported keys (including `dialecticDepth`, `writeFrequency`, `pinUserPeer`,
`userPeerAliases`, granular observation and session overrides) and invalid values
appear as `unsupported` items in the preview; Lemon does not pretend to implement
their semantics. Null settings are left at Lemon defaults. Review this report
before enabling Honcho: retaining a workspace and peers preserves access to
server-side memory, but does not copy remote data or reproduce Hermes's session
IDs. The migration makes no Honcho network requests.

Restart Lemon to load the imported settings; environment and application-env
overrides still win. See [Honcho](honcho.md) for activation, remote costs and
privacy controls.

## Safety Model

Each apply writes a report directory:

```text
<target>/migration/hermes/<timestamp>/
  report.json
  summary.md
  backups/
  archive/
```

Before applying, the command also creates a zip backup at:

```text
<target>/backups/pre-hermes-migration-<timestamp>.zip
```

Secret values are never written to reports. The secret importer reads known
Hermes environment variable names and the selected Honcho `apiKey`, and writes
them through `LemonCore.Secrets`. If the local Lemon secrets master key is not
available, those items are reported as errors, no plaintext fallback or new
credential reference is written, and the rest of the migration continues.

## Current Gaps

The migration maps the compatible, high-value Hermes surfaces first. It does not
yet fully translate Hermes cron jobs, gateway bindings, provider pools, MCP
servers, plugin state, checkpoints, browser state, or exact run-history replay.
Those files are either skipped or archived for manual review so the migration
does not silently invent unsafe Lemon config.
