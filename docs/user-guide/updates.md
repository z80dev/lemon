# Update, roll back, and uninstall Lemon

Installer-managed `lemon_runtime_min`, `lemon_runtime_full`, and simulation
releases expose a preview-confirm update lifecycle. Lemon stages verified
artifacts and moves the active pointers. It restarts verified own processes
that were running before the update; a stopped installation stays stopped.
Managed Bot installations include the matching backend artifact.

## Choose an update path

| Your install | Update with | Notes |
| --- | --- | --- |
| Installer release (`~/.lemon`) | `lemon update check`, `plan`, `apply` | Preview-confirm, checkpoint, rollback receipt. This page. |
| Any `lemonup` selection, including a source checkout | `lemonup update` | Installs the latest stable release if missing and activates it. See [Install](../install.md#switching-between-releases-and-source-with-lemonup). |
| Installer release, to reinstall or when `lemon update` cannot run | Re-run `install.sh` with `--skip-setup` | Installs the newest version beside the old one and flips `versions/current`. No plan digest, checkpoint or receipt, and it does not restart a running daemon: run `lemon restart` afterwards. Old versions stay in `~/.lemon/versions/` until you remove them. |
| Source checkout | Your Git workflow | See [Source checkouts](#source-checkouts-and-other-layouts). |
| Container image | Pull and start a newer image tag | Not managed by `lemon update`; keep the `/data` volume. |

Check which release you are running at any time:

```bash
lemon version --verbose
```

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
- each selected runtime/TUI/Bot-backend artifact filename, declared size, and SHA-256;
- a short expiry window.

The digest is authorization for one exact plan, not a general `--yes` switch.
Changing the manifest, active version, artifact, or time window makes it stale.

## Apply the exact plan

```bash
lemon update apply --confirm <plan-digest>
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
5. moves the runtime pointer and, for a managed Bot installation, the backend
   pointer, verifies the active programs, then writes the receipt;
6. restarts previously running Lemon-owned services in the order below.

If validation fails after a pointer moves, Lemon restores the prior pointers.
Downloads and partial directories are removed on every outcome.

### Service update order (breaking change)

Running worker units must stop **before** the controller restarts and start
again only **after** it is healthy. The updater snapshots running owned units,
stops those workers, restarts the controller through its supervisor when managed,
waits for readiness, starts the workers and waits for online, then restarts a
previously running backend. Custom supervision must follow that same order;
restarting only the controller is no longer the complete Bot update procedure.

Units use stable launchers (`~/.lemon/bin/lemon`, `~/.local/bin/lemon-bot`),
not paths inside an old version directory. A managed Bot backend is staged at
the same release version; apply and rollback move its pointer with the runtime's.
Remote workers are **never silently updated** by the controller: update each
destination deliberately. Afterward inspect `lemon service status --json`.

Worker/backend restart results report their readiness separately. A restart
failure after selection does not mean the artifact transaction was undone;
inspect the committed result and repair the affected service.

Daemon ownership is checked before staging and again before stopping. A
foreign runtime, an occupied foreign control-plane port, or unverifiable
process ownership is refused; Lemon never kills a process based only on a PID
file. Download, checksum, archive, confirmation, and pre-commit verification
failures do not stop a healthy old daemon. An already-up-to-date apply is a
no-op and does not restart anything.

Use the same `LEMON_CONTROL_PLANE_PORT` for the original daemon and every
update command. The updater inherits that port; it does not assume `4040` or
restart a daemon on another port. For example:

```bash
export LEMON_CONTROL_PLANE_PORT=4220
lemon update plan --json
lemon update apply --confirm <plan-digest> --json
lemon status
```

The restart invokes the selected version's absolute launcher, not the old
update VM's release root. Generated old-release paths are removed from the
child environment; explicit external operator sysconfig, VM-args, and temporary
directory overrides remain in effect.

### If restart fails after selection

Apply and rollback return exit `1` with `daemon_restart_failed` when selection
and its receipt succeeded but daemon restart did not. The selected pointer and
receipt remain committed: the command does **not** falsely report a transaction
undo. JSON errors include the sanitized committed result and receipt, with
`restart: "failed"` and `restart_required: true`; human output includes the
receipt ID and, for apply, its rollback digest.

Inspect `lemon status` and the runtime log before recovery. After correcting the
startup problem, explicitly start the selected release with `lemon daemon`, or
use the apply receipt's exact rollback command below. Do not blindly repeat
apply with an old confirmation digest. A receipt's `applied` or `rolled_back`
status records the version selection, not a claim that the daemon is healthy.
Successful results report `restart: "restarted"` or `restart: "not_running"`;
neither requires a further automatic restart.

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

Rollback follows the same ownership checks and restart rules as apply. It
restarts a running own managed daemon into the retained prior release, and
leaves a stopped installation stopped.

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
your reviewed Git workflow to update a checkout, then synchronize the source
TUI's declared dependencies before launching it:

```bash
(cd clients/tui && bun install --frozen-lockfile)
```

An existing `node_modules` directory can still contain an older TUI package
after a source update. Missing Bun module/export errors are a reason to run
the dependency synchronization above, not to change the imports or install a
different package version.

The contributor-only `mix lemon.update` maintenance task does not download or
replace release artifacts; it is not exposed through `./bin/lemon update`.

Manual tarball directories and container images also fail the managed-layout
guard. Replace or roll those deployments back through their service/container
orchestrator instead of pointing Lemon at an arbitrary path.

All update commands use exit `0` for success, `1` for an operational or
verification refusal, and `2` for invalid arguments. `--json` emits one stable
success document on stdout or one redacted error document on stderr.

## Local artifact servers and release mirrors

Set `LEMON_UPDATE_BASE_URL` to a trusted HTTP(S) artifact base URL for update
commands. When absent, `LEMON_INSTALL_BASE_URL` supplies the same host used by
the installer. Update host precedence is the programmatic `:base_url` option,
`LEMON_UPDATE_BASE_URL`, `LEMON_INSTALL_BASE_URL`, application configuration
`:lemon_core, :update_base_url`, then `https://github.com/z80dev/lemon`.
Use plain HTTP only for an isolated local test server; checksums do not
authenticate a manifest fetched from an untrusted host.

The server must retain the existing release layout:

- `/releases/latest/download/manifest.json` for the stable latest manifest;
- `/releases/download/v<VERSION>/manifest.json` for an explicit `--version`;
- `/releases/download/v<VERSION>/<artifact-file>` for every selected artifact.

For example, with a local server already listening on port `4226`:

```bash
export LEMON_UPDATE_BASE_URL=http://127.0.0.1:4226
export LEMON_CONTROL_PLANE_PORT=4220
lemon update plan --json
lemon update apply --confirm <plan-digest> --json
```

Keep the same host, channel, and explicit version settings between plan and
apply. If using `--channel` or `--version`, repeat them on apply. This seam
changes only the artifact host; managed-layout, exact-digest, checksum, archive,
receipt, and daemon-ownership checks remain mandatory.

## Uninstall

`lemon uninstall` removes owned services and installed programs, keeping your
configuration, sessions, secrets and Bot data by default. Preview first:

```bash
lemon uninstall --json
lemon uninstall --confirm <confirmation-digest>
```

Review the exact units, paths and installer-added shell PATH lines in the
preview. Confirmation authorizes that plan, not an arbitrary later removal.
The command stops owned units through their managers and verifies ownership
before stopping a detached controller; it does not kill a foreign port owner.
Program removal happens after the CLI exits.

For services only, use `lemon service uninstall ROLE...` (for a named worker,
`lemon service uninstall worker --name NAME`). This keeps programs and data.
Removing a worker service does not revoke the machine: remove it in Lemon Bot
if you also want to revoke its authorization.

Before any data removal, create and verify a backup **outside** `~/.lemon`:

```bash
lemon backup create --output ~/lemon-final.lemonbackup
lemon backup verify ~/lemon-final.lemonbackup
```

Backups exclude the `cookie`, `env`, `secrets_master_key` files and
`nodes/execution/` unless `--include-credentials` is selected. Included config
and other files may still contain inline secrets, so treat every bundle as
sensitive. See [Back up and restore](backups.md).

To remove a single old release instead, use `lemonup uninstall <version>`; it
refuses to delete the active `versions/current`.

### Remove all data

This permanently deletes your configuration, sessions, memory, the secrets
master key (when file-backed), and `~/.lemon/backups/`. If you might want any
of it back, create and verify the external backup above. The default backup
directory is inside `~/.lemon` and is deleted by purge. Preview and confirm
the destructive variant explicitly:

```bash
lemon uninstall --purge --json
lemon uninstall --purge --confirm <confirmation-digest>
```

On macOS, purge also removes the **Lemon Secrets** / `default` Keychain item.

Also revoke any provider API keys or bot tokens (Telegram, Discord) you gave
Lemon, at the provider; deleting local files does not revoke them.

### Other layouts

- **Source checkout:** `lemon uninstall` removes owned units only. Manage the
  checkout with your Git/filesystem tools. `~/.lemon` can be shared with installed
  releases; do not remove shared data unintentionally. If `~/.lemon/bin/lemon`
  points at the checkout, select an installed release with `lemonup use <version>`
  before deleting the checkout.
- **Standalone `lemon_bot` backend:** when a runtime CLI is installed, include
  its owned backend service/programs in the uninstall preview. Without that CLI,
  stop your manually supervised backend before removing its launcher and
  `~/.lemon/lemon_bot/versions` / `current`; preserve the remaining
  `~/.lemon/lemon_bot` data unless you deliberately intend to delete it.
- **Container:** `docker rm -f lemon` removes the container. `docker volume rm
  lemon-data` (your volume name) deletes everything on `/data`.
