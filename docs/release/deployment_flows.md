# Deployment Flows

This document describes the supported ways to run Lemon and when to use each.

---

## 1. Source-dev (development)

Run directly from the source tree using Mix.  No release assembly needed.

```bash
# Open the TUI, starting the runtime if needed
./bin/lemon

# Run the runtime in the foreground / background
./bin/lemon start
./bin/lemon daemon

# Or run it directly with Mix
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
~/.lemon/run/                  port-scoped pid/root records and mode-600 port tokens; directory mode 700
~/.lemon/store                 default store path for user installs
```

`bin/lemon` inside every release is a launcher shim that picks the bundled
profile and applies user-install defaults before delegating to
`bin/<profile>`. Its lifecycle commands include `tui`, `web`, `start`,
`daemon`, `stop`, `restart`, and `status`; release VM tools are `remote`,
`eval`, and `rpc`. The full and minimal runtime profiles dispatch `setup`,
`model`, `gateway`, `doctor`, `config`, `secrets`, `mcp`, `channels`,
`providers`, `blueprints`, `profile`, `backup`, `context`, `sessions`, `runs`,
`cron`, `logs`, `omp`, `learn`, `update`, `completion`, `migrate`, `node`,
`acp`, `run`, and `version` through the shared CLI (`lemon --help` lists the
exact set). `doctor --bundle [path]` generates a redacted support bundle. With no
arguments the launcher opens the TUI in an interactive terminal; without a TTY
it prints usage and exits.
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
lemon update apply --confirm <exact-plan-digest>   # also restarts a running daemon
lemon restart   # manual restart, e.g. after changing config or env
```

```bash
lemon setup                         # first-time configuration in a full/min release
lemon model                         # configure a model provider
lemon gateway setup                 # configure a gateway adapter
lemon doctor --json                 # ordinary runtime diagnostics
lemon doctor --bundle               # redacted support bundle
```

Doctor runs in a fresh client VM. When a separate healthy daemon is detected,
it reports that the daemon's memory health was not checked rather than treating
the client's inactive memory store as a daemon failure. Missing memory modules
or native dependencies remain actionable warnings.

Updating stages the checksum/size-authenticated runtime and matching TUI
artifacts together for full/min profiles, then flips the symlink. Planning is
non-mutating and apply needs its exact
fresh digest. There are no hot upgrades: if a verified managed daemon was
running, apply restarts it onto the new version itself (a stopped install stays
stopped), so no separate `lemon stop`/`lemon daemon` is needed. Inspect the
successful apply receipt with `lemon update history`, then roll back only that
receipt-bound checkpoint:

```bash
lemon update rollback --receipt <apply-receipt-id> \
  --confirm <rollback-digest>
```

Rollback never chooses a retained version by recency and restarts a running
managed daemon the same way. See [the update safety contract](../user-guide/updates.md).

Environment knobs, the uninstall procedure, and the platform support table live
in `docs/install.md`. `scripts/verify_install_script` proves this flow against a
fixture release served from localhost, with no published release required.

Installer `--verify` uses a temporary HOME, Store, agent directory, release
pipe/log directory, isolated distributed node, and separate ephemeral control,
web, gateway-health, and router-health ports. It stops that node and removes
the scratch state on success, failure, or interruption rather than booting a
second scheduler against the operator's saved state.

### Publish

Product publication is a single on-demand GitHub Actions operation. Put the
release notes under `CHANGELOG.md`'s Unreleased section, then dispatch from
`main`:

```bash
gh workflow run release.yml --ref main -f channel=stable -f draft=false
```

The workflow gates the source commit with `ci.yml`, derives and commits the next
CalVer, tags the exact commit, builds and native-verifies every runtime, TUI,
and standalone `lemon_bot` artifact, publishes the multi-arch container and
GitHub Release, and finally promotes the mutable container channel tags. See
`docs/release/versioning_and_channels.md` for the full contract and
explicit-version/draft inputs.

### Build

```bash
# Minimal headless runtime (gateway + router + channels + control-plane)
MIX_ENV=prod mix release lemon_runtime_min

# Full local runtime (+ automation, skills, web UI)
MIX_ENV=prod mix do --app lemon_web phx.digest
MIX_ENV=prod mix release lemon_runtime_full
```

Both full and minimal runtime compositions assemble `lemon_mcp` with release
mode `:load`. The library has no application callback and starts no processes;
this entry makes its client modules available to `LemonSkills.McpSource` while
the consuming application remains responsible for supervising each connection.

Both runtime profiles also bundle the local browser driver. A release step runs
`npm ci` and `npm run build` in `clients/lemon-browser-node`, then stages `dist/`
with production-only dependencies under `lib/lemon_browser-*/priv/driver`, so
building either runtime requires Node.js 24 and `npm`. Installed users need only
Node.js and Chrome/Chromium for the managed local browser.
`scripts/verify_release_runtime_boot` fails a runtime tarball whose bundled
driver is missing or does not load.

The full profile bundles the web UI. `lemon_web` commits its
built `app.css` (Tailwind source in `apps/lemon_web/assets`, rebuilt by
developers with `mix do --app lemon_web assets.build`), so it needs the digest
step only. Skipping it
makes the release log "Could not warm up static assets" at boot and serve
undigested assets.

Releases are written to `_build/prod/rel/<profile>/`. Release automation also
builds the `lemon_tui` pseudo-profile as a Bun binary and the standalone
`lemon_bot` backend (`products/lemon_bot/scripts/build_release`), producing 12
published artifacts total: three min, three full, three TUI, and three
`lemon_bot` artifacts.

Mix's `:tar` release step already produces the clean runtime archive. Publish
that file directly rather than compressing the assembled directory again.
With `--path DIR`, Mix puts the archive inside `DIR` instead; do not re-archive
that directory, which would include the archive itself and any local smoke logs.

```bash
cp "_build/prod/<profile>-<version>.tar.gz" \
  "lemon-<version>-<channel>-<platform>-<profile>.tar.gz"
