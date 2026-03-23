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
MIX_ENV=prod mix release sim_broadcast_platform
```

Releases are written to `_build/prod/rel/<profile>/`.

### Run

```bash
# Foreground
./_build/prod/rel/lemon_runtime_min/bin/lemon_runtime_min start

# Daemon (background)
./_build/prod/rel/lemon_runtime_min/bin/lemon_runtime_min daemon

# Stop
./_build/prod/rel/lemon_runtime_min/bin/lemon_runtime_min stop
```

`sim_broadcast_platform` is the dedicated production profile for `lemon_sim_ui`. It is the one to use when you want to expose public `/watch/:sim_id` spectator pages while keeping the admin dashboard and `/api/admin/*` behind `LEMON_SIM_UI_ACCESS_TOKEN`.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `LEMON_CONTROL_PLANE_PORT` | `4040` | Control-plane HTTP port |
| `LEMON_WEB_PORT` | `4080` | Web UI HTTP port |
| `LEMON_SIM_UI_PORT` | `4090` | Sim UI HTTP port |
| `LEMON_SECRETS_MASTER_KEY` | *(keychain)* | Override secrets master key |
| `LEMON_PATH` | *(source-relative)* | Override Lemon root directory |

### Verify health

```bash
# Wait for the control-plane to become ready
curl -sS http://localhost:4040/healthz

# Or use the doctor command from the source tree
mix lemon.doctor --json
```

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
Override with `LEMON_CONTROL_PLANE_URL`.

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

The `release-smoke.yml` workflow exercises the release-runtime flow end-to-end:

1. Build `lemon_runtime_min` with `MIX_ENV=prod mix release`.
2. Launch the release as a daemon.
3. Poll `/healthz` until the control-plane is ready (up to 30 s).
4. Run `apps/lemon_core/test/lemon_core/release/smoke_test.exs` with `--include smoke`.
5. Stop the release.
6. On failure, upload logs from `_build/prod/rel/<profile>/tmp/log/` as GitHub Actions artifacts.

---

## See also

- `docs/release/versioning_and_channels.md` — CalVer scheme and channel model
- `apps/lemon_core/lib/lemon_core/runtime/` — Boot, Profile, Health, Env modules
- `mix lemon.doctor` — diagnostic check suite
- `mix lemon.setup` — first-time configuration wizard
