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

The installer adds `~/.lemon/bin` to PATH for new shells; then use `lemon`.
That is your first chat. The TUI starts the daemon when needed. To use a local
browser instead, run `lemon web`; it starts the full runtime when needed,
checks the same readiness state, and opens the page only after Web health is
confirmed. Full installer
behavior, including platform support and updates, is in the
[Install guide](../install.md).

## What setup does—and does not do

`lemon setup` is an idempotent first-time configuration wizard. On each run it
re-checks the saved state, performs pending work, and re-verifies an existing provider:

1. creates a minimal config scaffold if no config exists;
2. initializes encrypted secrets if they are not configured, without replacing
   an existing key;
3. onboards a provider, auth credential, and default provider/model;
4. checks the resulting configuration and credential, including a live provider
   check when supported;
5. offers an opt-in daily brief (default: off); and
6. offers optional runtime-profile configuration.

Pasted API keys are read with terminal echo disabled; echo is restored after the
read, including on errors or closed input. Without an interactive terminal, setup
fails before prompting. Use `lemon setup --non-interactive` to prepare config and
secrets, then a flag-driven provider command as shown below.

Declining provider onboarding leaves **pending steps**, not a failed step. The
wizard only prints **Setup complete** after a passing live credential check.
When the check is skipped or unsupported, it explicitly says the provider was
not live-verified; local configuration can still be saved successfully.

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

The browser is also fail-closed. `lemon web` may start before setup is complete
so the page can explain what is missing, but the page disables prompts and
uploads until config, secure secrets, and a usable provider/model are all
ready. After setup changes, choose **Check again**; a running Web client also
refreshes on config and secret change events. See the [browser guide](web.md).

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

The full wizard always selects a default provider/model; `setup provider`
accepts `--set-default` to request this explicitly. Both `--set-default` and
`--daily-brief HH:MM` appear in `lemon setup --help`.

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
lemon model --non-interactive --provider anthropic --token "$ANTHROPIC_API_KEY" \
  --model claude-sonnet-4-20250514 --set-default
lemon doctor
```

`lemon model` uses the local configuration checks and does not make a provider
network request. When network access is available and you need the live check,
use the corresponding provider setup command instead:

```bash
lemon setup provider --non-interactive --provider anthropic --token "$ANTHROPIC_API_KEY" \
  --model claude-sonnet-4-20250514 --set-default
```

Append `--skip-verify` to that command to defer only the live check.

Pass a bare model id such as `claude-sonnet-4-20250514`, not
`anthropic:claude-sonnet-4-20250514`, to onboarding's `--model`. Runtime model
overrides elsewhere use the `provider:model` form.

### Daily brief

After the provider step, setup asks whether you want a short daily brief on
your phone each morning (default: no), explains that this needs a paired
Telegram chat (`lemon gateway setup telegram`), and asks for a time (`HH:MM`,
24-hour, this machine's local time; default `08:00`). The answer is written as
`daily_brief` under `[automation]` in your config and takes effect the next time
Lemon starts. If a brief is already configured, setup only reports its time.

The non-interactive setup skips the question unless you pass the time:

```bash
lemon setup --non-interactive --daily-brief 07:30
```

The brief is delivered to your paired chat, so pair Telegram (see below). To
change or remove it, edit `[automation] daily_brief` and restart Lemon. See
[Reminders, heartbeats, and the daily brief](reminders-and-heartbeats.md).

### Runtime profile and ports

`lemon setup runtime` offers `runtime_min` and `runtime_full` and prints the
environment settings to apply. Invalid interactive profile or port input is
explained and asked again; an invalid flag is an error, not a fallback.
Ports must be integers from 1 to 65535.

```bash
lemon setup runtime --non-interactive --profile runtime_min \
  --control-port 5050 --web-port 5080 --sim-port 5090
```

## Verify and recover

After setup, inspect the persisted configuration and secret state, then run
local diagnostics:

```bash
lemon config validate
lemon secrets status
lemon doctor
```

If validation or doctor warns about deprecated settings such as an `[agent]`
table, run `lemon config migrate`: it rewrites them to the current schema and
keeps the original as `config.toml.bak-<timestamp>`. `lemon setup` does this
automatically for an existing config.

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

Both adapters store the bot token in encrypted secrets, verify it against the
platform API, restrict the bot to your conversations, and write the config for
you. Restart Lemon afterwards (`lemon restart`).

Telegram pairs the bot with your chat. After the token check, setup asks you to
send `/start` to the bot, waits up to two minutes (`--pair-timeout SECONDS`),
and writes `enable_telegram = true`, `bot_token_secret`, and
`allowed_chat_ids = [<your chat id>]`. For scripted installs pass the chat id
instead of waiting:

```bash
lemon gateway setup telegram --non-interactive --token "$TELEGRAM_BOT_TOKEN" --chat-id 12345678
```

A Telegram bot without `allowed_chat_ids` is unpaired: it ignores every chat and
only replies with a pairing hint. Send `/whoami` to the bot to see a chat's id
(for example, to add a group with another `--chat-id`). Group chats respond only
to mentions, replies, and commands unless an admin sends `/trigger all`, and every
file edit or shell command in a group needs an approval. Remote chats run in the
assistant home (`~/.lemon/agent/workspace`), not your home directory, unless
`gateway.default_cwd` is set.

The first paired Telegram chat is also your owner chat: reminders, heartbeats,
the daily brief, and other scheduled results created outside a chat are sent
there. In a paired chat, `/remind <when> <what>` sets a reminder. See
[Reminders, heartbeats, and the daily brief](reminders-and-heartbeats.md).

### Images in Telegram and Discord

Send a Telegram photo or a document with an `image/*` MIME type to give a
vision-capable model the image itself, not just an attachment link. Captions
remain the prompt; a photo without a caption uses `[image]`. For Telegram
photos, Lemon selects the largest available dimensions whose declared size
fits the limit.

Discord image attachments are fetched only over HTTPS from
`cdn.discordapp.com` or `media.discordapp.net`; redirects are not followed.
Attachment URLs remain in the prompt, including non-image files and images
that could not be fetched.

Image input uses fixed safety limits: **5 MiB per image** and **four images per
message/submission**. Downloads stop at the byte limit. Failed or oversized
images leave the text intact and add a short image-unavailable note; they do
not stop the message from being submitted. Telegram messages combined by the
debounce buffer share the four-image limit. Group mention/reply rules still
apply. Existing Telegram `/file put` and configured file auto-put workflows
keep their file-transfer behavior (upload-only mode does not start a model
run). The selected model must support image input.

Inspect redacted channel configuration (enabled state, credentials, binding and
allowlist counts, registered transports) with:

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
  --model claude-sonnet-4-20250514 --set-default
```

`./bin/lemon-tui` is the source-development TUI entry point once the source
runtime is configured. A fresh launcher-owned runtime receives a generated,
process-scoped operator token and is stopped when the TUI exits. Attaching to
an existing or persistent runtime requires exporting its matching
`LEMON_CONTROL_PLANE_OPERATOR_TOKEN`; the launcher does not read or persist the
daemon's credential.

Supplying a token does not make a runtime started by `./bin/lemon-tui`
persistent: the launcher still stops it when the client exits. Start
`./bin/lemon daemon` separately, then attach with the same token, when the
runtime should outlive the TUI.