```

The TUI is a separate artifact, not a file produced by `mix release`. Build its
native binary and matching addon before testing an interactive installation:

```bash
(cd clients/tui && bun install --frozen-lockfile && \
  bun run build:binary --target darwin-arm64 --outdir dist)
tar -czf "lemon-<version>-<channel>-darwin-arm64-lemon_tui.tar.gz" \
  -C clients/tui/dist/darwin-arm64 tui
```

The installer combines the runtime and TUI artifacts from the same schema-2
manifest. For a local smoke, serve the manifest and both archives under
`releases/download/v<version>/` on a loopback HTTP server, then point
`LEMON_INSTALL_BASE_URL` at that server and set `LEMON_VERSION=<version>`.
Use an isolated HOME; `--skip-setup` defers login and `--verify` checks an
isolated daemon boot. Plain HTTP is a local test seam, not a distribution
transport.

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
| `LEMON_PATH` | *(unset in releases)* | Lemon source checkout root; the source launchers set it |

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
| `lemon_bot` | `bot/bin/lemon-bot`, packaged web build | Standalone Bun-compiled backend; not a BEAM release (see `docs/release/versioning_and_channels.md`) |

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

The TUI connects to `ws://127.0.0.1:4040/ws` by default.
Override with `LEMON_WS_URL` (a full WebSocket URL). Control-plane approval events surface
as TUI notifications, including MCP OAuth `Open OAuth` links and resource,
scope, and redirect context when a configured HTTP MCP source requests local
PKCE authorization. Operators can resolve the same pending approvals from the
terminal with `/approve [n] [once|session|agent|global]` or `/deny [n]`,
which route to the control-plane `exec.approval.resolve` method. Use
`/approvals` to refresh the current pending approval snapshot from
`exec.approvals.get`; `n` is the 1-based index in that list.

The source launcher creates a high-entropy process-scoped operator token when
it boots a new local runtime, shares it only through the daemon and TUI process
environments, and stops that owned runtime when the TUI exits.

Persistent runtimes started by `./bin/lemon daemon` or installed
`lemon daemon` create a port-scoped credential under `~/.lemon/run`. A later
TUI loads that credential automatically only when it is a regular current-user
file with mode 0600 and a valid 256-bit token. Explicit
`LEMON_CONTROL_PLANE_OPERATOR_TOKEN` values are never persisted; the same value
must still be supplied to attach to a runtime started with an explicit token.
Missing or unsafe credentials fail closed rather than enabling tokenless
loopback access.

Runtime ownership is independent of token origin: every daemon started by
`./bin/lemon-tui` is stopped when that client exits, including when the token
was preconfigured. Start `./bin/lemon daemon` separately before attaching if
the source runtime must remain persistent; already-running runtimes are never
stopped by the TUI launcher.

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


## Public website and documentation

The public website and documentation share the VitePress project in `docs/`.
Markdown remains the source of truth; `docs/.vitepress/theme/` supplies the
homepage and shared visual theme. `LemonFace.vue` draws the mascot with the
Lemon Bot geometry and palette; reuse it rather than adding mascot images.
Brand assets (favicon mark, README banner, social card) live in
`docs/public/brand/`. Fonts are self-hosted through `@fontsource-variable`
packages, so the site makes no third-party font requests.
Relative Markdown links into the repository source are rewritten to GitHub by
`docs/.vitepress/source-links.mjs`; `npm test --prefix docs` checks this behavior.
This static site deploys independently of Lemon runtime releases.

### Verify and publish

```bash
scripts/verify_docs_site
```

The verifier builds in an isolated temporary copy. Both `npm --prefix docs run
build` and dev startup generate the ignored `llms.txt` and `llms-full.txt` assets
from Markdown before VitePress copies them to the site root. Do not commit these
files or require a clean-tree generated diff. Python 3 is required alongside Node.

The `Docs Site` workflow runs the same npm build and recursive link-check commands.
With repository variable `ENABLE_PAGES_DEPLOY=true` and GitHub Pages configured to
use GitHub Actions, docs changes pushed to `main` deploy automatically. To redeploy:

```bash
gh workflow run docs-site.yml --ref main -f deploy=true
```

The production URL is `https://lemon.food/`, served at the domain root (VitePress
`base: "/"`). Verify the homepage, quickstart, search, mobile navigation, and
brand assets after deployment. To roll back a presentation change, revert its
commit on `main` and let the same workflow publish the previous site. No runtime
release or restart is required.

### Custom domain

`lemon.food` is registered at Porkbun, which hosts its DNS. The repository's
Pages settings carry the custom domain with HTTPS enforced. DNS records follow
[GitHub's custom-domain guide](https://docs.github.com/en/pages/configuring-a-custom-domain-for-your-github-pages-site):

|Name|Type|Content|
|---|---|---|
|`lemon.food`|`A`|`185.199.108.153`, `185.199.109.153`, `185.199.110.153`, `185.199.111.153`|
|`lemon.food`|`AAAA`|`2606:50c0:8000::153`, `2606:50c0:8001::153`, `2606:50c0:8002::153`, `2606:50c0:8003::153`|
|`www.lemon.food`|`CNAME`|`z80dev.github.io`|

Do not add wildcard records; GitHub warns they allow subdomain takeover.

Changing the domain means updating those records, the Pages custom domain,
`SITE` in `scripts/generate_docs_llms.py`, and public website links in the
README and docs. Keep homepage links base-aware with VitePress `withBase`.
