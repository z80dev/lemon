# Lemon CLI

`lemon_cli` is the user-facing command boundary for packaged Lemon releases.
`LemonCli.CLI.main/1` is the one process-halting boundary: it receives the
forwarded argument vector from the release launcher and turns dispatch results
into exit codes. Its non-halting `run/1` and command handlers are shared by
tests and source-checkout Mix adapters, so release commands do not depend on
Mix at runtime.

The runtime CLI is included in `lemon_runtime_min` and `lemon_runtime_full`
artifacts. The `sim_broadcast_platform` artifact intentionally does not bundle
`lemon_cli`; it supports only its release-specific `doctor --bundle` path.

## Release CLI contract

The packaged launcher sends runtime CLI arguments through `LemonCli.CLI` as
data, not dynamically constructed Elixir source. The boundary has these
user-visible rules:

- success exits `0`;
- a command failure exits `1`;
- an unknown command, unknown setup/gateway subcommand, or invalid command
  arguments exits `2`;
- `--help`, `-h`, or `help` prints the relevant command usage and exits `0`
  without starting a wizard, provider flow, or gateway adapter.

## Packaged and source commands

Use the same command nouns in an installed release and a source checkout.
Installed releases use `lemon`; a checkout uses the matching `./bin/lemon`
wrapper. Direct Mix tasks remain contributor-level alternatives, not the
recommended commands for users of a packaged release.

Packaged and Mix `secrets check` / `secrets import-env` commands read the same
ordered environment-secret names from `LemonCore.Secrets.EnvCatalog`, keeping
release and source-checkout behavior aligned.

| Purpose | Installed release | Source checkout | Contributor Mix adapter |
| --- | --- | --- | --- |
| First-time setup | `lemon setup` | `./bin/lemon setup` | `mix lemon.setup` |
| Configure a model provider | `lemon model --provider anthropic` | `./bin/lemon model --provider anthropic` | `mix lemon.onboard anthropic` |
| Configure Telegram or Discord | `lemon gateway setup` | `./bin/lemon gateway setup` | `mix lemon.setup gateway` |
| Diagnostics | `lemon doctor` | `./bin/lemon doctor` | `mix lemon.doctor` |
| Open the local Web UI | `lemon web` | `./bin/lemon web` | Start the full runtime directly |
| Validate/show config | `lemon config validate` | `./bin/lemon config validate` | `mix lemon.config validate` |
| Manage encrypted secrets | `lemon secrets status` | `./bin/lemon secrets status` | `mix lemon.secrets.status` |
| Inspect channel readiness | `lemon channels` | `./bin/lemon channels` | `mix lemon.channels` |
| Back up or restore durable user state | `lemon backup create` | `./bin/lemon backup create` | Call `LemonCli.CLI.run/1` from contributor tooling |
| Manage specialist profiles | `lemon profile list` | `./bin/lemon profile list` | Use the same packaged command boundary |

## Backup and restore

`lemon backup contract|create|list|verify|restore` is implemented by the same
Mix-free `LemonCli.CLI` handler in source and packaged runtimes. Every
subcommand supports `--json`; success writes one document to stdout and exits
`0`, verification/operational failure writes one redacted document to stderr
and exits `1`, and invalid options exit `2`.

Restore is additive and verified before mutation. Differing destination files
require `--overwrite` plus the token emitted by `backup verify --target PATH`;
that token is bound to the verified manifest digest and expanded target.
Credential-bearing files are excluded unless `backup create
--include-credentials` is explicit. See
[Back up and restore Lemon user state](../../docs/user-guide/backups.md) for the
complete format, exclusion, permissions, rollback, and compatibility contract.

## User-managed profiles

Profiles are durable router agents, not alternate engines. Each validated ID
maps to `[profiles.<id>]`, a stable `agent:<id>:main` chat, and an isolated
`~/.lemon/profiles/<id>/workspace/` used for bootstrap, memory paths, and skills.

```bash
lemon profile create research --name "Research" --model openai:gpt-5
lemon profile clone research research-copy --name "Research Copy"
lemon profile show research --json
lemon profile roster
lemon profile chat research "Review this week's notes"
lemon profile export research ./research-profile.json
lemon profile delete research-copy --confirm research-copy
```

`rename` changes the display name without changing the stable ID or chat.
Deletion requires exact-ID confirmation and moves the managed home into Lemon's
trash before removing config. Export is selected-file and credential-safe by
default: it excludes sessions, memory, artifacts, binaries, and secret-like
paths; redacts sensitive assignments and token patterns; and reports omission
and redaction counts. There is no CLI switch to include secrets.

