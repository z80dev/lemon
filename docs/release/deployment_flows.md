# Deployment Flows

This document describes the supported ways to run Lemon and when to use each.

---

## 1. Source-dev (development)

Run directly from the source tree using Mix.  No release assembly needed.

```bash
# Start the full runtime from source
bin/lemon

# Or start a specific profile
mix run --no-halt
```

**Characteristics:**

- Live code reloading with `iex -S mix`
- All Mix tasks available (`mix lemon.setup`, `mix lemon.doctor`, etc.)
- Uses `MIX_ENV=dev` configuration
- Config loaded from `~/.lemon/config.toml` and `.lemon/config.toml` in the project root
- Ports default to 4040 (control-plane), 4080 (web), 4090 (sim-ui)

**When to use:** Local development, debugging, running tests.

---

## 2. Release-runtime (production/server)

A self-contained Erlang/OTP release with the BEAM bundled — no Elixir or Mix required on the target machine.

### Build

```bash
# Minimal headless runtime (gateway + router + channels + control-plane)
MIX_ENV=prod mix release lemon_runtime_min

# Full local runtime (+ automation, skills, web UI, sim UI)
MIX_ENV=prod mix release lemon_runtime_full

# Public sim broadcast site (dashboard + spectator UI)
MIX_ENV=prod mix sim_ui.assets.deploy
MIX_ENV=prod mix release sim_broadcast_platform
```

Releases are written to `_build/prod/rel/<profile>/`.

Release automation packages the assembled release directory as a `.tar.gz`:

```bash
tar -czf lemon-<version>-<channel>-ubuntu-24.04-x86_64-<profile>.tar.gz \
  -C ./_build/prod/rel/<profile> .
```

Install an artifact by verifying its SHA-256 from `manifest.json`, extracting it
into the target directory, setting the required runtime environment variables,
and running `bin/<profile>` from the extracted directory.

```bash
scripts/verify_release_artifacts /path/to/downloaded-artifacts
scripts/verify_release_runtime_boot /path/to/downloaded-artifacts
```

### Run

```bash
# Foreground
./_build/prod/rel/lemon_runtime_min/bin/lemon_runtime_min start

# Daemon (background)
./_build/prod/rel/lemon_runtime_min/bin/lemon_runtime_min daemon

# Stop
./_build/prod/rel/lemon_runtime_min/bin/lemon_runtime_min stop
```

`sim_broadcast_platform` is the dedicated production profile for `lemon_sim_ui`. It serves the public Werewolf-first broadcast lobby at `/`, stable arenas at `/arena/:domain`, individual `/watch/:sim_id` model broadcasts, and optional hosted human Werewolf at `/play`, while keeping the `/admin` control room, metrics, and `/api/admin/*` behind `LEMON_SIM_UI_ACCESS_TOKEN`. Browser operators authenticate through the CSRF-protected `/admin/login` form and receive an expiring signed-session marker; query-string tokens are rejected and `/api/admin/*` remains bearer-only. `LEMON_SIM_UI_ADMIN_SESSION_TTL_SECONDS` controls the browser lifetime from 300 to 86400 seconds and defaults to eight hours. Rotate the access token to invalidate all browser sessions, and expose these routes only over HTTPS.

Its production endpoint fails closed unless host, persistent store path, a
64-byte secret key base, and a 32-byte admin access token are explicit. Use
`/healthz` for process liveness and `/readyz` for deploy/load-balancer readiness.
The container and Fly manifest persist both `/app/data/store` and
`/app/data/leagues` on the same mounted volume and must remain at one instance
while SQLite and local PubSub are in use.

Hosted rooms are off by default in production. Enabling them requires HTTPS,
`LEMON_WEREWOLF_HOSTED_ENABLED=true`, and a random 32-byte-or-longer
`LEMON_WEREWOLF_HOST_CREATE_TOKEN`. AI seats additionally require a valid
`LEMON_WEREWOLF_HOSTED_AI_MODEL` and provider credential. Keep one instance:
room ownership, Registry, timers, and PubSub are process-local.

