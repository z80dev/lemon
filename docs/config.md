# Lemon Configuration (TOML)

Lemon uses a single canonical configuration file in TOML format. Configuration is layered:

1. Global: `~/.lemon/config.toml`
2. Project: `<project>/.lemon/config.toml` (overrides global)
3. Environment variables (override file values)
4. CLI arguments (highest priority, when applicable)

## Example

```toml
[providers.anthropic]
api_key = "sk-ant-..."

[providers.openai]
api_key = "sk-..."

[agent]
default_provider = "anthropic"
default_model = "claude-sonnet-4-20250514"
default_thinking_level = "medium"

[agent.compaction]
enabled = true
reserve_tokens = 16384
keep_recent_tokens = 20000

[agent.retry]
enabled = true
max_retries = 3
base_delay_ms = 1000

[agent.cli.codex]
extra_args = ["-c", "notify=[]"]
auto_approve = false

[agent.cli.claude]
dangerously_skip_permissions = true

[tui]
theme = "lemon"
debug = false

[gateway]
max_concurrent_runs = 2
default_engine = "lemon"
auto_resume = false
enable_telegram = false

[gateway.telegram]
bot_token = "123456:token"
allowed_chat_ids = [12345678]
```

## Environment Overrides

Environment variables override file values. Common overrides:

- `LEMON_DEFAULT_PROVIDER`, `LEMON_DEFAULT_MODEL`
- `LEMON_THEME`, `LEMON_DEBUG`
- `<PROVIDER>_API_KEY`, `<PROVIDER>_BASE_URL` (e.g., `ANTHROPIC_API_KEY`, `OPENAI_BASE_URL`)
- `LEMON_CODEX_EXTRA_ARGS`, `LEMON_CODEX_AUTO_APPROVE`
- `LEMON_CLAUDE_YOLO`

## Sections

- `providers.<name>`: API keys and base URLs per provider.
- `agent`: default model/provider and agent behavior.
- `agent.compaction`: context compaction settings.
- `agent.retry`: retry settings.
- `agent.cli`: CLI runner settings (`codex`, `claude`, `kimi`).
- `tui`: terminal UI settings.
- `gateway`: Lemon gateway settings, including `queue`, `telegram`, `projects`, `bindings`, and `engines`.
