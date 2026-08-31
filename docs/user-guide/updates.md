# Safely update and roll back Lemon

Installer-managed `lemon_runtime_min`, `lemon_runtime_full`, and simulation
releases expose a preview-confirm update lifecycle. Lemon never replaces the
running process in place: it stages a verified version, atomically moves the
`~/.lemon/versions/current` pointer, and asks you to restart.

## Check and plan

```bash
lemon update check
lemon update plan
```

`check` compares the running release with the published schema-2 manifest.
`plan` is non-mutating: it creates no update directory, receipt, checkpoint,
download, or staged version. Its opaque digest binds all of the following:

- the exact running version and `versions/current` target;
- channel, target version, release profile, and platform;
- the SHA-256 of the raw manifest plus its source commit;
- each selected runtime/TUI artifact filename, declared size, and SHA-256;
- a short expiry window.

The digest is authorization for one exact plan, not a general `--yes` switch.
Changing the manifest, active version, artifact, or time window makes it stale.

## Apply the exact plan

```bash
lemon update apply --confirm <plan-digest>
lemon stop && lemon daemon
lemon status
```

Apply re-plans once before taking the update lock and again under the exclusive
lock. It refuses a missing, stale, or incorrect digest before downloading or
writing update state. Before staging, it records a private verified checkpoint
of the exact current launcher. It then:

1. downloads only the manifest-selected artifacts with bounded time and a hard
   declared-size ceiling;
2. verifies each downloaded byte count and SHA-256;
3. rejects unsafe archives before extraction: absolute or parent-traversing
   names, symlinks, hard links, devices, FIFOs, and excessive entry/expanded
   sizes all fail closed;
4. extracts into a partial directory, verifies the resulting tree and the
   staged `bin/lemon version`, then promotes it with a same-filesystem rename;
5. atomically flips `versions/current`, verifies the active launcher, and only
   then writes the successful receipt.

If validation fails after the pointer moves, Lemon restores the exact prior
pointer. Downloads and partial directories are removed on every outcome.

The current schema-2 release manifest provides **checksum authentication**, not
publisher signing: the artifact SHA-256 and declared size are mandatory, but
Lemon releases do not currently publish a detached signature or trusted signing
key for the manifest. Do not describe this flow as cryptographically signed.

Erlang `:httpc` streams artifacts directly to a file and Lemon enforces the
manifest's declared maximum plus the exact post-download size. The current
client boundary cannot cancel an in-progress response at the exact byte that it
crosses the declared size; an overlong response is deleted and refused after
the bounded request returns. This is a known residual, not an unlimited install
or an integrity bypass.

## Inspect receipts and roll back

```bash
lemon update history
lemon update history --limit 5 --json
lemon update rollback --receipt <apply-receipt-id> \
  --confirm <rollback-digest>
lemon stop && lemon daemon
```

History is newest first and bounded. Receipts live under
`~/.lemon/updates/receipts`; verified checkpoints live beside them under
`checkpoints`. Directories are owner-only (`0700`) and files are owner-only
(`0600`). Records contain only version/profile/platform identity, timestamps,
receipt/checkpoint IDs, manifest/plan integrity metadata, and status. They do
not contain artifact contents, command output, environment values, credentials,
secret names, or absolute paths.

Rollback never picks a directory by recency and never accepts a filesystem
path. It requires the exact successful apply receipt and that receipt's exact
rollback digest. Lemon verifies that the current pointer still names the
receipt's target and that the retained checkpoint launcher still matches its
recorded SHA-256 before flipping to the receipt-bound prior version. A failed
rollback receipt write restores the update target instead of leaving an
unrecorded state.

User configuration, encrypted credentials, sessions, memory, and stores are
outside the managed `versions/` target and are never restored by update
rollback. Use [`lemon backup`](backups.md) for user-state recovery.

## Source checkouts and other layouts

Source checkouts are not binary installations. They support the read-only
published-version visibility and receipt history surfaces:

```bash
./bin/lemon update check
./bin/lemon update history
```

`plan`, `apply`, and `rollback` fail closed with source-update guidance. Use
your reviewed Git workflow to update a checkout. The legacy no-subcommand
`./bin/lemon update` and its contributor flags remain the local stage-1
maintenance task; it does not download or replace release artifacts.

Manual tarball directories and container images also fail the managed-layout
guard. Replace or roll those deployments back through their service/container
orchestrator instead of pointing Lemon at an arbitrary path.

All update commands use exit `0` for success, `1` for an operational or
verification refusal, and `2` for invalid arguments. `--json` emits one stable
success document on stdout or one redacted error document on stderr.