Lifecycle commands run in the release CLI's fresh, non-booted VM. Canonical
chat is different: it must outlive that one-shot process, so the CLI connects
to the authenticated loopback control plane and calls `profile.chat`. The
packaged launcher starts the daemon when needed; source users start
`./bin/lemon --daemon` before `./bin/lemon profile chat`. The request sends only
the profile ID, prompt, queue mode, and optional model override—working
directory and execution node are resolved again from the profile by the
long-running runtime.

## First-run setup and readiness

`lemon setup` is an idempotent state machine over the global config, encrypted
secrets, and default provider. Each run derives which steps are complete,
creates a minimal config only when it is absent, initializes the secrets master
key only when it is absent, skips a provider that is already usable, and
re-derives state before reporting the final result. It never replaces an
existing config or secrets master key.

When setup onboards a provider, it always performs offline configuration checks
and performs the provider's live credential check by default. Use
`lemon setup --skip-verify` or `lemon setup provider --skip-verify` only to
defer that live check when offline; a failed verification is not reported as a
completed setup.

The derived state lives in `LemonCore.Setup.Readiness`, so the setup wizard,
first-run TUI gate, and Web UI agree on exactly what is missing. The browser is
read-only during setup: it lists pending items and rejects prompts/uploads until
the shared state is ready.

The one-line installer starts `lemon setup` by default when it has a controlling
terminal. `--skip-setup`, an unavailable terminal, and the simulation profile
defer that interaction. The first interactive TUI launch consults the same
readiness predicate and runs setup before starting an unconfigured agent; if
setup remains incomplete, it directs the user to `lemon setup`.

`lemon model` is the focused provider onboarding command. It stores the
credential in encrypted secrets, updates the provider configuration, and can
set the default provider/model. Use the full `lemon setup` journey when config
and secrets may not exist yet or when live provider verification is required.

## Gateway setup

`lemon gateway setup` provides interactive and non-interactive adapters for
both supported messaging gateways:

- `telegram` stores a Telegram bot token in encrypted secrets and verifies it
  with the Telegram Bot API.
- `discord` stores a Discord bot token in encrypted secrets, enables Discord,
  writes its secret reference and a default/allowed channel scope to
  `[gateway.discord]`, and verifies the token with Discord's bot identity API.

```bash
# Installed release: choose Telegram or Discord interactively.
lemon gateway setup

# Configure a specific adapter.
lemon gateway setup telegram
lemon gateway setup discord

# Source checkout: use the matching wrapper.
./bin/lemon gateway setup discord --non-interactive \
  --token "$DISCORD_BOT_TOKEN" \
  --default-channel-id 123456789012345678 \
  --allowed-channel-id 234567890123456789
```

The Discord token is persisted as `discord_bot_token` by default and only its
secret key is written to TOML. Pass `--secret-key <name>` to use another key,
`--allowed-guild-id <id>` to restrict by guild as well, or `--skip-smoke` when
the Discord API identity check cannot be reached.

## Onboarding providers

Guided provider setup uses a plain numbered prompt that works consistently
across packaged releases, source checkouts, SSH sessions, and narrow terminals.
Press Enter to accept the displayed default, enter a number or exact label to
choose another option, or enter `q` to cancel. The same selector is used for
providers, authentication methods, models, and confirmation prompts, so setup
does not switch the terminal between cooked and raw modes.

Anthropic provider auth supports API keys or Claude subscription OAuth. Raw API
keys live in `llm_anthropic_api_key_raw` and should be referenced by
`providers.anthropic.api_key_secret`. OAuth-backed Claude Max usage keeps using
`llm_anthropic_api_key` plus `providers.anthropic.auth_source = "oauth"` /
`providers.anthropic.oauth_secret`, and Lemon prefers refreshable Claude Code
credentials from `~/.claude/.credentials.json` over a stale static
`CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_TOKEN`.

OpenAI Codex browser sign-in starts a temporary loopback HTTP listener before
opening the authorization URL. The listener binds the redirect URI's port
(`http://localhost:1455/auth/callback` by default), captures the authorization
code, returns a completion page to the browser, and then shuts down. If the
port cannot be bound or no callback arrives within two minutes, onboarding
falls back to accepting the callback URL or authorization code manually.

```bash
# Installed release
lemon model --provider antigravity --token <token> --set-default --model gemini-3-pro-high
lemon model --provider gemini --project-id your-gcp-project
lemon model --provider openai-codex --token <token> --set-default --model gpt-5.2
lemon model --provider github-copilot --enterprise-domain company.ghe.com

# Source checkout
./bin/lemon model --provider antigravity --token <token> --set-default --model gemini-3-pro-high
./bin/lemon model --provider gemini --project-id your-gcp-project
./bin/lemon model --provider openai-codex --token <token> --set-default --model gpt-5.2
./bin/lemon model --provider github-copilot --enterprise-domain company.ghe.com

# Contributors can invoke the underlying Mix task directly.
mix lemon.onboard codex --token <token> --set-default --model gpt-5.2
```
