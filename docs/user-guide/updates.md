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
- each selected runtime/TUI artifact filename, declared size, and SHA-256;
- the Lemon Bot backend artifact's filename, declared size, and SHA-256, when
  this machine has an installer-managed backend (see
  [Lemon Bot backend](#lemon-bot-backend));
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
5. atomically flips `versions/current`, verifies the active launcher, flips
   `lemon_bot/current` when a backend artifact is part of the plan, and only
   then writes the successful receipt;
6. stops the Lemon-owned worker units that were running before the
   transaction;
7. if a managed daemon was running before the transaction, re-verifies its
   ownership and process identity, stops that exact daemon, and starts the new
   selected release, waiting for readiness;
8. starts those worker units again, then restarts the Lemon Bot backend unit
   when it was running.

If validation fails after a pointer moves, Lemon restores the exact prior
pointers — both of them when a backend is part of the plan. Downloads and
partial directories are removed on every outcome.

### Service update order (breaking change)

Running worker units must stop **before** the controller restarts and start
again only **after** it is healthy (steps 6–8 above). Custom supervision must
follow that same order; restarting only the controller is no longer the complete
Bot update procedure.

Units use stable launchers (`~/.lemon/bin/lemon`, `~/.local/bin/lemon-bot`),
not paths inside an old version directory. Remote workers are **never silently
updated** by the controller: update each destination deliberately. Afterward
inspect `lemon service status --json`.

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

### Worker and backend units

When this machine runs Lemon under a service manager
(see [Run Lemon as a service](setup.md)), the pre-staging snapshot also records
the Lemon-owned worker units and the backend unit that were **running**. Only
those are cycled, in the order above: workers stop before the controller
restarts and start again only after it is healthy, so no worker keeps a session
open against a controller that is going away. A unit that was installed but
stopped stays stopped, exactly like a stopped controller.

Worker shutdown gates controller restart; controller readiness gates worker and
backend starts. If a worker unit cannot be stopped, the controller and backend
are left untouched. If the controller does not come back, workers stay down
rather than reconnecting to a port nobody serves. If the unit
inventory itself cannot be read — no reachable service manager, or a Mac with
no logged-in desktop session — the update refuses before staging instead of
treating the machine as having no units.

Successful results add two fields beside `restart`:

- `workers`: `"restarted"` or `"not_running"`;
- `backend`: `"restarted"`, `"not_running"`, or `"not_installed"`.

Units run the stable launchers (`~/.lemon/bin/lemon`, `~/.local/bin/lemon-bot`),
never a `versions/<v>` path, so flipping the pointers is what selects the
version a unit runs. No other machine's workers are ever updated from here.

### Lemon Bot backend

`lemon update` treats the Lemon Bot backend as a co-artifact only when
`~/.lemon/lemon_bot/current` is a symlink into `~/.lemon/lemon_bot/versions/`,
the layout `install.sh --profile bot` and `--profile lemon_bot` create. Then the
manifest's `lemon_bot` artifact for the **same target version** is downloaded,
checksum-verified, and staged into
`lemon_bot/versions/<version>-<channel>-<platform>.partial` before anything is
promoted. The backend archive must contain only members under `bot/`, with no
absolute or parent-traversing path, no duplicate member, no member reached
through a symlinked directory, no link pointing outside `bot/`, and a regular
`bot/bin/lemon-bot`. The staged tree must then report
`lemon-bot <version>` and carry its web assets and host-native image runtime.

The runtime pointer flips first, the backend pointer second. A failure after
the first flip restores **both** previous pointers. The receipt records both
versions, and rollback restores both; a backend pointer that moved on since the
apply refuses the rollback with `stale_current_bot_version`. The backend
version the machine runs now is part of the plan digest too, so moving that
pointer between `plan` and `apply` makes the digest stale.

Runtime and backend move together or not at all: if the release publishes no
`lemon_bot` artifact for this platform, planning refuses with
`missing_bot_artifact` rather than updating the runtime alone. Old backend
installs are pruned like old runtime versions, except the one the apply receipt
can roll back to, which is always kept.

Without such a backend install, `lemon update` behaves exactly as before and
never touches `~/.lemon/lemon_bot`. A backend that you supervise yourself, or
that lives outside the managed pointer, is yours to update.

### If restart fails after selection

Apply and rollback return exit `1` with `daemon_restart_failed` when selection
and its receipt succeeded but a restart step did not. The selected pointers and
receipt remain committed: the command does **not** falsely report a transaction
undo. JSON errors include the sanitized committed result and receipt, with
`restart_required: true` and the failing step marked `"failed"` in `restart`,
`workers`, or `backend`; human output includes the receipt ID and, for apply,
its rollback digest.

Inspect `lemon status`, `lemon service status`, and the runtime log before
recovery. After correcting the startup problem, explicitly start the selected
release with `lemon daemon` (or `lemon service repair` for units), or use the
apply receipt's exact rollback command below. Do not blindly repeat apply with
an old confirmation digest. A receipt's `applied` or `rolled_back` status
records the version selection, not a claim that anything is healthy. Successful
results report `restart: "restarted"` or `restart: "not_running"`; neither
requires a further automatic restart.

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
(`0600`). Records contain only version/profile/platform identity (including the
Lemon Bot backend install key when one was updated), timestamps,
receipt/checkpoint IDs, manifest/plan integrity metadata, and status. They do
not contain artifact contents, command output, environment values, credentials,
secret names, or absolute paths.

Rollback never picks a directory by recency and never accepts a filesystem
path. It requires the exact successful apply receipt and that receipt's exact
rollback digest. Lemon verifies that the current pointer still names the
receipt's target, that `lemon_bot/current` still names the backend the receipt
selected when one was updated, and that the retained checkpoint launcher still
matches its recorded SHA-256 before flipping to the receipt-bound prior
version. A failed rollback receipt write restores the update target instead of
leaving an unrecorded state.

Rollback follows the same ownership checks and restart rules as apply. It
restores both pointers when the apply moved both, restarts a running own
managed daemon into the retained prior release with the same worker and backend
ordering, and leaves a stopped installation stopped.

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

`lemon uninstall` removes a packaged Lemon install: its service units, its
program files, and the PATH line the installer added. Your data in `~/.lemon`
is kept unless you pass `--purge`.

Uninstall is a destructive lifecycle operation, so it previews first and binds
your confirmation to the exact set it just listed. Running it with no flags
changes nothing:

```bash
lemon uninstall
```

The preview lists:

- the Lemon service units that will be removed (controller, backend, workers,
  tunnel), as installed by `lemon service install`;
- the program paths that will be deleted: `~/.lemon/versions`, `~/.lemon/bin`,
  `~/.lemon/updates`, `~/.lemon/tmp`, `~/.lemon/lemon_bot/versions`,
  `~/.lemon/lemon_bot/current` and `~/.local/bin/lemon-bot`;
- the rc-file lines to remove: the installer's `# added by the lemon installer`
  comment and the PATH line after it, per shell rc file;
- with `--purge`, `~/.lemon` itself and, on macOS, the Keychain item
  `Lemon Secrets`/`default`;
- a **confirmation digest** over exactly that set.

Execute by repeating the same flags with the digest from the preview:

```bash
lemon uninstall --confirm <digest>
lemon uninstall --purge --confirm <digest>   # also deletes ~/.lemon and secrets
```

Add `--json` to either form for a machine-readable preview or result. For
services only, use `lemon service uninstall ROLE...` (for a named worker,
`lemon service uninstall worker --name NAME`); this keeps programs and data.
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
sensitive. The default backup directory is inside `~/.lemon` and is deleted by
`--purge`. See [Back up and restore](backups.md).

To remove a single old release instead, use `lemonup uninstall <version>`; it
refuses to delete the active `versions/current`.

The digest covers each unit's identity *and* its current file content, every
program path, every rc-file line with its position, and the `--purge` choice.
It is recomputed from live state at execution time: if anything changed since
the preview — a unit was reinstalled or edited, a path appeared or vanished,
you added `--purge` — the digest no longer matches and the command refuses with
a fresh digest instead of acting. Add `--json` to either mode for
machine-readable output.

Execution order is: remove every previewed unit through its service manager by
its exact identity (which stops the processes), stop an unsupervised controller
through the launcher's verified snapshot, remove exactly the bound rc lines,
remove the Keychain item when purging, and finally hand the program paths to
the launcher. Each step must succeed before the next one runs, so a unit that
cannot be removed or a controller that cannot be verified stops the uninstall
with nothing else changed. The deletion itself runs in the launcher after the
Lemon VM exits, because a running release cannot delete its own program files;
the launcher removes only the installer's own paths and refuses anything else.

Uninstall does **not** revoke anything remote. Provider API keys, bot tokens
(Telegram, Discord) and bot machines stay valid: revoke keys at the provider,
and remove a worker machine in Lemon Bot.

Before uninstalling with `--purge`, back up anything you want to keep. Config,
sessions and the store are included by default; only the `cookie`, `env`,
`secrets_master_key` files and `nodes/execution/` are excluded unless you pass
`--include-credentials`. `config.toml` and other files are copied as-is and may
hold inline secrets ([Back up and restore](backups.md)). Write the bundle
outside `~/.lemon`, because the default `~/.lemon/backups/` is purged with the
rest:

```bash
lemon backup create --output ~/lemon-final.lemonbackup
lemon backup verify ~/lemon-final.lemonbackup
```

To sign out of subscription logins first (repeat per provider):

```bash
lemon model anthropic --logout
```

### Remove units only

To stop supervising Lemon without removing the program, remove the units and
keep everything else:

```bash
lemon service uninstall controller backend worker
```

This boots out / disables each unit, deletes the plist or unit file, reloads the
manager, and deletes the unit's status and pid records. Credentials and data are
untouched. For a worker it does not revoke the machine; remove it in Lemon Bot.

### Remove a single release

To remove one old release instead of uninstalling, use
`lemonup uninstall <version>`; it refuses to delete the active
`versions/current`.

### Other layouts

- **Source checkout:** `./bin/lemon uninstall` removes service units only. It
  never deletes program files, rc lines or data — not even with `--purge` —
  because a checkout's program files are the checkout. Delete the checkout
  directory yourself, and remove the shared `~/.lemon` by hand if you also want
  the data gone. If `~/.lemon/bin/lemon` points at the checkout
  (`lemonup use local`), run `lemonup use <version>` first, or delete the link.
- **Standalone `lemon_bot` backend:** `lemon uninstall` removes
  `~/.local/bin/lemon-bot`, `~/.lemon/lemon_bot/versions` and
  `~/.lemon/lemon_bot/current`. The backend's database, attachments and
  encryption key stay in `~/.lemon/lemon_bot` unless you pass `--purge`, so back
  that directory up first if you need it.
- **Container:** `docker rm -f lemon` removes the container. `docker volume rm
  lemon-data` (your volume name) deletes everything on `/data`.
