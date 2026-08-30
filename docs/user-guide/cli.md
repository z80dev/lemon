# Lemon command-line reference

Lemon exposes the same Mix-free command families from an installed
`lemon_runtime_min` or `lemon_runtime_full` release and from a source checkout.
Use `lemon ...` after installation and `./bin/lemon ...` in the repository.

The runtime command boundary has stable exit codes:

- `0` means the command completed successfully;
- `1` means a safe operational or verification failure;
- `2` means the command or its arguments are invalid.

`--help`, `-h`, and `help` print command help without running the command body.
Commands that support `--json` write one JSON document to stdout on success
and one redacted JSON error document to stderr on operational failure. Invalid
arguments remain human-readable usage errors with exit code `2`.

## Runtime command families

| Family | Purpose |
| --- | --- |
| `setup` | Complete first-run configuration |
| `model` | Configure a model provider |
| `gateway` | Configure Telegram or Discord |
| `doctor` | Run diagnostics or create a support bundle |
| `config` | Validate or show resolved configuration |
| `secrets` | Manage encrypted credentials |
| `channels` | Inspect channel launch readiness |
| `providers` | Inspect provider readiness and manage routing |
| `blueprints` | Review and exactly confirm cataloged skill automation bundles |
| `profile` | Manage isolated specialist profiles |
| `backup` | Create, verify, list, or restore user-state backups |
| `context` | Preview or resolve bounded context references |
| `sessions` | Inspect and manage durable sessions |
| `completion` | Generate shell completion scripts |

The source and packaged launchers also expose commands specific to their own
runtime lifecycle. Run `lemon --help` or `./bin/lemon --help` for that exact
launcher. Completion generation detects the launcher, so it does not advertise
packaged daemon commands in a source checkout or source-only commands in an
installed release.

## Portable blueprints

`lemon blueprints` talks only to the authenticated local control plane. It
never accepts a filesystem root or path and never starts a scheduler in the
one-shot CLI VM. Installed releases start the daemon when needed; from a source
checkout, start `./bin/lemon --daemon` first.

```bash
lemon blueprints
lemon blueprints inspect daily-note
lemon blueprints validate daily-note --json
lemon blueprints daily-note --profile operator
lemon blueprints preview daily-note --profile operator --json
```

The bundle-ID shorthand is preview, not activation. These reads return only
the control plane's sanitized projections: IDs/names, content hashes and byte
counts, profile/session target, cron schedule/state, provenance, collision
actions, and cleanup flags. They omit absolute paths, skill bodies, prompt or
command text, and secret values.

Activation requires the exact 64-character `confirmationDigest` from a fresh
preview:

```bash
lemon blueprints activate daily-note --profile operator \
  --confirm <exact-confirmation-digest>
```

The long-running runtime re-plans under the existing blueprint lock before any
write. Content, profile destination, enabled-skill state, or cron collision
changes invalidate the digest. Successful replay reports `unchanged` and keeps
one stable cron job. JSON success is one sanitized document on stdout;
operational failures are one redacted error document on stderr with exit `1`;
invalid CLI arguments use exit `2`. See the
[bundle manifest and safety guide](skills.md#portable-skill-and-automation-bundles).

## Durable sessions

`lemon sessions` is the operator boundary over Lemon's canonical run history,
chat state, policy, and session metadata stores. It does not create another
conversation database. All list and history reads are bounded; history and
exports are always redacted.

### List, search, show, and history

```bash
lemon sessions list --limit 20
lemon sessions list --archived --pinned --agent-id research --json
lemon sessions search "deployment follow-up" --limit 10
lemon sessions show agent:research:main
lemon sessions history agent:research:main --limit 25 --json
```

List and search accept `--limit` from 1 to 500 and `--offset` from 0 to
1,000,000. History accepts `--limit` from 1 to 200. Lifecycle filters are
explicit pairs: `--pinned` or `--unpinned`, and `--archived` or `--active`.
Contradictory filters are usage errors rather than silently selecting one.

Search checks session identifiers, agent identifiers, titles, and a bounded
redacted history selection. Human output avoids store paths and secret values;
JSON output contains normalized session and run fields only.

### Title, pin, and archive state

```bash
lemon sessions title agent:research:main "Literature review"
lemon sessions title agent:research:main --clear
lemon sessions pin agent:research:main
lemon sessions unpin agent:research:main
lemon sessions archive agent:research:main
lemon sessions restore agent:research:main
```

Titles are trimmed and limited to 160 characters. These commands update the
shared lifecycle metadata and verify the session still exists before reporting
success.

### Redacted export

Print an always-redacted JSON or Markdown export:

```bash
lemon sessions export agent:research:main --format json
lemon sessions export agent:research:main --format markdown
```

Write the selected export to an owner-only file:

```bash
lemon sessions export agent:research:main \
  --format json \
  --output research-session.json \
  --json
```

Existing files are refused unless `--force` is explicit. Symlinks and special
files are always refused. With `--output --json`, stdout contains safe export
metadata and only the output basename; the exported content stays in the file.
Without `--output`, `--json` returns the redacted content in its JSON envelope.
Exports contain selected session/run/tool fields, SHA-256 integrity metadata,
and omission counts. They never contain raw run records or raw event payloads.

### Preview-confirm prune

Prune is dry-run by default. It selects only archived sessions older than the
cutoff and excludes pinned sessions:

```bash
lemon sessions prune --older-than 30d
```

`--older-than` accepts a positive age with `s`, `m`, `h`, `d`, or `w`, an
ISO-8601 date/time, or epoch milliseconds. The preview prints the exact
`older_than_ms`, candidate keys, and confirmation token. Review the candidates,
then execute with the exact millisecond cutoff and token printed by the
preview:

```bash
lemon sessions prune \
  --older-than 1788062400000 \
  --confirm <preview-token>
```

Do not repeat a relative value such as `30d` for execution: time has advanced,
so the derived cutoff and token will differ. If any candidate or lifecycle
metadata changes after preview, execution fails and requires a new preview.

`--all` also considers non-archived sessions. `--include-pinned` also considers
pinned sessions. Both widen deletion scope and are included in the token, so
they must be identical at preview and execution. Deletion removes core-owned
chat, policy, metadata, index, and history state and verifies each session is
gone before reporting success.

### Verified single-session delete

Single-session deletion requires the exact session key twice:

```bash
lemon sessions delete agent:research:main \
  --confirm agent:research:main
```

A mismatch is a usage error and does not mutate state. The lifecycle service
deletes canonical run history last, verifies all core-owned state is gone, and
restores recoverable ancillary metadata if final deletion or verification
fails.

## Shell completion

Completion scripts are generated from the same registry used by CLI dispatch
and help, so new runtime families cannot be added to one surface while being
omitted from the others.

### Bash

```bash
mkdir -p "$HOME/.local/share/bash-completion/completions"
lemon completion bash > "$HOME/.local/share/bash-completion/completions/lemon"
```

### Zsh

```zsh
mkdir -p "$HOME/.zfunc"
lemon completion zsh > "$HOME/.zfunc/_lemon"
fpath=("$HOME/.zfunc" $fpath)
autoload -Uz compinit && compinit
```

Persist the `fpath` line in `.zshrc` if `$HOME/.zfunc` is not already in the
completion path.

### Fish

```fish
mkdir -p "$HOME/.config/fish/completions"
lemon completion fish > "$HOME/.config/fish/completions/lemon.fish"
```

Regenerate the script after upgrading Lemon so it reflects the installed
command registry.
