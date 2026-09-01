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
- Ports default to 4040 (control-plane) and 4080 (web)

**When to use:** Local development, debugging, running tests.

---

## 2. Release-runtime (production/server)

A self-contained Erlang/OTP release with the BEAM bundled — no Elixir or Mix required on the target machine.

### Installer flow (workstations and single-machine hosts)

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh
```

`install.sh` resolves the platform from `uname`, downloads the matching artifact
named in the release `manifest.json`, verifies its SHA-256, and installs it
under `~/.lemon`:

```
~/.lemon/versions/<version>/   extracted release
~/.lemon/versions/<version>/tui/bin/lemon-tui  compiled TUI when installed
~/.lemon/versions/current      symlink to the active version
~/.lemon/bin/lemon             -> ../versions/current/bin/lemon
~/.lemon/{cookie,env}          generated once by the launcher, mode 600 from creation
~/.lemon/run/                  pid, runtime-root, and mode-600 port-token records; directory mode 700
~/.lemon/store                 default store path for user installs
```

`bin/lemon` inside every release is a launcher shim that picks the bundled
profile and applies user-install defaults before delegating to
`bin/<profile>`. It accepts `start`, `daemon`, `stop`, `restart`, `status`,
`remote`, `eval`, `rpc`, `version`, `update`, and `tui`. The full and minimal
runtime profiles additionally accept `setup`, `model`, `gateway`, `config`,
`secrets`, `channels`, and `doctor`; `doctor --bundle [path]` generates a
redacted support bundle. With no arguments the launcher starts the TUI
in an interactive terminal, auto-starting the daemon; non-interactive
invocation prints usage.

The launcher never builds Elixir source from user input. `doctor` argv is
forwarded verbatim to `LemonCli.CLI.main/1`, so option order is preserved and
`#{...}` in a bundle path stays literal. Launcher-created state — `~/.lemon` itself,
`run/`, the cookie, and `env` — is written under `umask 077`, so secrets are
private from their first byte (directories 0700, files 0600).

```bash
lemon daemon    # background start, recording pid and version root in ~/.lemon/run
lemon status    # pidfile plus a control-plane /healthz probe
lemon stop      # stops through the recorded root, so it works across a flip
lemon update plan
lemon update apply --confirm <exact-plan-digest>
lemon stop && lemon daemon   # restart to apply a staged version
```

```bash
lemon setup                         # first-time configuration in a full/min release
lemon model                         # configure a model provider
lemon gateway setup                 # configure a gateway adapter
lemon doctor --json                 # ordinary runtime diagnostics
lemon doctor --bundle               # redacted support bundle
```

Updating stages the checksum/size-authenticated runtime and matching TUI
artifacts together for full/min profiles, then flips the symlink. Planning is
non-mutating and apply needs its exact fresh digest. There are no hot upgrades.
Inspect the successful apply receipt
with `lemon update history`, then roll back only that receipt-bound checkpoint:

```bash
lemon update rollback --receipt <apply-receipt-id> \
  --confirm <rollback-digest>
```

Rollback never chooses a retained version by recency and again needs a restart
to take effect. See [the update safety contract](../user-guide/updates.md).

Environment knobs, the uninstall procedure, and the platform support table live
in `docs/install.md`. `scripts/verify_install_script` proves this flow against a
fixture release served from localhost, with no published release required.

### Publish

Product publication is a single on-demand GitHub Actions operation. Put the
release notes under `CHANGELOG.md`'s Unreleased section, then dispatch from
`main`:

```bash
gh workflow run release.yml --ref main -f channel=stable -f draft=false
```

The workflow derives and commits the next CalVer, tags the exact commit,
builds and native-verifies every runtime and TUI artifact, publishes the
multi-arch container and GitHub Release, and finally promotes the mutable
container channel tags. See `docs/release/versioning_and_channels.md` for the
full contract and explicit-version/draft inputs.

### Build

```bash
# Minimal headless runtime (gateway + router + channels + control-plane)
MIX_ENV=prod mix release lemon_runtime_min

# Full local runtime (+ automation, skills, web UI)
MIX_ENV=prod mix phx.digest apps/lemon_web/priv/static -o apps/lemon_web/priv/static
MIX_ENV=prod mix release lemon_runtime_full
```

Both full and minimal runtime compositions assemble `lemon_mcp` with release
mode `:load`. The library has no application callback and starts no processes;
this entry makes its client modules available to `LemonSkills.McpSource` while
the consuming application remains responsible for supervising each connection.

The full profile bundles `lemon_web`, which ships static files with no build
pipeline, so it needs the digest step only. Skipping it makes the release log
"Could not warm up static assets" at boot and serve undigested assets.

Releases are written to `_build/prod/rel/<profile>/`. Release automation also
builds the `lemon_tui` pseudo-profile as a Bun binary, producing nine published
artifacts total: three min, three full, and three TUI artifacts.

Release automation packages the assembled release directory as a `.tar.gz`:

```bash
tar -czf lemon-<version>-<channel>-<platform>-<profile>.tar.gz \
  -C ./_build/prod/rel/<profile> .
```

Platform tags are `linux-x86_64`, `linux-arm64`, and `darwin-arm64`; see
`docs/release/versioning_and_channels.md`.

### Manual tarball install (servers)