### Sim broadcast operations

Keep exactly one `sim_broadcast_platform` instance attached to a persistent
volume. Before every deploy or rollback, disable arena/auto-loop starts, wait
for `/readyz` to report zero active runners and queued recoveries, then stop the
instance. Run the backup commands from a maintenance shell with the same volume
mounted and no application writer. This keeps SQLite and the rotating league
tree in one consistent snapshot. For the container layout:

For hosted rooms, stop new creation first by removing the public creation
invite or placing the service in maintenance mode. Ask hosts to pause active
matches, then inspect protected `/api/admin/metrics` until no room is `running`
and hosted recovery reports `ok`. A graceful restart can resume running timers,
but an offline backup must have no application writer. Hosted room records,
reconnect-token hashes, RNG checkpoints, replay events, deadlines, and rematch
archives are stored inside the same SQLite backup below; raw host/player tokens
exist only in browser cookies and are never part of a backup.

```bash
mkdir -p /app/data/backups
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
sqlite3 /app/data/store/store.sqlite3 \
  ".backup '/app/data/backups/store.${timestamp}.sqlite3'"
sqlite3 "/app/data/backups/store.${timestamp}.sqlite3" "PRAGMA integrity_check;"
tar -C /app/data -czf "/app/data/backups/leagues.${timestamp}.tgz" leagues
```

Copy backups off the instance/volume. A valid SQLite check prints `ok`. The
arena keeps only the newest configured game-record window, so archive league
records before they rotate if long-term raw history is required.

Restore offline: stop the release/container, integrity-check the chosen backup,
replace `/app/data/store/store.sqlite3`, replace `/app/data/leagues` from the
matching archive, set both trees to UID/GID `10001:10001`, then start the exact
image paired with that backup.

```bash
sqlite3 /app/data/backups/store.TIMESTAMP.sqlite3 "PRAGMA integrity_check;"
rm -f /app/data/store/store.sqlite3-wal /app/data/store/store.sqlite3-shm
cp /app/data/backups/store.TIMESTAMP.sqlite3 /app/data/store/store.sqlite3
rm -rf /app/data/leagues
tar -C /app/data -xzf /app/data/backups/leagues.TIMESTAMP.tgz
chown -R 10001:10001 /app/data/store /app/data/leagues
```

Deployments made before the unified volume layout may have league directories
at `/app/data/*_league`; move those directories under
`/app/data/leagues/` before booting the new image. Do not leave both layouts
active.

For rollback, stop traffic, stop the current instance with its 30-second grace
period, restore the pre-deploy database and league archive, and start the
previous immutable image/release. Verify `/healthz`, `/readyz`, `/`, a known
`/watch/:sim_id`, an unauthenticated redirect from `/admin` to `/admin/login`,
and an unauthenticated `401` from `/api/admin/metrics` before restoring traffic.
Keep the failed image, logs, `/readyz` build block, and backup
timestamps for incident review.

For a hosted deployment, also verify `/play`, create a room using the creation
invite, join from an independent browser, reload the player session, and verify
that a room persisted before restart is still accessible afterward. Private
rooms must return to their host/player sessions but remain unavailable to an
anonymous `/rooms/:id/watch` request.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `LEMON_CONTROL_PLANE_PORT` | `4040` | Control-plane HTTP port |
| `LEMON_WEB_PORT` | `4080` | Web UI HTTP port |
| `LEMON_SIM_UI_PORT` | `4090` | Sim UI HTTP port |
| `LEMON_SECRETS_MASTER_KEY` | *(keychain/file)* | Override secrets master key. On local Linux source runs, `bin/lemon` will normalize this from `~/.lemon/secrets_master_key` when that file exists. |
| `LEMON_PATH` | *(source-relative)* | Override Lemon root directory |

