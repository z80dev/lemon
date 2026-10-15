# Install Lemon

Choose a prebuilt release for everyday use, or a source checkout to contribute.
Both paths use the same provider setup and keep your state under `~/.lemon`.

| Path | Best for | What you need |
| --- | --- | --- |
| [Prebuilt release](#install-and-start-your-first-chat) | Start using Lemon | `curl`, `tar`, `python3`, and provider credentials |
| [Source development](#source-development) | Change Lemon or build it yourself | Elixir, Erlang/OTP, and the relevant client toolchain |

Release targets are **macOS Apple Silicon**, **Linux x86_64**, and **Linux
ARM64**. Linux builds target glibc 2.39 or newer; the simulation profile is
Linux-only. See [installer details](#installer-details) for compatibility and
profile options.

Want a guided first run? Follow the [quickstart](getting-started/quickstart.md).

## Install and start your first chat

From an interactive terminal, install Lemon with one command:

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh
```

The installer downloads the release for your platform, verifies its SHA-256
against the release manifest, and installs it under `~/.lemon`. For the `full`
and `min` profiles, it then opens `lemon setup` on `/dev/tty`; piping the
installer through `sh` does not prevent the wizard from being interactive.

The setup wizard is safe to rerun. It creates a config scaffold only when one
is missing, initializes encrypted secrets when needed, and guides provider,
authentication, and default-model configuration. It verifies the resulting
provider configuration; it does **not** install development dependencies,
configure a messaging gateway, or run the general doctor command for you.

When setup completes, start the interactive TUI and send your first message:

```bash
$HOME/.lemon/bin/lemon
```

The installer adds `~/.lemon/bin` to PATH in your shell rc file (zsh, bash or
fish), so new terminals find `lemon`. In an interactive terminal,
invoking `lemon` with no arguments opens the TUI; without a TTY it prints usage
and exits. The TUI runs setup when required, starts a daemon if needed, and
then attaches. Use `lemon start` to run the runtime in the foreground.

## Installer handoff and non-interactive installs

The default installer starts setup only for `full` and `min` profiles and only
when it can open `/dev/tty`.

- Pass `--skip-setup` to install without opening the wizard:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh -s -- --skip-setup
  ```

- With no TTY, the install succeeds without blocking and prints the exact
  command to run later: `$HOME/.lemon/bin/lemon setup`.
- The `sim` profile has no provider setup wizard.

For an automated or headless provider configuration, first create the local
setup state, then supply the provider credential and default model explicitly:

```bash
lemon setup --non-interactive
lemon model --provider anthropic --token "$ANTHROPIC_API_KEY" \
  --model claude-sonnet-4-20250514 --set-default
lemon doctor
```

`lemon model` performs the offline-strong configuration checks but does not
make a provider network request. Where a live provider credential check is
wanted, use the setup-provider flow instead:

```bash
lemon setup provider --provider anthropic --token "$ANTHROPIC_API_KEY" \
  --model claude-sonnet-4-20250514 --set-default
```

That flow verifies the provider configuration and performs its live check when
the provider supports one. When deliberately offline, append `--skip-verify`;
the configuration, model, and stored credential are still checked, while the
live request is deferred.

Useful recovery and inspection commands are:

```bash
lemon setup
lemon config validate
lemon secrets status
lemon doctor
```

## Optional Telegram or Discord

Messaging channels are optional; configure a provider and use the TUI first if
that is all you need. To add a bot later, choose an adapter interactively or
name one directly:

```bash
lemon gateway setup
lemon gateway setup telegram
lemon gateway setup discord
lemon channels
```

`lemon channels` inspects redacted Telegram and Discord configuration status,
including enabled state, configured credentials, binding and allowlist counts,
and registered transports.

The Telegram and Discord setup adapters store their bot tokens in encrypted
secrets, write their configuration, and verify the adapter inputs. Follow the
prompt for the allowed Telegram chat or Discord channel scope.

## Installer details

Prerequisites for the prebuilt installer are `curl`, `tar`, and `python3`.
`python3` reads the release manifest and performs the atomic symlink flip; no
`jq` is required. On macOS, `xcode-select --install` provides it.

Linux releases target glibc 2.39 or newer. The installer warns and continues on
older or non-glibc systems; set `LEMON_INSTALL_IGNORE_GLIBC=1` to silence that
warning.

| Flag | Effect |
| --- | --- |
| `--force` | Reinstall a version already present. |
| `--verify` | Boot the installed runtime on ephemeral ports and poll `/healthz` before finishing. |
| `--no-modify-path` | Do not add `~/.lemon/bin` to PATH in your shell rc file; only print the line. |
| `--skip-setup` | Do not start the post-install setup wizard. |
| `--require-bot` | Worker hosts: install only the full or min runtime (never `lemon_bot`, `sim`, or the TUI), and refuse to promote it unless `node capabilities --json --require-bot --expected-version <manifest version>` passes on the staged tree. |
| `--resolve-version` | Print the version this run would install and exit without installing. |

| Variable | Default | Purpose |
| --- | --- | --- |
| `LEMON_VERSION` | *(latest stable)* | Pin an exact release version. Required for non-stable channels. A pin alone accepts the channel its manifest publishes. |
| `LEMON_CHANNEL` | `stable` | Release channel. `preview` and `nightly` also require `LEMON_VERSION`. When set explicitly it must match the manifest, even with a pin. |
| `LEMON_PROFILE` | `lemon_runtime_full` | `full`, `min`, or `sim`, or the full profile name. |
| `LEMON_NO_TUI` | *(unset)* | Set to `1` to omit the TUI artifact. `sim` is runtime-only. |
| `LEMON_INSTALL_IGNORE_GLIBC` | *(unset)* | Silence the Linux glibc baseline warning. |

The installed launcher is `~/.lemon/bin/lemon`; updates atomically move only
`~/.lemon/versions/current`. Your configuration, encrypted secrets, and store
remain in place. The installer adds the launcher to PATH unless you pass
`--no-modify-path`; to add it yourself:

```bash
export PATH="$HOME/.lemon/bin:$PATH"
```

For lifecycle commands and release verification, see `lemon --help` and
[Versioning and Channels](release/versioning_and_channels.md).

## Updating an installed release

Installer-managed releases use a preview-confirm lifecycle:

```bash
lemon update check
lemon update plan
lemon update apply --confirm <exact-plan-digest>
lemon stop && lemon daemon
```

Plan does not write or download anything. Apply revalidates the exact active
release and manifest under an exclusive lock, creates a verified private
checkpoint, checks artifact size/SHA-256, rejects unsafe archive entries,
verifies the staged launcher's version, and atomically moves only
`versions/current`. Inspect private content-free receipts and roll back the
exact recorded checkpoint with:

```bash
lemon update history
lemon update rollback --receipt <apply-receipt-id> \
  --confirm <rollback-digest>
lemon stop && lemon daemon
```

Update rollback does not restore config, credentials, sessions, memory, or
stores. Schema-2 manifests provide mandatory checksums/sizes but do not yet have
a publisher signature. See [Safely update and roll back Lemon](user-guide/updates.md)
for the full safety and residual contract.

## Source development

Use a source checkout for Lemon development, unsupported platforms, or building
release artifacts yourself. These are source-only requirements; the prebuilt
installer does not require them:

- Elixir 1.19.5+
- Erlang/OTP 28.5+
- Bun 1.3.14+ for TUI client development
- Node.js 24 LTS+ for web client development

```bash
git clone https://github.com/z80dev/lemon.git
cd lemon
mix local.hex --force
mix deps.get
mix compile
./bin/lemon setup
./bin/lemon doctor
./bin/lemon-tui
```

For a source checkout, use the `./bin/lemon` wrapper for Lemon commands:

```bash
./bin/lemon model --provider anthropic --token "$ANTHROPIC_API_KEY" \
  --model claude-sonnet-4-20250514 --set-default
./bin/lemon gateway setup telegram
./bin/lemon gateway setup discord
./bin/lemon config validate
./bin/lemon secrets status
./bin/lemon channels
./bin/lemon doctor
```

The source wrapper follows the same setup and provider behavior described
above. In an interactive terminal, bare `./bin/lemon` opens the TUI; without a
TTY it prints usage. `./bin/lemon start` runs the runtime in the foreground.
`./bin/lemon-tui` remains the development TUI entry point.
When it starts a fresh runtime, the launcher generates and shares an in-memory
operator token with the TUI, then stops that owned runtime when the TUI exits.

Persistent runtimes started with `./bin/lemon daemon` receive a private,
port-scoped credential at `~/.lemon/run/control-plane-<port>.token`; later TUI
launches load it automatically after validating ownership, mode 0600, and
format. Explicit `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` values are not persisted,
so runtimes started with one still require it when attaching. Every runtime
started by `./bin/lemon-tui` is stopped with the TUI, even when a token was
preconfigured.

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
manages; `local` repoints `~/.lemon/bin/lemon` at the checkout's `bin/lemon`
and leaves `versions/current` alone. Releases and source keep different daemon
records, so when a runtime answers on the control port, `lemonup` stops it with
the active launcher and starts it again with the new selection; if the stop
fails, nothing is switched. `lemonup` refuses to replace a `~/.lemon/bin/lemon`
it did not create.

`lemonup update` asks `install.sh --resolve-version` for the latest stable
release, ignoring `LEMON_VERSION` and `LEMON_CHANNEL`. If that release is
already active it reports so and exits 0; if it is installed it is activated
like `lemonup use`; otherwise it is installed like `lemonup install <version>`.
It works from any selection, including `local`, and a failed install leaves the
previous selection active. `lemon update` is the product's own
[preview-confirm update](#updating-an-installed-release): it runs only from an
installed release, refuses to run from source, and adds a plan digest,
checkpoint, and rollback receipts. Use `lemon update` to move a release install
forward with rollback; use `lemonup update` to get onto the latest release from
wherever you are, including a source checkout.

## Browser interface

The full release profile also includes a local browser interface. The launcher
reuses a healthy runtime on the configured local control-plane port, starts the
daemon only when necessary, waits for the Web health check, prints the URL, and
opens the default browser:

```bash
lemon web
```

Use `lemon web --no-open` on SSH/headless systems. A source checkout uses
`./bin/lemon web`; the interactive no-argument source launcher opens the TUI,
which reuses an already healthy runtime instead of registering a duplicate
Erlang node. The browser checks the same config, secrets, provider,
pending items, disables prompt/file submission, and points back to `lemon
setup`; it never waits for a failed agent request to explain first-run setup.

The Web UI is not bundled in `lemon_runtime_min`. Reinstall with
`LEMON_PROFILE=full` when browser access is wanted. See
[Use Lemon in a Browser](user-guide/web.md) for access control and recovery.