Servers that manage their own directory layout, service unit, and rollback
should keep installing tarballs directly rather than through `install.sh`.
Install an artifact by verifying its SHA-256 from `manifest.json`, extracting it
into the target directory, setting the required runtime environment variables,
and running `bin/<profile>` from the extracted directory. `bin/lemon` is present
too, but the explicit `bin/<profile>` entry point is the one to script against
when the layout is not `~/.lemon`.

```bash
scripts/verify_release_artifacts /path/to/downloaded-artifacts
scripts/verify_release_runtime_boot /path/to/downloaded-artifacts
```

`lemon update` refuses to run against this layout: it only manages the
`~/.lemon/versions` shape, so a manual install is never mutated underneath its
operator. Roll back with the operator procedure in
`docs/release/release_checklist_and_support_policy.md`.

### Run

```bash
# Foreground
./_build/prod/rel/lemon_runtime_min/bin/lemon_runtime_min start

# Daemon (background)
./_build/prod/rel/lemon_runtime_min/bin/lemon_runtime_min daemon

# Stop
./_build/prod/rel/lemon_runtime_min/bin/lemon_runtime_min stop
```

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `LEMON_CONTROL_PLANE_PORT` | `4040` | Control-plane HTTP port |
| `LEMON_WEB_PORT` | `4080` | Web UI HTTP port |
| `LEMON_SECRETS_MASTER_KEY` | *(keychain/file)* | Override secrets master key. On local Linux source runs, `bin/lemon` will normalize this from `~/.lemon/secrets_master_key` when that file exists. |
| `LEMON_PATH` | *(source-relative)* | Override Lemon root directory |

### Verify health

```bash
# Wait for the control-plane to become ready
curl -sS http://localhost:4040/healthz

# Run diagnostics from a full or minimal release
./_build/prod/rel/lemon_runtime_full/bin/lemon doctor --json

# Generate a redacted support bundle from any release profile
./_build/prod/rel/lemon_runtime_full/bin/lemon doctor --bundle
```

For `lemon_runtime_full`, include `LEMON_WEB_SECRET_KEY_BASE` in release `eval`
commands as well as daemon/start commands. The full profile configures the web
endpoint during release boot before the eval expression is executed.

### Profiles

| Profile | Apps | Use case |
|---|---|---|
| `lemon_runtime_min` | gateway, CLI, router, channels, control-plane; MCP client library loaded on demand | Headless / API-only server |
| `lemon_runtime_full` | + automation, skills, web; MCP client library loaded on demand | Full local runtime with UI |
| `lemon_tui` | `tui/bin/lemon-tui` | Bun-compiled client pseudo-profile, not a BEAM release |

---

## 3. Attached-client (TUI / web)

Connect a client to an already-running Lemon runtime — either the source-dev instance or a release.

### TUI client

For an installed full/min release, use the plain command from an interactive
terminal; it starts the daemon when needed. The explicit form is:

```bash
lemon tui
```

For source development, the launcher runs `bun src/main.ts` from `clients/tui`:

```bash
./bin/lemon-tui
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

The source launcher creates a high-entropy process-scoped operator token when
it boots a new local runtime, shares it only through the daemon and TUI process
environments, and stops that owned runtime when the TUI exits.

Persistent runtimes started by `./bin/lemon --daemon` or installed
`lemon daemon` create a port-scoped credential under `~/.lemon/run`. A later
TUI loads that credential automatically only when it is a regular current-user
file with mode 0600 and a valid 256-bit token. Explicit
`LEMON_CONTROL_PLANE_OPERATOR_TOKEN` values are never persisted; the same value
must still be supplied to attach to a runtime started with an explicit token.
Missing or unsafe credentials fail closed rather than enabling tokenless
loopback access.

Runtime ownership is independent of token origin: every daemon started by
`./bin/lemon-tui` is stopped when that client exits, including when the token
was preconfigured. Start `./bin/lemon --daemon` separately before attaching if
the source runtime must remain persistent; already-running runtimes are never
stopped by the TUI launcher.

### Web client (`lemon-web`)

```bash
cd clients/lemon-web
npm start
```

`npm start` runs the root `prestart` hook first, rebuilding the ignored shared
and server entrypoints so this works from a clean checkout after dependencies
are installed.

This source command starts the Node debug bridge on `http://localhost:3939` by
default. The packaged Phoenix Web endpoint remains `http://localhost:4080`.

The separate browser monitoring client has no delegated browser-session login
exchange today. It therefore does not receive the server's shared operator
token and cannot connect to an authenticated control plane. Do not put that
secret in a `VITE_*` variable or URL, and do not enable tokenless loopback
behind a reverse proxy. Authenticated browser monitoring requires a future
short-lived, scoped server-issued browser credential flow.


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

- `docs/install.md` — one-line installer, `~/.lemon` layout, env knobs, uninstall
- `install.sh` / `scripts/verify_install_script` — installer and its fixture-server verifier
- `docs/release/versioning_and_channels.md` — CalVer scheme and channel model
- `docs/release/release_checklist_and_support_policy.md` — release-candidate checklist, rollback checklist, and public support boundaries
- `apps/lemon_core/lib/lemon_core/runtime/` — Boot, Profile, Health, Env modules
- `lemon doctor` / `mix lemon.doctor` — diagnostics in a release / source checkout; append `--bundle` for a redacted support bundle
- `lemon setup` / `mix lemon.setup` — first-time configuration wizard in a release / source checkout
