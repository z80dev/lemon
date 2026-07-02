# Lemon CLI

`lemon_cli` owns user-facing Mix tasks and interactive setup flows that sit
above the core foundation:

- provider onboarding through `mix lemon.onboard`
- first-time setup through `mix lemon.setup`
- Hermes import audit and migration through `mix lemon.hermes.*`

The app depends on `lemon_core` for config, secrets, store, and shared runtime
primitives, and on `ai` for provider model and OAuth integration. It does not
start a supervision tree; tasks run the flows on demand.

## Onboarding Providers

1. Add a provider spec to `lib/lemon_cli/onboarding/providers.ex`.
2. Reuse `LemonCli.Onboarding.Runner` for auth flow, secrets persistence, and config updates.
3. If you want a dedicated alias task, create `lib/mix/tasks/lemon.onboard.<provider>.ex` that delegates to the shared runner.
4. Update config via `LemonCore.Config.TomlPatch`.
5. Add focused tests in `test/mix/tasks/` and `test/lemon_cli/onboarding/`.

## Tasks

```bash
mix lemon.onboard
mix lemon.onboard anthropic
mix lemon.onboard codex
mix lemon.onboard gemini
mix lemon.setup
mix lemon.hermes.audit
mix lemon.hermes.migrate --dry-run
```

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
