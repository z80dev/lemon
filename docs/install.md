# Install Lemon

Last reviewed: 2026-08-18

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

The installer prints the PATH entry for its launcher. Once `~/.lemon/bin` is
on your `PATH`, use `lemon` for this and the commands below. `lemon` starts the
daemon when needed. If provider readiness is incomplete at a first interactive
launch, it opens setup before starting the daemon. If it cannot open a
terminal, it leaves the daemon stopped and tells you to run `lemon setup` from
an interactive terminal.

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
  --model anthropic:claude-sonnet-4-20250514 --set-default
lemon doctor
```

`lemon model` performs the offline-strong configuration checks but does not
make a provider network request. Where a live provider credential check is
wanted, use the setup-provider flow instead:

```bash
lemon setup provider --provider anthropic --token "$ANTHROPIC_API_KEY" \
  --model anthropic:claude-sonnet-4-20250514 --set-default
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
| `--modify-path` | Add the printed PATH entry to the appropriate shell rc file. |
| `--skip-setup` | Do not start the post-install setup wizard. |

| Variable | Default | Purpose |
| --- | --- | --- |
| `LEMON_VERSION` | *(latest stable)* | Pin an exact release version. Required for non-stable channels. |
| `LEMON_CHANNEL` | `stable` | Release channel. `preview` and `nightly` also require `LEMON_VERSION`. |
| `LEMON_PROFILE` | `lemon_runtime_full` | `full`, `min`, or `sim`, or the full profile name. |
| `LEMON_NO_TUI` | *(unset)* | Set to `1` to omit the TUI artifact. `sim` is runtime-only. |
| `LEMON_INSTALL_IGNORE_GLIBC` | *(unset)* | Silence the Linux glibc baseline warning. |

The installed launcher is `~/.lemon/bin/lemon`; updates atomically move only
`~/.lemon/versions/current`. Your configuration, encrypted secrets, and store
remain in place. Add the launcher to your PATH if needed:

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
  --model anthropic:claude-sonnet-4-20250514 --set-default
./bin/lemon gateway setup telegram
./bin/lemon gateway setup discord
./bin/lemon config validate
./bin/lemon secrets status
./bin/lemon channels
./bin/lemon doctor
```

The source wrapper follows the same setup and provider behavior described
above. `./bin/lemon-tui` is the development TUI entry point after the source
runtime is configured. When it starts a fresh runtime, the launcher generates
and shares an in-memory operator token with the TUI, then stops that owned
runtime when the TUI exits.

Persistent runtimes started with `./bin/lemon --daemon` receive a private,
port-scoped credential at `~/.lemon/run/control-plane-<port>.token`; later TUI
launches load it automatically after validating ownership, mode 0600, and
format. Explicit `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` values are not persisted,
so runtimes started with one still require it when attaching. Every runtime
started by `./bin/lemon-tui` is stopped with the TUI, even when a token was
preconfigured.

## Browser interface

The full release profile also includes a local browser interface. The launcher
reuses a healthy runtime on the configured local control-plane port, starts the
daemon only when necessary, waits for the Web health check, prints the URL, and
opens the default browser:

```bash
lemon web
```

Use `lemon web --no-open` on SSH/headless systems. A source checkout uses
`./bin/lemon web`; invoking `./bin/lemon` beside an already healthy source
runtime also reports and reuses it instead of registering a duplicate Erlang
node. The browser checks the same config, secrets, provider,
credential, and model readiness as setup. If anything is missing it lists the
pending items, disables prompt/file submission, and points back to `lemon
setup`; it never waits for a failed agent request to explain first-run setup.

The Web UI is not bundled in `lemon_runtime_min`. Reinstall with
`LEMON_PROFILE=full` when browser access is wanted. See
[Use Lemon in a Browser](user-guide/web.md) for access control and recovery.
