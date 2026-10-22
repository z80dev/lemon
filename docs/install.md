# Install Lemon

Lemon installs as a prebuilt release in one command, as a container image, or
from a source checkout. Every path keeps your configuration, encrypted secrets,
and store in `~/.lemon` and uses the same first-run setup.

| Path | Best for | What you need |
| --- | --- | --- |
| [Installer](#quick-install) | Everyday use on macOS or Linux | `curl`, `tar`, `python3`, a model-provider account |
| [Container image](#container-image) | Servers and always-on hosts | Docker |
| [Source checkout](#source-development) | Contributing, unsupported platforms, building releases | Elixir, Erlang/OTP, Bun |
| [Mac app](#mac-app) | Lemon Bot on macOS | Built from source today |

Want the shortest route to a working chat? Follow the
[quickstart](getting-started/quickstart.md).

## Supported platforms

The release workflow builds and boot-verifies these artifacts on native
runners (`.github/workflows/release.yml`):

| Platform | `full` (default) | `min` | `sim` | Terminal UI | `lemon_bot` backend |
| --- | --- | --- | --- | --- | --- |
| macOS Apple Silicon (`darwin-arm64`) | yes | yes | no | yes | yes |
| Linux x86_64 (`linux-x86_64`) | yes | yes | yes | yes | yes |
| Linux ARM64 (`linux-arm64`) | yes | yes | yes | yes | yes |

Linux builds target glibc 2.39 or newer. macOS Intel and native Windows have no
release artifacts: use WSL, the [container image](#container-image), or a
[source install](#source-development). On an unsupported OS or architecture the
installer exits and points you here.

## Quick install

From a terminal, run:

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh
```

The installer:

1. detects your platform and downloads the release manifest from GitHub
   Releases (`releases/latest/download/manifest.json` for stable);
2. downloads the runtime tarball and, unless you opt out, the terminal UI
   tarball, and verifies each size and SHA-256 against the manifest before
   anything is extracted;
3. extracts both into `~/.lemon/versions/<version>/`, atomically flips
   `~/.lemon/versions/current`, and links `~/.lemon/bin/lemon`;
4. on macOS, clears the download quarantine attribute from the extracted tree;
5. adds `~/.lemon/bin` to PATH in your shell rc file (`~/.zshrc`, `~/.bashrc`, or
   fish `config.fish`) unless you pass `--no-modify-path`;
6. runs `lemon version`, then starts `lemon setup` (on `/dev/tty`, so the pipe
   through `sh` does not block it) for the `full` and `min` profiles.

Output stays short: one line before the download, a progress bar on a
terminal, one line once installed, then setup and a final hint. Checksum
failures and other errors are still reported in full.

If the install is interrupted, the installer removes its partial downloads and
staging directory and restores the previous version, if any. Installing never
touches `config.toml`, secrets, or the store.

### First run

Complete the setup prompts: provider, sign-in or API key, and default model.
Setup verifies the provider and, when the check passes, offers **Open Lemon now?**
Accept it to open the terminal UI and send your first message. Later, open a new
terminal (or `export PATH="$HOME/.lemon/bin:$PATH"` in the current one) and run:

```bash
lemon            # interactive terminal: opens the TUI, starting a daemon if needed
lemon doctor     # offline diagnostics for config, credentials, model, and runtime
lemon version    # add --verbose for source/release, commit, and channel
```

In an interactive terminal, bare `lemon` opens the TUI (`lemon tui` is
equivalent). Without a TTY it prints a hint and exits with status 2. Use
`lemon -p "PROMPT"` for scripts and `lemon start` to run the runtime in the
foreground. Before the first daemon start, the TUI launcher runs
`lemon setup --if-required`, so an unfinished setup is resumed instead of
starting an unconfigured daemon. Details are in [Set up Lemon](user-guide/setup.md).

### Installer options

| Flag | Effect |
| --- | --- |
| `--profile NAME` | Select `full`, `min`, `sim`, or `lemon_bot`. Same as `LEMON_PROFILE`. |
| `--force` | Reinstall a version that is already present. |
| `--verify` | Boot the installed runtime on ephemeral ports in a throwaway `HOME` and poll `/healthz` before finishing. |
| `--no-modify-path` | Do not edit your shell rc file; print the PATH line instead. |
| `--skip-setup` | Install without starting the setup wizard. |
| `--require-bot` | Worker hosts: install only the `full` or `min` runtime (never `lemon_bot`, `sim`, or the TUI) and refuse to promote it unless `lemon node capabilities --json --require-bot --expected-version <manifest version>` passes on the staged tree. |
| `--resolve-version` | Print the version this run would install, then exit. |
| `--help` | Show usage. |

Pass flags through the pipe with `sh -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh -s -- --skip-setup
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `LEMON_VERSION` | *(latest stable)* | Pin an exact version. Required for `preview` and `nightly`. A pin alone accepts whichever channel its manifest publishes. |
| `LEMON_CHANNEL` | `stable` | Release channel. When set explicitly it must match the manifest, even with a pin. |
| `LEMON_PROFILE` | `lemon_runtime_full` | `full`, `min`, `sim`, `lemon_bot`, or a full profile name. |
| `LEMON_NO_TUI` | *(unset)* | `1` installs the runtime only, skipping the terminal UI download. |
| `LEMON_INSTALL_IGNORE_GLIBC` | *(unset)* | `1` silences the Linux glibc 2.39 baseline warning. |
| `LEMON_INSTALL_BASE_URL` | `https://github.com/z80dev/lemon` | Release host override, for mirrors and tests. Plain `http://` is accepted with a warning. |

Environment variables apply to `sh`, not `curl`. Install a specific preview
release like this:

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh \
  | LEMON_VERSION=2026.10.2 LEMON_CHANNEL=preview sh
```

Every release also publishes a version-scoped `install.sh` and `manifest.json`
under `releases/download/v<VERSION>/`, listed in the [releases
page](https://github.com/z80dev/lemon/releases) assets. See
[Versioning and Channels](release/versioning_and_channels.md) for the channel
model and manifest schema.

### Profiles

| Profile | Contains | Notes |
| --- | --- | --- |
| `full` (`lemon_runtime_full`) | Runtime, local Web UI, simulation dashboard assets, TUI | Default. `lemon web` needs this profile. |
| `min` (`lemon_runtime_min`) | Runtime and TUI | No Web UI. |
| `sim` (`sim_broadcast_platform`) | LemonSim broadcast platform | Linux only, no TUI, no setup wizard. |
| `lemon_bot` | Standalone [Lemon Bot](../products/lemon_bot/README.md) backend | Installs under `~/.lemon/lemon_bot` and links `~/.local/bin/lemon-bot`; state stays in `~/.lemon/lemon_bot`. |

### Install layout

| Path | Contents |
| --- | --- |
| `~/.lemon/versions/<version>/` | One extracted release: `bin/`, `lib/`, and `tui/bin/lemon-tui` |
| `~/.lemon/versions/current` | Symlink to the active version; the only thing updates move |
| `~/.lemon/bin/lemon` | Launcher symlink to `../versions/current/bin/lemon` |
| `~/.lemon/config.toml` | Your configuration (written by setup) |
| `~/.lemon/store/` | Durable store |
| `~/.lemon/run/` | Daemon pid, logs, and the managed control-plane credential |
| `~/.lemon/agent/` | Sessions, assistant workspace, skills |
| `~/.lemon/updates/` | Update receipts and checkpoints |
| `~/.lemon/tmp/` | Installer downloads and staging |

`~/.lemon/secrets_master_key` (Linux, when file-backed) and the macOS Keychain
entry **Lemon Secrets** hold the key for encrypted secrets.

### Prerequisites and PATH

The installer needs `curl`, `tar`, and `python3`. `python3` reads the manifest
and performs the atomic symlink flip, so `jq` is not required. On macOS,
`xcode-select --install` provides it; on Debian-family Linux, `sudo apt-get
install python3`. The installer does not need Elixir, Erlang, Bun, or Node.js.

To add the launcher to PATH yourself:

```bash
export PATH="$HOME/.lemon/bin:$PATH"
```

## Headless and non-interactive installs

The installer starts setup only for `full` and `min`, and only when it can open
`/dev/tty`. With no TTY it installs, prints `$HOME/.lemon/bin/lemon setup`, and
exits 0. With `--skip-setup` it never opens the wizard. Configure the provider
afterwards with explicit values:

```bash
lemon setup --non-interactive
lemon model --non-interactive --provider anthropic --token "$ANTHROPIC_API_KEY" \
  --model claude-sonnet-4-20250514 --set-default
lemon doctor
```

`lemon model` runs offline configuration checks and makes no provider request.
For the live credential check, use `lemon setup provider` with the same flags;
add `--skip-verify` to defer it. See [Set up Lemon](user-guide/setup.md#automated-or-headless-configuration).

Run the runtime as a background service with `lemon daemon`, check it with
`lemon status`, and stop it with `lemon stop`. A packaged install reads
`LEMON_CONTROL_PLANE_PORT` (default 4040), `LEMON_WEB_PORT` (4080) and
`LEMON_SIM_UI_PORT` (4090); ports chosen by `lemon setup` are saved to
`~/.lemon/ports.env` and fill in whichever of those are unset.

## Optional Telegram or Discord

Messaging channels are optional. Get a first chat working in the terminal, then:

```bash
lemon gateway setup              # pick an adapter
lemon gateway setup telegram
lemon gateway setup discord
lemon channels                   # redacted status of both
```

Setup stores bot tokens in encrypted secrets, verifies them, and writes the
config. See [Set up Lemon](user-guide/setup.md#optional-telegram-or-discord).

## Browser interface

The `full` profile includes a local browser interface:

```bash
lemon web              # reuses a healthy runtime or starts one, then opens the page
lemon web --no-open    # print the URL only (SSH, headless)
```

`lemon web` waits for the Web health check before opening the browser. It is not
available in `min`; reinstall with `LEMON_PROFILE=full` to add it. See
[Use Lemon in a Browser](user-guide/web.md).

## Container image

Releases publish a multi-arch (`linux/amd64`, `linux/arm64`) image of the `full`
runtime to `ghcr.io/z80dev/lemon`, tagged by exact version, by channel (`stable`,
`preview`, `nightly`), and `latest` for stable
(`.github/workflows/release.yml`, `docker/Dockerfile.runtime`). The image runs
as a non-root user, keeps all state on the `/data` volume (`HOME=/data`), exposes
ports 4040 (control plane), 4080 (Web) and 4090 (simulation UI), and has a
`/healthz` health check.

Modeled on the release CI smoke test, which waits for `/healthz` on ports 4040
and 4080. Generate the master key once with `openssl rand -base64 32` (Lemon
rejects passphrase-like values), store it somewhere safe, and pass the same
value on every start; it decrypts the secrets kept on the volume:

```bash
docker run -d --name lemon \
  -p 127.0.0.1:4040:4040 -p 127.0.0.1:4080:4080 \
  -v lemon-data:/data \
  -e LEMON_SECRETS_MASTER_KEY="<your base64 key>" \
  ghcr.io/z80dev/lemon:latest
curl -fsS http://127.0.0.1:4040/healthz
```

If `LEMON_WEB_SECRET_KEY_BASE` or `LEMON_GATEWAY_NODE_COOKIE` is unset, the
entrypoint generates one, warns, and stores it in `/data/.lemon/env`; set
`LEMON_REQUIRE_SECRETS=1` to make missing values a startup error. Pin a version
tag for production. Container installs are not managed by `lemon update`; replace
the image instead. Volumes, secrets, and backups for container deployments are
covered in [Deployment flows](release/deployment_flows.md).

## Mac app

On macOS, `install.sh` on Apple Silicon gives you the runtime, the terminal UI,
and `lemon web`; everything above works there.

The native macOS application is **Lemon Bot**, a separate product
(`products/lemon_bot/apple/LemonBotMac`, macOS 14+) that connects to a running
Lemon controller and a Lemon Bot backend. The release workflow does not publish
a signed `.dmg`, application `.zip`, or `.ipa`
([Apple application prerequisites](release/versioning_and_channels.md#apple-application-prerequisites)),
so there is no downloadable Mac app to install yet. To build it yourself you
need Xcode 26.3 and XcodeGen 2.46+; follow the
[Apple build guide](https://github.com/z80dev/lemon/blob/main/products/lemon_bot/apple/README.md#generate-build-and-launch)
and the [Lemon Bot README](https://github.com/z80dev/lemon/blob/main/products/lemon_bot/README.md#running-an-integrated-checkout).
Run `lemon setup` on the controller first; the app never receives Lemon's
operator credential.

## Source development

Use a source checkout to develop Lemon, run on an unsupported platform, or build
release artifacts. These requirements apply only to source installs:

- Elixir 1.19.5+ and Erlang/OTP 28.5+
- Bun 1.3.14+ for the terminal client
- Node.js 24 LTS+ for the browser client and this documentation site

```bash
git clone https://github.com/z80dev/lemon.git
cd lemon
mix local.hex --force
mix deps.get
mix compile
./bin/lemon setup
./bin/lemon doctor
./bin/lemon              # interactive terminal: TUI, starting a daemon if needed
```

The source wrapper `./bin/lemon` dispatches the same command registry as the
installed `lemon`, so every command in these docs works as `./bin/lemon <command>`.
Differences:

- The first `./bin/lemon` TUI launch installs the TUI's dependencies with
  `bun install --frozen-lockfile` if `clients/tui/node_modules` is missing, and
  compiles the project when needed.
- `./bin/lemon start` accepts `--port`, `--web-port`, `--sim-port`, `--name`,
  `--sname`, `--cookie`, `--debug` and `--no-distribution`; see
  `./bin/lemon start --help`.
- `./bin/lemon update plan|apply|rollback` fail closed; update with your Git
  workflow (see [Source checkouts](user-guide/updates.md#source-checkouts-and-other-layouts)).
- Commands that only exist in packaged releases (`remote`, `eval`, `rpc`) are not
  available.

`./bin/lemon-tui` remains the development TUI entry point. When it starts a
fresh runtime, the launcher generates an in-memory operator token for the TUI
and stops that runtime when the TUI exits. A runtime started with
`./bin/lemon daemon` receives a private, port-scoped credential at
`~/.lemon/run/control-plane-<port>.token` that later TUI launches load after
validating ownership, mode `0600`, and format. An explicit
`LEMON_CONTROL_PLANE_OPERATOR_TOKEN` is never persisted, so a runtime started
with one still needs it when attaching.

Run source checks with `scripts/test help` and `scripts/verify_source_install`;
see [Testing](testing.md).

### Switching between releases and source with `lemonup`

`bin/lemonup` switches the `lemon` on your PATH (`~/.lemon/bin/lemon`) between
installed releases and a source checkout. Config, secrets, and the store in
`~/.lemon` are shared by every selection. `lemonup` belongs to a checkout: it
installs releases with that checkout's `install.sh` and defaults `use local` to
that checkout, so the installer does not place it for you. Link it next to the
launcher:

```bash
ln -s "$PWD/bin/lemonup" ~/.lemon/bin/lemonup

lemonup list                      # installed releases and this checkout; * is active
lemonup current
lemonup use local                 # run from source (this checkout, compiled on demand)
lemonup use local .worktrees/foo  # or another checkout/worktree
lemonup use 2026.10.2             # back to an installed release
lemonup install 2026.10.1         # download via this checkout's install.sh and activate
lemonup update                    # latest stable release: install if missing, then activate
lemonup uninstall 2026.10.1       # delete a release that is not versions/current
```

Release selection moves only `versions/current`, the pointer `lemon update`
manages; `local` repoints `~/.lemon/bin/lemon` at the checkout's `bin/lemon` and
leaves `versions/current` alone. Releases and source keep different daemon
records, so when a runtime answers on the control port, `lemonup` stops it with
the active launcher and starts it again with the new selection; if the stop
fails, nothing is switched. `lemonup` refuses to replace a `~/.lemon/bin/lemon`
it did not create.

`lemonup update` asks `install.sh --resolve-version` for the latest stable
release, ignoring `LEMON_VERSION` and `LEMON_CHANNEL`. If that release is already
active it reports so and exits 0; if it is installed it is activated like
`lemonup use`; otherwise it is installed like `lemonup install <version>`. It
works from any selection, including `local`, and a failed install leaves the
previous selection active. Compare it with `lemon update`, which adds a plan
digest, checkpoint, and rollback receipts but runs only from an installed
release: see [Update, roll back, and uninstall](user-guide/updates.md).

## Update and uninstall

Installer-managed releases update with a preview-confirm lifecycle. Nothing is
downloaded or written until you confirm the exact plan, and a checkpoint lets
you roll back:

```bash
lemon update check
lemon update plan
lemon update apply --confirm <exact-plan-digest>
lemon status
```

Apply restarts a daemon that was already running onto the new release; it does
not start one that was stopped. Update never touches your config, secrets,
sessions, memory, or store. The full contract, rollback
(`lemon update history`, `lemon update rollback`), source-checkout and mirror
behavior are in [Update, roll back, and uninstall](user-guide/updates.md).

There is no `lemon uninstall`; removal is deleting `~/.lemon/versions`,
`~/.lemon/bin`, and the PATH line the installer added, with an optional
full-data removal. See [Uninstall](user-guide/updates.md#uninstall) before
deleting `~/.lemon`, which also holds your configuration, secrets, and the
default `~/.lemon/backups/`; write any backup you want to keep outside
`~/.lemon` with `lemon backup create --output <path>`.

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| `lemon: command not found` | Open a new terminal, or `export PATH="$HOME/.lemon/bin:$PATH"`. Use `$HOME/.lemon/bin/lemon` directly to check the install. |
| `python3 is required to read the release manifest` | Install `python3` (`xcode-select --install` on macOS), or use a source install. |
| `no prebuilt Lemon release for <os> <arch>` | Use WSL, the container image, or a source install. |
| `channel 'preview' needs an explicit version` | Set `LEMON_VERSION` to the exact preview or nightly version. |
| `checksum mismatch` or `size mismatch` | Nothing was installed. Retry; if it repeats, report the version. |
| glibc warning on Linux | Releases target glibc 2.39+. Use the container or a source install, or set `LEMON_INSTALL_IGNORE_GLIBC=1` if you accept the risk. |
| `No interactive terminal` from `lemon` | Bare `lemon` needs a TTY. Use `lemon -p "PROMPT"`, `lemon daemon`, or `lemon --help`. |
| `TUI not installed` | The release is sim-only or was installed with `LEMON_NO_TUI=1`. Reinstall with `--force` without that variable. |
| `Web UI is available only in the lemon_runtime_full profile` | Reinstall with `LEMON_PROFILE=full`. |
| Setup was interrupted | Run `lemon setup`; it keeps completed steps and offers pending ones. |
| Anything else | `lemon doctor`, then `lemon logs`. See [Support](support.md) for redacted bundles. |
