# Set up Lemon

For a prebuilt Lemon install, the shortest path is one command followed by the
interactive setup handoff:

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh
```

The installer verifies and installs the release, then starts `lemon setup` for
`full` and `min` profiles when it can read `/dev/tty`. Complete the provider,
authentication, and default-model prompts, then start the TUI:

```bash
$HOME/.lemon/bin/lemon
```

The installer prints the PATH entry; after adding `~/.lemon/bin`, use `lemon`.
That is your first chat. The TUI starts the daemon when needed. Full installer
behavior, including platform support and updates, is in the
[Install guide](../install.md).

## What setup does—and does not do

`lemon setup` is an idempotent first-time configuration wizard. On each run it
re-checks the state and performs only pending work:

1. creates a minimal config scaffold if no config exists;
2. initializes encrypted secrets if they are not configured, without replacing
   an existing key;
3. onboards a provider, auth credential, and default provider/model;
4. checks the resulting configuration and credential, including a live provider
   check when supported; and
5. offers optional runtime-profile configuration.

It does not install source dependencies, configure Telegram or Discord, start
a gateway, or run `lemon doctor` automatically. Rerun it whenever setup is
incomplete:

```bash
lemon setup
```

If the first interactive `lemon` launch detects that a usable provider is not
ready, it opens this setup flow before starting the daemon. If no controlling
terminal is available, it does not start an unconfigured daemon; run `lemon
setup` later from an interactive terminal.

### Provider, auth, and model

The wizard presents the supported providers and their available authentication
flows. It stores credentials in encrypted secrets and writes secret references,
not a plaintext provider key, to configuration. Select a default provider and
model during the flow so Lemon has a model for your first chat.

To configure or change a provider directly:

```bash
lemon model --provider anthropic
```

For a provider setup that includes the live credential check, use:

```bash
lemon setup provider
```

The live check is deferred with `--skip-verify`, which is useful when you are
deliberately offline. Local checks of the config, selected provider/model, and
stored credential still run:

```bash
lemon setup provider --skip-verify
```

If a provider verification fails, setup remains incomplete. Correct the
credential or model and rerun `lemon setup provider`; do not expect a failed
verification to be treated as a working setup.

### Automated or headless configuration

The installer does not run setup when there is no TTY. It succeeds and prints
`$HOME/.lemon/bin/lemon setup` for a later interactive handoff. To suppress the
wizard even with a TTY, use:

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh -s -- --skip-setup
```

The `sim` profile does not offer a provider setup wizard. For a non-interactive
provider setup, use explicit values:

```bash
lemon setup --non-interactive
lemon model --provider anthropic --token "$ANTHROPIC_API_KEY" \
  --model anthropic:claude-sonnet-4-20250514 --set-default
lemon doctor
```

`lemon model` uses the local configuration checks and does not make a provider
network request. When network access is available and you need the live check,
use the corresponding provider setup command instead:

```bash
lemon setup provider --provider anthropic --token "$ANTHROPIC_API_KEY" \
  --model anthropic:claude-sonnet-4-20250514 --set-default
```

Append `--skip-verify` to that command to defer only the live check.

## Verify and recover

After setup, inspect the persisted configuration and secret state, then run
local diagnostics:

```bash
lemon config validate
lemon secrets status
lemon doctor
```

`lemon doctor` reports diagnostics; it is not a replacement for provider
onboarding. To retry first-time state, use `lemon setup`. To correct a provider
or model, use `lemon setup provider` or `lemon model`.

## Optional Telegram or Discord

A messaging channel is optional. Add one only after the provider path is ready:

```bash
lemon gateway setup
```

The picker includes Telegram and Discord. You can choose either directly:

```bash
lemon gateway setup telegram
lemon gateway setup discord
```

Each adapter guides its required bot token and allowed conversation scope,
stores the token in encrypted secrets, and verifies the adapter configuration.
See the configured channel state with:

```bash
lemon channels
```

## Source development

A source checkout is for development, unsupported platforms, and release work.
Only this path needs the development toolchain:

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

Use the source wrapper for Lemon commands, rather than installed `lemon`
commands:

```bash
./bin/lemon model --provider anthropic
./bin/lemon gateway setup telegram
./bin/lemon gateway setup discord
./bin/lemon config validate
./bin/lemon secrets status
./bin/lemon channels
./bin/lemon doctor
```

For non-interactive source configuration, use the same wrapper forms:

```bash
./bin/lemon setup --non-interactive
./bin/lemon model --provider anthropic --token "$ANTHROPIC_API_KEY" \
  --model anthropic:claude-sonnet-4-20250514 --set-default
```

`./bin/lemon-tui` is the source-development TUI entry point once the source
runtime is configured. A fresh launcher-owned runtime receives a generated,
process-scoped operator token and is stopped when the TUI exits. Attaching to
an existing or persistent runtime requires exporting its matching
`LEMON_CONTROL_PLANE_OPERATOR_TOKEN`; the launcher does not read or persist the
daemon's credential.
