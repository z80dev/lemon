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
| `--preset full --migrate-secrets` | Include the allowlisted secret import path. Both flags are required; `--migrate-secrets` alone under the default preset imports no secrets. |
| `--overwrite` | Replace conflicting target files. Existing files are copied into the migration backup area first. |
| `--skill-conflict skip` | Treat an existing skill folder as a conflict. This is the default. |
| `--skill-conflict rename` | Import conflicting skills as `<name>-hermes-import`. |
| `--include-skill-assets` | Also import unrecognised skill files inside the skill bundle layout (`references/`, `templates/`, `scripts/`, `assets/`), after you have reviewed the `gated` list. |
| `--no-backup` | Skip the pre-migration `lemon backup` bundle. |
| `--dry-run` | Print the preview and exit without writing. |
| `--yes` | Apply without the confirmation prompt (conflicts still require `--overwrite`). |

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
| `skills/*/` | `<target>/agent/skill/<skill-name>/`: `SKILL.md` and recognised text files only, installed through the skill audit and recorded as `pending` (see [Credential handling](#credential-handling)) |
| `config.yaml` model/provider base URLs | Compatible `[defaults]` and `[providers.*]` entries in `<target>/config.toml` |
| `$HERMES_HOME/honcho.json` or `~/.honcho/config.json` | Supported settings in `[honcho]`; API key in Lemon encrypted secrets with `--preset full --migrate-secrets` |
| `.env` allowlisted secrets | Lemon encrypted secrets, only with `--preset full --migrate-secrets`. An existing Lemon secret with the same name is always a conflict; a different existing credential reference in `config.toml` is a conflict unless `--overwrite` is set. |
| `state.db` sessions/messages | Searchable Lemon memory documents in `<target>/store/memory.sqlite3` |
| `config.yaml` `model` and provider `base_url` values, and `cron/` job schedules | Archived under `<target>/migration/hermes/<timestamp>/archive/` (`config.yaml`, `cron.json`) for manual review; see [Credential handling](#credential-handling) |
| `auth.json` | Never copied; reported as `gated`. Import supported credentials with `--preset full --migrate-secrets` |

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
| `pinUserPeer` (`pinPeerName`) | `pin_user_peer` |
| `userPeerAliases`, `runtimePeerPrefix` | `user_peer_aliases`, `runtime_peer_prefix` |
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

Gateway identity settings are imported without collapsing their scope: the
selected host's alias map replaces the root map, and canonical `pinUserPeer`
wins over legacy `pinPeerName` within the same scope. Alias maps preserve
runtime IDs as quoted TOML keys and require valid Honcho peer names. Empty maps
and an empty prefix remain explicit empty values. These settings use the same
preview and overwrite policy as other Honcho config.

Omitted `pinUserPeer` stays at Lemon's default `false`: non-owner channel senders
receive their own platform-qualified peers even with an empty prefix. A trusted
channel owner retains `user_peer`; use `pin_user_peer = true` or explicit aliases
to pool senders or retain a particular person's historical peer. See
[gateway identity mapping](honcho.md#gateway-identity-mapping).

Unsupported keys (including `dialecticDepth`, `writeFrequency`, granular
observation and session overrides) and invalid values
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
  journal.jsonl
  backups/
  archive/
```

`lemon backup` never includes `<target>/migration/`, even with
`--include-credentials`.

### Offline operation

Apply and rollback run offline. They refuse while a launcher-managed Lemon
runtime uses the target and hold the same lifecycle locks as
`lemon backup restore` for the whole operation, so no runtime can start and no
restore or other migration can run meanwhile. Stop Lemon (`lemon stop`) first.
Other tools that edit `config.toml` or the secret store directly while a
migration runs are not coordinated with; do not run them concurrently.

Before applying to an existing Lemon home, the command creates a standard
`lemon backup` bundle under `<target>/backups/` inside that lock. It follows the
backup contract (credential material such as `secrets_master_key`, `env` and
`cookie` is excluded; SQLite databases are consistent snapshots) and can be
checked with `lemon backup verify <path>`. The bundle does not contain the
secrets master key, so keep the existing key (Keychain,
`LEMON_SECRETS_MASTER_KEY` or key file) in place.

### Rollback

`journal.jsonl` records each plain-file destination before its first change.
Undo an applied migration with:

```bash
lemon migrate hermes rollback <target>/migration/hermes/<timestamp>
```

Rollback removes files and directories the migration created, restores plain
files it modified from `backups/`, and deletes secrets it created. Limits:

- SQLite databases are never copied. If the migration created
  `store/memory.sqlite3`, rollback removes it (and its sidecars) while holding
  the offline lock. If session memory was added to an existing database, the
  item is reported as `manual`: restore the pre-migration bundle with
  `lemon backup restore` to revert it.
- A created secret is deleted only from the same store (its physical database
  path is recorded) and only while it is still the exact value the migration
  stored. A secret changed afterwards is left untouched and reported as
  `manual`; a different active store is reported as `error`.
- Empty parent directories and the report directory are left in place.
- Changes made after the migration to the same files are discarded when those
  files are restored or removed. Roll back before further edits.
- While any `error` or `manual` item remains, rollback reports
  `"complete": false` and the command exits nonzero.

Config files are rewritten through a temp file inside a freshly created `0700`
sibling directory, set to mode `0600` (or the stricter existing mode), synced
and renamed into place; the directory is then removed. A rewritten
`config.toml` therefore ends up `0600`, and its new content is never readable
by other users while it is being written.

### Secrets

Secret values are never written to reports. The secret importer reads an
allowlist of Hermes `.env` names (`ANTHROPIC_API_KEY`, `OPENAI_API_KEY`,
`OPENAI_CODEX_API_KEY`, `OPENCODE_API_KEY`, `ZAI_API_KEY`, `MINIMAX_API_KEY`,
`TELEGRAM_BOT_TOKEN`, `DISCORD_BOT_TOKEN`, `ELEVENLABS_API_KEY`,
`DEEPGRAM_API_KEY`) and the selected Honcho `apiKey`, and writes
them through `LemonCore.Secrets`. Provider keys are referenced from
`[providers.<name>] api_key_secret`. If the local Lemon secrets master key is not
available, those items are reported as errors, no plaintext fallback or new
credential reference is written, and the rest of the migration continues.

- Migration only creates secrets that do not exist yet. An existing secret of
  the same name is a conflict and is never replaced, even with `--overwrite`;
  delete it with `lemon secrets delete NAME` first to import the Hermes value.
- A config reference is only written if it is unset or already names that
  secret, unless `--overwrite` is set.
- If the config update fails, the created secret is deleted again, but only if
  it is still the exact value just created. If that compensation fails, the
  item is reported as `error` saying the secret remains stored.
- Secret migration is refused (`gated`) unless the running secret store's
  physical database lies inside `--target`, is not reached through a symlink,
  and is present in the pre-migration backup bundle (so excluded directories
  such as `logs/` and `--no-backup` are refused too).

### Credential handling

- Skills: only `SKILL.md` and UTF-8 text files with a known source or document
  extension (`.md`, `.txt`, `.py`, `.sh`, `.js`, `.ts` and similar) under
  `references/`, `scripts/` or `templates/` are selected. Every other file,
  including dotfiles and any JSON, YAML or extensionless file, is reported as
  `gated` and not copied. After reviewing the listed files,
  `--include-skill-assets` also imports the ones inside the skill bundle
  layout (`references/`, `templates/`, `scripts/`, `assets/`; each is listed
  as `migrated`); files outside that layout, symlinks, hard-linked files,
  symlinked skill directories and special files are never read or imported.
  Imported text is not scanned for secrets.
- Selected skill files are staged in a private temporary directory outside
  every skill root and installed through the skill installer's audit: the
  exact staged file set is scanned, a skill the audit blocks is reported as
  `blocked` and not imported, and only the audited files are activated. An
  imported skill is recorded in `<target>/agent/skills.lock.json` with
  `source_kind: hermes`, `trust_level: community` and `audit_status: pending`,
  so Lemon's normal audit and approval pipeline still judges it before it is
  trusted: a pending skill is not loadable until you run
  `lemon skill audit <skill-key>` (add `--approve` to accept `warn` findings).
  The report and `summary.md` list each skill's audit status and verdict.
- `config.yaml` is archived reduced to `model` and provider `base_url` values;
  every other top-level section is reported by name as `gated`, never copied.
- URLs with userinfo, a query string or a fragment are never imported into
  `config.toml` or the archive, since they may embed credentials.
- `cron/` is archived as `cron.json` holding job ids, names, schedules,
  timezones and enabled flags only; commands, prompts and environment are not
  copied.
- Persona, memory, skill and session text is imported as written and is not
  scanned for embedded secrets; the report carries a `warning` reminding you to
  review it.

### Earlier migrations

Earlier Lemon versions copied `auth.json`, the full `config.yaml` and `cron/`
into `migration/hermes/<timestamp>/archive/`, and wrote
`backups/pre-hermes-migration-<timestamp>.zip` containing the whole Lemon home,
including the secrets master key. Audit, preview and apply list any such files
as `legacy_archive` warnings (paths only). Lemon does not delete them: review
them, delete them once you no longer need them, and rotate any credentials they
contained.

## Current Gaps

The migration maps the compatible, high-value Hermes surfaces first. It does not
yet fully translate Hermes cron jobs, gateway bindings, provider pools, MCP
servers, plugin state, checkpoints, browser state, or exact run-history replay.
Those files are either skipped or archived for manual review so the migration
does not silently invent unsafe Lemon config.
