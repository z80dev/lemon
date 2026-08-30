# Back up and restore Lemon user state

Lemon can create, verify, list, and restore private backups of durable state in
`~/.lemon`. The same commands are available in an installed release as
`lemon backup ...` and from a source checkout as `./bin/lemon backup ...`.

```bash
lemon backup contract
lemon backup create
lemon backup list
lemon backup verify ~/.lemon/backups/<bundle>.lemonbackup
lemon backup restore ~/.lemon/backups/<bundle>.lemonbackup
```

The current backup format and data-contract version are both `1`. Restore
checks both versions before staging or changing the target. A newer or malformed
schema fails closed instead of being interpreted approximately.

## The `~/.lemon` data contract

The default scope is durable user state under `~/.lemon`. Project-local
`<project>/.lemon` directories are separate and are never discovered by this
command.

| Included by default | Excluded by default |
| --- | --- |
| `config.toml` | Installed `bin/` launchers and `versions/` |
| Durable `agent/` sessions, workspace, and skills | `run/`, `tmp/`, caches, logs, pid/socket files, and operation locks |
| Durable stores such as `store/` | Existing `backups/`, support bundles, and restore rollback material |
| Other regular files not covered by an exclusion | Symlinks and special files |
|  | Project-local `.lemon` directories and platform keychain contents |
|  | `cookie`, `env`, `secrets_master_key`, and `nodes/execution/` credentials |

Use `--include-credentials` only when the backup destination has the same
security as the machine's credential store:

```bash
lemon backup create --include-credentials
```

This opt-in includes Lemon's local cookie, environment file, file-backed
secrets master key, and execution-node credential files. It cannot export
platform keychain contents. Backed-up bytes are opaque: neither human nor JSON
CLI output contains file contents or secret values.

`lemon backup contract --json` returns the policy as machine-readable metadata.
There are no TOML settings for backups; the command's explicit flags and paths
are the safety boundary.

## Bundle format and creation guarantees

The default destination is `~/.lemon/backups/`. A bundle is a private directory
named `lemon-backup-<timestamp>-<unique>.lemonbackup`:

```text
<bundle>.lemonbackup/
├── manifest.json
├── manifest.sha256
└── data/
    └── <relative paths from ~/.lemon>
```

`manifest.json` records format and contract versions, creation time, relative
paths, byte counts, SHA-256 checksums, and an allowlisted owner mode for every
file. It never records the absolute source path. The bundle root and all of its
directories are owner-only; files are owner-only as well.

Creation copies into a private partial directory, checks that each source file
did not change during the copy, syncs file and manifest metadata where the
platform permits, verifies the completed partial bundle, then exposes the final
path with one atomic directory rename. A failed create removes the partial path
and never reports it as a backup.

Choose another final path with `--output`:

```bash
lemon backup create --output /secure/offline/lemon-2026-08-30.lemonbackup
```

The destination must not already exist.

## Verification

Always verify a copied or transported bundle before restore:

```bash
lemon backup verify /secure/offline/lemon-2026-08-30.lemonbackup
```

Verification checks all of the following without reading values into CLI
output:

- supported product, format schema, and data-contract versions;
- manifest checksum and bounded manifest structure;
- safe normalized relative paths with no traversal;
- an exact match between the manifest and the files below `data/`;
- every recorded size and SHA-256 checksum;
- regular-file/directory types only, with no symlinks or special entries;
- owner-only permissions throughout the bundle.

Permission widening is a verification failure. Tightening a bundle file's mode
does not change the restore mode: restore applies the exact owner mode recorded
in the manifest, and only `0400`, `0500`, `0600`, or `0700` are accepted.

## Safe restore and overwrite confirmation

Restore is additive. It installs missing files, skips byte-and-mode-identical
files, and leaves excluded runtime installations such as `versions/` and
`bin/` untouched. A symlink, special file, or non-directory parent in the
target is always a structural conflict.

Differing regular files are refused by default:

```bash
lemon backup restore /secure/offline/lemon-2026-08-30.lemonbackup
```

To replace them, first verify against the exact target:

```bash
lemon backup verify /secure/offline/lemon-2026-08-30.lemonbackup \
  --target "$HOME/.lemon" --json
```

Copy `result.overwrite_confirmation` from that output, then use it explicitly:

```bash
lemon backup restore /secure/offline/lemon-2026-08-30.lemonbackup \
  --target "$HOME/.lemon" \
  --overwrite \
  --confirm <overwrite_confirmation>
```

The confirmation is derived from the verified manifest SHA-256 plus the
expanded, normalized target root. A token for another bundle or target is
rejected. `--confirm` without `--overwrite` is a usage error.

Before mutation, restore re-verifies the complete bundle and stages all new
bytes in a private sibling directory. Differing destination files are moved to
`<target>.pre-restore.<backup-id>/`, then staged files are renamed into place
and directory metadata is synced where supported. The retained rollback
directory includes `restore-receipt.json` with counts and timestamps, never
file contents. It also records the manifest digest and normalized local target
so an operator can identify the authorized restore. If apply fails, Lemon
removes newly installed files and moves the displaced originals back. If that
rollback cannot finish, Lemon retains the rollback material and reports a
fail-closed error.

## JSON and exit codes

Every subcommand supports `--json`. A successful command writes exactly one
JSON document to stdout:

```json
{"ok":true,"operation":"verify","result":{"verified":true}}
```

An operational or verification failure writes one redacted JSON document to
stderr. Exit codes are stable:

| Code | Meaning |
| --- | --- |
| `0` | Success |
| `1` | Operational, conflict, or verification failure |
| `2` | Invalid command or options |

Aggregate output may include bundle/target paths, identifiers, timestamps,
file counts, byte counts, checksums, and the target-bound confirmation. It does
not include backed-up contents or secret values.

## Boundaries

This command backs up local durable user state. It does not:

- back up project-local `.lemon` directories;
- export macOS Keychain or another platform credential manager;
- upload a bundle or transmit it to a named execution node;
- provide update plan/apply/rollback receipts;
- replace application-level database snapshots required by a separately
  managed deployment.

Keep offline copies according to your own retention policy, verify them after
transport, and test restore into an isolated `--target` before relying on a
backup for recovery.