### Verify health

```bash
# Wait for the control-plane to become ready
curl -sS http://localhost:4040/healthz

# Or use the doctor command from the source tree
mix lemon.doctor --json

# Generate a redacted support bundle from the source tree
mix lemon.doctor --bundle

# Generate a redacted support bundle from a release artifact
./_build/prod/rel/lemon_runtime_full/bin/lemon_runtime_full eval \
  'LemonCore.Doctor.CLI.bundle!()'
```

For `lemon_runtime_full`, include `LEMON_WEB_SECRET_KEY_BASE` in release `eval`
commands as well as daemon/start commands. The full profile configures the web
endpoint during release boot before the eval expression is executed.

### Profiles

| Profile | Apps | Use case |
|---|---|---|
| `lemon_runtime_min` | gateway, router, channels, control-plane | Headless / API-only server |
| `lemon_runtime_full` | + automation, skills, web, sim-ui | Full local runtime with UI |
| `sim_broadcast_platform` | lemon_core, lemon_sim, lemon_sim_ui | Public sim broadcast deployment |

---

## 3. Attached-client (TUI / web)

Connect a client to an already-running Lemon runtime — either the source-dev instance or a release.

### TUI client (`lemon-tui`)

```bash
cd clients/lemon-tui
npm start
```

The TUI connects to the control-plane at `http://localhost:4040` by default.
Override with `LEMON_CONTROL_PLANE_URL`. Control-plane approval events surface
as TUI notifications, including MCP OAuth `Open OAuth` links and resource,
scope, and redirect context when a configured HTTP MCP source requests local
PKCE authorization. Operators can resolve the same pending approvals from the
terminal with `/approval approve|once|session|agent|global|deny <approval-id>`,
which routes to the control-plane `exec.approval.resolve` method. Use
`/approval` or `/approval list` to refresh the current pending approval
snapshot from `exec.approvals.get`.

### Web client (`lemon-web`)

```bash
cd clients/lemon-web
npm start
```

Connects to `http://localhost:4080` (the web Phoenix endpoint).

### Python TUI (CLI wrapper)

```bash
python apps/lemon_tui/lemon_tui/main.py
```

---

## CI smoke-test flow

The `release-smoke.yml` workflow exercises both release-runtime and Sim UI
container flows end-to-end:

1. Build `lemon_runtime_min` with `MIX_ENV=prod mix release`.
2. Launch the release as a daemon.
3. Poll `/healthz` until the control-plane is ready (up to 30 s).
4. Run `apps/lemon_core/test/lemon_core/release/smoke_test.exs` with `--include smoke`.
5. Stop the release.
6. On failure, upload logs from `_build/prod/rel/<profile>/tmp/log/` as GitHub Actions artifacts.

Its `sim-container-smoke` job builds the production Dockerfile with commit
identity, verifies UID `10001`, `/healthz`, `/readyz`, admin denial, digested
gzip assets and immutable caching, seeds persisted Werewolf state, and performs
a graceful stop/restart against the same mounted volume. It also boots a second
production container with hosted mode, HTTPS URL configuration, and a creation
invite, then verifies secure/no-store cookies and paused-room recovery after a
restart. The hosted browser lane (`npm run smoke:hosted-werewolf`) separately
exercises five isolated sessions, secret non-leakage, timeout, pause/resume,
reconnect, completion, export, rematch, and the supported responsive viewports.

---

## See also

- `docs/release/versioning_and_channels.md` — CalVer scheme and channel model
- `docs/release/release_checklist_and_support_policy.md` — release-candidate checklist, rollback checklist, and public support boundaries
- `apps/lemon_core/lib/lemon_core/runtime/` — Boot, Profile, Health, Env modules
- `mix lemon.doctor` / `LemonCore.Doctor.CLI.bundle!()` — diagnostic check suite and redacted support bundles
- `mix lemon.setup` — first-time configuration wizard
