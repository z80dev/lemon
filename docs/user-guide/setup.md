# Set up Lemon

Setup connects Lemon to a model provider and records a default model. For a
prebuilt install it runs automatically at the end of the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh
```

The installer verifies and installs the release, then starts `lemon setup` for
the `full` and `min` profiles when it can read `/dev/tty`. Complete the provider,
authentication, and default-model prompts, then accept **Open Lemon now? [Y/n]**
to start the TUI immediately. To open it later:

```bash
lemon
```

The installer adds `~/.lemon/bin` to PATH for new shells; until you open one,
use `$HOME/.lemon/bin/lemon`. That is your first chat. The TUI starts the daemon
when needed. To use a local browser instead, run `lemon web`; it starts the full
runtime when needed, checks the same readiness state, and opens the page only
after Web health is confirmed. Installer flags, platform support, containers and
source installs are in the [Install guide](../install.md); updating is in
[Update, roll back, and uninstall](updates.md).

Setup writes to `~/.lemon`: `config.toml` for configuration, the encrypted
secrets store for credentials (its master key is kept in the macOS Keychain
entry **Lemon Secrets** or, when file-backed, `~/.lemon/secrets_master_key`),
and the durable store under `~/.lemon/store`. See [Configuration](../config.md)
for the file format.

## What setup does—and does not do

`lemon setup` is an idempotent first-time configuration wizard. On each run it
re-checks the saved state, performs pending work, and re-verifies an existing provider:

1. creates a minimal config scaffold if no config exists;
2. initializes encrypted secrets if they are not configured, without replacing
   an existing key;
3. onboards a provider, auth credential, and default provider/model;
4. checks the resulting configuration and credential, including a live provider
   check when supported;
5. checks the ports the runtime will use and, only if one is taken by another
   program, offers a free one (see [Runtime profile and ports](#runtime-profile-and-ports));
   and
6. shows a first prompt and success check, then offers to open Lemon in an
   interactive terminal after a passing live check.

Setup does not ask about the runtime profile or import Hermes data. The
installer installs the full runtime (`--profile min` selects the minimal one).

Pasted API keys are read with terminal echo disabled; echo is restored after the
read, including on errors or closed input. Without an interactive terminal, setup
fails before prompting. Use `lemon setup --non-interactive` to prepare config and
secrets, then a flag-driven provider command as shown below.

Declining provider onboarding leaves **pending steps**, not a failed step. The
wizard only prints **Setup complete** after a passing live credential check.
When the check is skipped or unsupported, it explicitly says the provider was
not live-verified; local configuration can still be saved successfully.

The finish screen reuses the README's first coding task. Success means a reply
arrives and `lemon doctor` shows no **FAIL**. Get one conversation working before
adding optional Telegram (`lemon gateway setup telegram`) or the browser UI
(`lemon web`). Declining the launch keeps the manual `lemon` command available.
Headless setup never offers or starts the TUI. During bare `lemon`'s first-run
setup, the original launcher opens the TUI afterwards instead of offering a
second launch.

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

An existing scaffold alone does not count as ready: an interrupted provider
setup is offered again on the next interactive launch. This check is offline:
it starts only the core services needed to read encrypted credentials, not the
agent runtime. A startup/read error is reported rather than mistaken for
incomplete setup.
Local presets such as Ollama and custom endpoints with `auth = "none"` do not
need an API key to pass provider readiness; secure secrets setup remains a
separate step.
Provider credentials exported through recognized environment variables (for
example `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`) also satisfy offline readiness,
even without a secret reference in the config.

The browser is also fail-closed. `lemon web` may start before setup is complete
so the page can explain what is missing, but the page disables prompts and
uploads until config, secure secrets, and a usable provider/model are all
ready. After setup changes, choose **Check again**; a running Web client also
refreshes on config and secret change events. See the [browser guide](web.md).

### Coming from Hermes

Setup does not import Hermes data. Run `lemon migrate hermes` after setup to
preview and import an existing `$HERMES_HOME` (or `~/.hermes`). See
[Migrate from Hermes](migrate-from-hermes.md) for the read-only preview,
overwrite policy, and secret-import options.

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
accepts `--set-default` to request this explicitly; it appears in
`lemon setup --help`.

If a provider verification fails, setup remains incomplete. Correct the
credential or model and rerun `lemon setup provider`; do not expect a failed
verification to be treated as a working setup.

Native model IDs retain their colons: with `defaults.provider = "ollama"`,
both `qwen3:32b` and `ollama:qwen3:32b` select model `qwen3:32b`.
Only a known provider or configured custom-provider prefix is qualification;
an explicitly declared full model ID remains literal. For dynamic presets,
discovered full IDs are recognized only in the effective endpoint/credential/
header cache scope, never an unrelated default/environment cache. Setup applies
the same rule to effective `LEMON_DEFAULT_MODEL` overrides, accepts provider
aliases, and refuses real foreign-provider qualification before any HTTP request.
Local readiness is dependency-free and recognizes only configured provider
names (case and `-`/`_` variants); it does not own the runtime provider/alias
catalog. With `--skip-verify`, identity checks use locally configured prefixes
rather than resolving credentials to disambiguate dynamic preset caches.
A local ready state or skipped live check alone is not proof that a
runtime-qualified selector or effective override passed live setup verification.

### Local servers and custom endpoints

`lemon setup` and `lemon setup provider` include **local server** entries for
Ollama, LM Studio, llama.cpp, vLLM, and LiteLLM. Their API key is optional:
press Enter to save keyless authentication, or enter a key to store it in
encrypted secrets. You can also select **Custom OpenAI-compatible endpoint**,
choose a new provider name, and enter its API base URL (usually ending in `/v1`).
Setup writes `[providers.<name>]` with `api = "openai_completions"` and
`auth = "none"` when no key is supplied.

When selecting a local default model, setup asks before probing the selected
server's `GET {base_url}/models` endpoint. **No is the default**. Accept to pick
from discovered model IDs, or decline and type a model ID. An unreachable or
empty server also falls back to manual entry. Native IDs such as `qwen3:8b`
are accepted. Passing `--model` skips discovery entirely.

```bash
lemon setup provider --provider ollama --set-default
lemon model --provider lm-studio --set-default
# Headless: no discovery or prompts, no key required:
lemon model --non-interactive --provider ollama --set-default --model qwen3:8b
```

Headless setup accepts local presets but never probes for models. Custom
endpoint creation is interactive; for automated custom configuration, use the
[provider TOML reference](../config.md#custom-providers-and-models).
Discovery consent is separate from setup's existing live verification:
`lemon setup` / `lemon setup provider` still run their models-list live check
when verification is enabled, including for keyless servers. Use `--skip-verify`
to defer that check; `lemon model` does not run live verification.

### Automated or headless configuration

The installer does not run setup when there is no TTY. It succeeds and prints
`$HOME/.lemon/bin/lemon setup` for a later interactive handoff. To suppress the
wizard even with a TTY, use:

```bash
curl -fsSL https://raw.githubusercontent.com/z80dev/lemon/main/install.sh | sh -s -- --skip-setup
```

For a non-interactive provider setup, use explicit values:

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

### Runtime profile and ports

The installer picks the profile: full by default, minimal with
`sh install.sh --profile min`. Setup never asks about ports unless one is
taken. The full runtime uses 4040 (control plane) and 4080 (web UI); the
minimal runtime uses only 4040. If another program already listens on one of
them, setup offers the next free port (`Use 4041 instead? [Y/n]`). Declining
lets you enter a port; non-interactive setup takes the suggestion
automatically. Ports held by an already running Lemon are left alone.

The choice is saved to `~/.lemon/ports.env`. The `lemon` launcher loads that
file into any of `LEMON_CONTROL_PLANE_PORT`, `LEMON_WEB_PORT` and
`LEMON_SIM_UI_PORT` that are unset, so the daemon, TUI, `lemon web` and CLI
commands all use it. A port exported in your shell still wins.

To change ports later, run `lemon setup runtime`, which saves them to the same
file. Invalid interactive profile or port input is explained and asked again;
an invalid flag is an error, not a fallback. Ports must be integers from 1 to
65535.

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
and other scheduled results created outside a chat are sent there. In a paired
chat, `/remind <when> <what>` sets a reminder. See
[Reminders and heartbeats](reminders-and-heartbeats.md).

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

### Channel commands

Send `/help` or `/commands` in the bot conversation to see commands accepted by
that platform, including aliases. Telegram also populates the bot's `/` menu at
startup from the same catalog. Admin-only controls are excluded from the public
menu; a menu entry does not bypass chat authorization or command permissions.
If Telegram rejects menu registration, the transport still starts and typed
commands remain available.

Both Telegram and Discord support `/model`, `/resume`, `/file`, `/checkpoint`,
`/rollback`, `/goal`, `/kanban`, and `/media`, alongside `/queue`, `/steer`,
`/status`, `/usage`, `/agents`, `/compress`, `/bg`, and `/btw`.
Use `/new` on Telegram or `/session new` on Discord to start fresh; `/reset`
works on both. `/cancel` and `/stop` cancel the active run.
Telegram additionally offers `/whoami`, `/remind`, `/reminders`, and `/unremind`.
Discord offers `/lemon <prompt>`, `/session info`, and `/redirect <correction>`.
These lists describe discovery only: existing authorization and command behavior
are unchanged.

## Source development

A source checkout is for development, unsupported platforms, and release work.
Only this path needs the development toolchain (Elixir 1.19.5+, Erlang/OTP
28.5+, Bun 1.3.14+, and Node.js 24 LTS+ for the web client); see
[Install: source development](../install.md#source-development).

```bash
git clone https://github.com/z80dev/lemon.git
cd lemon
mix local.hex --force
mix deps.get
mix compile
./bin/lemon setup
./bin/lemon doctor
./bin/lemon
```

Use the source wrapper in place of installed `lemon` for every command in this
guide:

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

`./bin/lemon-tui` is the development TUI entry point. A runtime it starts itself
receives a generated, process-scoped operator token and is stopped when the TUI
exits, even if you supplied a token. When a runtime is already healthy, the
launcher loads the private, port-scoped credential of a `./bin/lemon daemon`
runtime from `~/.lemon/run/control-plane-<port>.token`; for a runtime started
another way, export its `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` before attaching.
Start `./bin/lemon daemon` separately when the runtime should outlive the TUI.

## Troubleshooting setup

| Symptom | What to do |
| --- | --- |
| Setup exits before prompting | It needs an interactive terminal. In scripts, use `lemon setup --non-interactive` and then `lemon model --non-interactive ...` ([headless configuration](#automated-or-headless-configuration)). |
| Provider verification failed | Setup stays incomplete. Fix the credential or model, rerun `lemon setup provider`, or defer the live check with `--skip-verify` when offline. |
| Not sure what is configured | `lemon config validate`, `lemon secrets status`, `lemon providers status`. |
| Revoked key or connectivity problem | `lemon doctor --live --verbose` makes bounded, non-generating requests. |
| First `lemon` launch asks for setup again | An interrupted provider setup is offered again on the next interactive launch; finish it with `lemon setup`. |
| Start over | Rerun `lemon setup`. To change provider or model only, use `lemon model` or `lemon setup provider`. |
