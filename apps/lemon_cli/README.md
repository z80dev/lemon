# Lemon CLI

`lemon_cli` owns user-facing release CLI commands and source-checkout Mix adapters
for setup flows above the core foundation:

- provider onboarding through `lemon model` or `mix lemon.onboard`
- first-time setup through `lemon setup` or `mix lemon.setup`
- Hermes import audit and migration through `mix lemon.hermes.*`

The app depends on `lemon_core` for config, secrets, store, and shared runtime
primitives, and on `lemon_ai` for provider model and OAuth integration. It does
not start a supervision tree; tasks run the flows on demand.

## Onboarding Providers

1. Add a provider spec to `lib/lemon_cli/onboarding/providers.ex`.
2. Reuse `LemonCli.Onboarding.Runner` for auth flow, secrets persistence, and config updates.
3. If you want a dedicated alias task, create `lib/mix/tasks/lemon.onboard.<provider>.ex` that delegates to the shared runner.
4. Update config via `LemonCore.Config.TomlPatch`.
5. Add focused tests in `test/mix/tasks/` and `test/lemon_cli/onboarding/`.

## Commands

Use the packaged executable when Lemon is installed from a release:

```bash
lemon setup
lemon model --provider anthropic
lemon gateway setup
lemon doctor
```

From a source checkout, use the equivalent Mix adapters:

```bash
mix lemon.setup
mix lemon.onboard anthropic
mix lemon.setup gateway
mix lemon.doctor
```

## Gateway Setup

`mix lemon.setup gateway` configures supported messaging gateways. The picker
offers both adapters:

- `telegram` stores a Telegram bot token in encrypted secrets and verifies it
  with the Telegram Bot API.
- `discord` stores a Discord bot token in encrypted secrets, enables
  `[gateway.discord]`, and restricts inbound handling to the configured default
  channel (and any additional explicitly allowed channels).

```bash
# Choose Telegram or Discord interactively.
mix lemon.setup gateway

# Run a specific adapter.
mix lemon.setup gateway telegram
mix lemon.setup gateway discord

# Supply Discord setup inputs without prompts.
mix lemon.setup gateway discord --non-interactive \
  --token "$DISCORD_BOT_TOKEN" \
  --default-channel-id 123456789012345678 \
  --allowed-channel-id 234567890123456789
```

The Discord token is persisted as `discord_bot_token` by default and only its
secret key is written to TOML. Pass `--secret-key <name>` to use another key,
`--allowed-guild-id <id>` to restrict by guild as well, or `--skip-smoke` when
the Discord API identity check cannot be reached.

Guided provider setup picks a provider from a menu or accepts one directly,
runs OAuth when supported, prompts for API keys otherwise, stores credentials in
encrypted secrets, writes `providers.<provider>` config keys, and can update
`defaults.provider` / `defaults.model`.

The onboarding selector uses `LemonCli.Onboarding.TerminalUI` rather than
`TermUI.Widget.PickList` because the stock pick-list widget can emit range
warnings that corrupt the TUI display.

Anthropic provider auth supports API keys or Claude subscription OAuth. Raw API
keys live in `llm_anthropic_api_key_raw` and should be referenced by
`providers.anthropic.api_key_secret`. OAuth-backed Claude Max usage keeps using
`llm_anthropic_api_key` plus `providers.anthropic.auth_source = "oauth"` /
`providers.anthropic.oauth_secret`, and Lemon prefers refreshable Claude Code
credentials from `~/.claude/.credentials.json` over a stale static
`CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_TOKEN`.

The packaged command accepts the provider as an explicit flag:

```bash
lemon model --provider antigravity --token <token> --set-default --model gemini-3-pro-high
lemon model --provider gemini --project-id your-gcp-project
lemon model --provider gemini --token <token> --set-default --model gemini-2.5-pro
lemon model --provider openai-codex --token <token> --set-default --model gpt-5.2
lemon model --provider zai --token <token> --set-default --model glm-5
lemon model --provider minimax --token <token> --set-default --model MiniMax-M2.7
lemon model --provider github-copilot --enterprise-domain company.ghe.com
lemon model --provider github-copilot --skip-enable-models
lemon model --provider github-copilot --token <token>
```

From source, the equivalent Mix task and provider-specific aliases remain available:

```bash
mix lemon.onboard.antigravity --token <token> --set-default --model gemini-3-pro-high
mix lemon.onboard.gemini --project-id your-gcp-project
mix lemon.onboard.gemini --token <token> --set-default --model gemini-2.5-pro
mix lemon.onboard.codex --token <token> --set-default --model gpt-5.2
mix lemon.onboard.codex --token <token> --config-path /path/to/config.toml
mix lemon.onboard zai --token <token> --set-default --model glm-5
mix lemon.onboard minimax --token <token> --set-default --model MiniMax-M2.7
mix lemon.onboard.copilot --enterprise-domain company.ghe.com
mix lemon.onboard.copilot --skip-enable-models
mix lemon.onboard.copilot --token <token>
mix lemon.onboard.copilot --token <token> --set-default --model gpt-5
mix lemon.onboard.copilot --token <token> --config-path /path/to/config.toml
```
