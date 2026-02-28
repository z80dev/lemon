# Lemon Configuration (TOML)

Lemon uses a single canonical configuration file in TOML format. Configuration is layered:

1. Global: `~/.lemon/config.toml`
2. Project: `<project>/.lemon/config.toml` (overrides global)
3. Environment variables (override file values; `.env` may auto-populate missing env vars at startup)
4. CLI arguments (highest priority, when applicable)

## Example

```toml
[providers.anthropic]
api_key = "sk-ant-..."

[providers.openai]
api_key = "sk-..."

[providers.opencode]
api_key = "opencode-..."
base_url = "https://opencode.ai/zen/v1"

[defaults]
provider = "anthropic"
model = "anthropic:claude-sonnet-4-20250514"
thinking_level = "medium"
engine = "lemon"

[runtime.compaction]
enabled = true
reserve_tokens = 16384
keep_recent_tokens = 20000

[runtime.retry]
enabled = true
max_retries = 3
base_delay_ms = 1000

[runtime.cli.codex]
extra_args = ["-c", "notify=[]"]
auto_approve = false

[runtime.cli.opencode]
# Optional model override passed to `opencode run --model`.
model = "gpt-4.1"

[runtime.cli.pi]
# Optional extra flags prepended to the `pi` command.
extra_args = []
# Optional provider/model overrides passed to `pi --provider/--model`.
provider = "openai"
model = "gpt-4.1"

[runtime.cli.claude]
dangerously_skip_permissions = true

[runtime.tools.web.search]
provider = "brave" # "brave" | "perplexity"
cache_ttl_minutes = 15

[runtime.tools.web.search.perplexity]
model = "perplexity/sonar-pro"

[runtime.tools.web.fetch]
cache_ttl_minutes = 15
allow_private_network = false
allowed_hostnames = []

[runtime.tools.web.fetch.firecrawl]
enabled = true

[runtime.tools.wasm]
enabled = false
auto_build = true
runtime_path = ""
tool_paths = []
default_memory_limit = 10485760
default_timeout_ms = 60000
default_fuel_limit = 10000000
cache_compiled = true
cache_dir = ""
max_tool_invoke_depth = 4

[tui]
theme = "lemon"
debug = false

[logging]
# Optional: write logs to a file for later analysis.
# If unset/empty, file logging is disabled and logs go to stdout/stderr only.
file = "~/.lemon/log/lemon.log"
# Optional: handler level for the file (defaults to "debug").
level = "debug"

[gateway]
max_concurrent_runs = 2
default_engine = "lemon"
auto_resume = false
enable_telegram = false
enable_xmtp = false

[gateway.telegram]
bot_token = "123456:token"
allowed_chat_ids = [12345678]

[gateway.xmtp]
env = "production"                  # production | dev | local
wallet_address = "${XMTP_WALLET_ADDRESS}"
wallet_key = "${XMTP_WALLET_KEY}"
db_path = "~/.lemon/xmtp-db"
poll_interval_ms = 1500
connect_timeout_ms = 15000
require_live = true
mock_mode = false

[profiles.default]
name = "Daily Assistant"
system_prompt = "You are my daily assistant."

[profiles.default.tool_policy]
# Optional preset profile:
# profile = "minimal_core"  # full_access | minimal_core | read_only | safe_mode | subagent_restricted | no_external | custom
allow = "all"
deny = []
require_approval = ["bash", "write", "edit"]
no_reply = false

[[gateway.bindings]]
transport = "telegram"
chat_id = 12345678
agent_id = "default"
```

## Environment Overrides

Environment variables override file values. Common overrides:

- `LEMON_DEFAULT_PROVIDER`, `LEMON_DEFAULT_MODEL`
- `LEMON_THEME`, `LEMON_DEBUG`
- `<PROVIDER>_API_KEY`, `<PROVIDER>_BASE_URL` (e.g., `ANTHROPIC_API_KEY`, `OPENAI_BASE_URL`, `OPENCODE_API_KEY`)
- `LEMON_CODEX_EXTRA_ARGS`, `LEMON_CODEX_AUTO_APPROVE`
- `LEMON_CLAUDE_YOLO`
- `LEMON_WASM_ENABLED`, `LEMON_WASM_RUNTIME_PATH`, `LEMON_WASM_TOOL_PATHS`, `LEMON_WASM_AUTO_BUILD`
- `LEMON_LOG_FILE`, `LEMON_LOG_LEVEL`
- `BRAVE_API_KEY`, `PERPLEXITY_API_KEY`, `OPENROUTER_API_KEY`, `FIRECRAWL_API_KEY`

## Preferred vs Legacy Sections

Preferred section names:

- `defaults` for model/provider/thinking/engine defaults
- `runtime` for runtime/tool/CLI behavior
- `profiles.<agent_id>` for assistant profiles

Legacy aliases are still supported for backward compatibility:

- `agent` (legacy alias of `runtime`, and also source of `default_*` values)
- `agents.<agent_id>` (legacy alias of `profiles.<agent_id>`)

When both are present, preferred sections win for overlapping keys (`runtime` over `agent`, `profiles` over `agents`).

## Dotenv Autoload

Lemon can auto-load a `.env` file at startup:

- `./bin/lemon-dev` / `lemon-tui`: loads `<cwd>/.env` where `<cwd>` is the agent working directory (`--cwd`, or current directory).
- `clients/lemon-web/server` bridge: loads `<cwd>/.env` from `--cwd` (or current directory).
- `./bin/lemon-gateway`: loads `.env` from the directory where you launch the script.

By default, existing environment variables are preserved. `.env` values only fill missing variables.

## OpenAI Codex (ChatGPT OAuth)

Lemon supports the **Codex subscription** provider as `openai-codex` (it uses the ChatGPT OAuth JWT, not `OPENAI_API_KEY`).

Primary setup path:

```bash
mix lemon.onboard.codex
```

What it does:
- Resolves Codex OAuth credentials via `Ai.Auth.OpenAICodexOAuth`
- Stores credentials in encrypted secrets
- Writes `providers.openai-codex.api_key_secret` in your config
- Optionally updates `[defaults]` provider/model

The onboarding flow opens the OpenAI auth URL directly and stores the returned OAuth credentials in Lemon secrets.

To force a token explicitly, set:
- `OPENAI_CODEX_API_KEY` (preferred)
- `CHATGPT_TOKEN` (fallback)

## Provider Onboarding (CLI)

Lemon includes guided onboarding flows for provider credentials where OAuth is supported:

```bash
# Google Antigravity OAuth onboarding
mix lemon.onboard.antigravity

# OpenAI Codex OAuth onboarding
mix lemon.onboard.codex

# GitHub Copilot OAuth onboarding
mix lemon.onboard.copilot
```

All onboarding tasks:
- Verify encrypted secrets are configured
- Run provider OAuth flow by default (or accept `--token`)
- Store credentials in encrypted secrets with provider metadata
- Write `providers.<provider>.api_key_secret` in config
- Support `--set-default`, `--model`, and `--config-path`

Antigravity OAuth client credentials resolve from Lemon secrets first:
- `google_antigravity_oauth_client_id`
- `google_antigravity_oauth_client_secret`

Environment variables are supported as fallback:
- `GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID`
- `GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET`

Common non-interactive usage:

```bash
# Google Antigravity
mix lemon.onboard.antigravity --token <token> --set-default --model gemini-3-pro-high

# OpenAI Codex
mix lemon.onboard.codex --token <token> --set-default --model gpt-5.2

# GitHub Copilot (enterprise + optional model enablement toggle)
mix lemon.onboard.copilot --enterprise-domain company.ghe.com
mix lemon.onboard.copilot --skip-enable-models
mix lemon.onboard.copilot --token <token> --set-default --model gpt-5
mix lemon.onboard.copilot --token <token> --config-path /path/to/config.toml
```

Anthropic provider auth is API key based. Store your raw key in secrets:

```bash
mix lemon.secrets.set llm_anthropic_api_key_raw <token>
```

## Web Tools (`websearch` / `webfetch`)

Lemon includes web tools under `runtime.tools.web`. For full setup and troubleshooting, see:
- [`docs/tools/web.md`](tools/web.md)
- [`docs/tools/firecrawl.md`](tools/firecrawl.md)

```toml
[runtime.tools.web.search]
enabled = true
provider = "brave"   # "brave" | "perplexity"
max_results = 5
timeout_seconds = 30
cache_ttl_minutes = 15

[runtime.tools.web.search.failover]
enabled = true
provider = "perplexity"

[runtime.tools.web.search.perplexity]
# Optional if PERPLEXITY_API_KEY / OPENROUTER_API_KEY is set.
api_key = "pplx-..."
base_url = "https://api.perplexity.ai"
model = "perplexity/sonar-pro"

[runtime.tools.web.fetch]
enabled = true
max_chars = 50000
timeout_seconds = 30
cache_ttl_minutes = 15
max_redirects = 3
readability = true
allow_private_network = false
allowed_hostnames = []

[runtime.tools.web.fetch.firecrawl]
# Optional if FIRECRAWL_API_KEY is set.
enabled = true
api_key = "fc-..."
base_url = "https://api.firecrawl.dev"
only_main_content = true
max_age_ms = 172800000
timeout_seconds = 60

[runtime.tools.web.cache]
persistent = true
path = "~/.lemon/cache/web_tools"
max_entries = 100
```

## WASM Tools

WASM tools are disabled by default and run in a per-session Rust sidecar.
See [`docs/tools/wasm.md`](tools/wasm.md) for runtime behavior and troubleshooting.

```toml
[runtime.tools.wasm]
enabled = false
auto_build = true
runtime_path = ""
tool_paths = []
default_memory_limit = 10485760
default_timeout_ms = 60000
default_fuel_limit = 10000000
cache_compiled = true
cache_dir = ""
max_tool_invoke_depth = 4
```

## Sections

- `providers.<name>`: API keys and base URLs per provider.
- `defaults`: global default model/provider/thinking/engine.
- `runtime`: runtime behavior and tool settings.
- `runtime.tools.web`: `websearch` / `webfetch` providers, guardrails, cache, and Firecrawl fallback.
- `runtime.tools.wasm`: WASM sidecar runtime controls and discovery paths.
- `profiles.<agent_id>`: assistant profiles (identity + defaults) used by gateway/control-plane.
- `runtime.compaction`: context compaction settings.
- `runtime.retry`: retry settings.
- `runtime.cli`: CLI runner settings (`codex`, `claude`, `kimi`, `opencode`, `pi`).
- `tui`: terminal UI settings.
- `gateway`: Lemon gateway settings, including `queue`, `telegram`, `xmtp`, `projects`, `bindings`, and `engines`.
- `logging`: optional file logging configuration.

## Gateway Projects and Bindings

When LemonGateway handles a Telegram message, it can optionally map that chat (or topic/thread) to a named
**project**. A project is just a **working directory root** (repo path) plus optional defaults.

Why it matters:
- The gateway will run engines with `cwd` set to the project root (so file edits/commands happen in the right repo).
- The gateway will load per-project config from `<project_root>/.lemon/config.toml` (which can override agent profiles,
  models, tool policy, etc. compared to your global `~/.lemon/config.toml`).
- If a chat has no bound project, gateway falls back to `gateway.default_cwd` (or `~/` by default).

### Projects

Define projects under `[gateway.projects.<project_id>]`:

```toml
[gateway.projects.myrepo]
root = "/path/to/myrepo"
# Optional: project-level default engine if a binding doesn't set one.
default_engine = "lemon"
```

### Bindings

Bindings connect an incoming chat scope to a project/agent/defaults:

```toml
[[gateway.bindings]]
transport = "telegram"
chat_id = 123456789

# Optional: bind this chat to a project (must match the `[gateway.projects.<id>]` key)
project = "myrepo"

# Optional: choose which agent profile to use (defaults to "default")
agent_id = "default"

# Optional: per-chat default engine/queue overrides
default_engine = "claude"
queue_mode = "steer"
```

Notes:
- If you omit `project`, LemonGateway will run with `cwd` set to `gateway.default_cwd` when configured, otherwise `~/`.
- You can also bind at the topic/thread level by setting `topic_id` in the binding (takes precedence over the chat-level
  binding when a matching topic exists).
- `topic_id` corresponds to Telegram's `message_thread_id` (only present in forum topics).
- LemonGateway loads `gateway.*` config on startup; after changing `gateway.projects` or `gateway.bindings`, restart the
  gateway process.

Optional fallback cwd:

```toml
[gateway]
default_cwd = "~/"
```

Tip:
- In Telegram, you can set or inspect the current chat/topic working directory at runtime with
  `/cwd [project_id|path|clear]`.
- `/new <project_id|path>` still works, and setting `/cwd` makes future `/new` sessions in that chat/topic use the same directory.
- `/new` confirmation replies include model, provider, cwd, and session context details.
- If you pass a path, Lemon will register it as a project named after the last path segment (e.g. `~/dev/lemon` => project `lemon`).

## XMTP (Base App / Wallet Chats)

Lemon can run as an XMTP bot through the `lemon_channels` XMTP adapter.

### 1. Install XMTP bridge dependencies

```bash
./bin/lemon-xmtp-bootstrap
```

This installs bridge dependencies in `apps/lemon_gateway/priv/node_modules` (where `xmtp_bridge.mjs` resolves imports).

### 2. Configure gateway XMTP

```toml
[gateway]
enable_xmtp = true

[gateway.xmtp]
env = "production"                  # production | dev | local
wallet_address = "${XMTP_WALLET_ADDRESS}"
wallet_key = "${XMTP_WALLET_KEY}"   # 64-char hex private key (or 0x-prefixed)
db_path = "~/.lemon/xmtp-db"
poll_interval_ms = 1500
connect_timeout_ms = 15000
require_live = true                 # production default: do not allow mock fallback
mock_mode = false                   # set true only for local bridge testing
# Optional:
# api_url = "https://api.xmtp.network"
# inbox_id = "..."
# sdk_module = "@xmtp/node-sdk"
```

Notes:
- When `enable_xmtp = true`, Lemon auto-registers and starts the XMTP channel adapter.
- `require_live = true` keeps health/readiness red unless the bridge is truly live (not mock mode).
- Non-text XMTP messages currently receive a text-only fallback response.

## Telegram Voice Transcription

If enabled, Telegram voice notes are transcribed and the transcript is routed as a normal text message.

```toml
[gateway.telegram]
voice_transcription = true
voice_transcription_model = "gpt-4o-mini-transcribe"  # optional
voice_max_bytes = 10485760                            # optional (default: 10MB)

# Optional OpenAI-compatible overrides (defaults to providers.openai)
voice_transcription_base_url = "https://api.openai.com/v1"
voice_transcription_api_key = "sk-..."
```

## Telegram File Transfer

Enable `/file put` and `/file get` (and optional auto-save for plain document uploads).

```toml
[gateway.telegram.files]
enabled = true
auto_put = true
auto_put_mode = "upload"  # "upload" | "prompt"
auto_send_generated_images = true      # optional: send generated images automatically after a run
auto_send_generated_max_files = 3      # optional: max images auto-sent per run (default: 3)
uploads_dir = "incoming"
media_group_debounce_ms = 1000  # optional (default: 1000ms)

# Optional safety rails
allowed_user_ids = [123456789]  # if empty, group uploads require admin
deny_globs = [".git/**", ".env", ".envrc", "**/*.pem", "**/.ssh/**"]
max_upload_bytes = 20971520     # optional (default: 20MB)
max_download_bytes = 52428800   # optional (default: 50MB)
outbound_send_delay_ms = 1000   # optional: delay between auto-sent files/batches to reduce 429s
```

Commands:
- `/file put [--force] <path>`: upload a Telegram document into the active working root.
- `/file get <path>`: fetch a file (or zip a directory) from the active working root back into Telegram.

If no project is bound for the chat, the active root falls back to `gateway.default_cwd` (or `~/`).

When `auto_send_generated_images = true`, Lemon tracks image files created/changed during the run and sends up to
`auto_send_generated_max_files` files back to Telegram automatically at completion (using the same `max_download_bytes`
limit as `/file get`).

## Telegram Context Compaction

When a Telegram run approaches the model context limit, Lemon can proactively mark the session for compaction so the
next user message is automatically rewritten with a compact transcript and sent as a fresh session.

```toml
[gateway.telegram.compaction]
enabled = true
context_window_tokens = 400000  # optional override; if unset Lemon infers from model/engine
reserve_tokens = 16384          # optional safety margin before limit
trigger_ratio = 0.9             # optional; 0.9 means trigger at 90% of context window
```

## Trigger Mode (Mentions-Only)

In Telegram group chats, you can gate runs so Lemon only triggers when explicitly invoked:
- `/trigger`: show current trigger mode.
- `/trigger mentions`: only run on `@botname`, reply-to-bot, or slash commands.
- `/trigger all`: run on all messages.
- `/trigger clear`: clear a topic override (forum topics only).
- `/cwd [project_id|path|clear]`: show, set, or clear the chat/topic working directory override used by future `/new` sessions.

Forum topic management:
- `/topic <name>`: create a new topic in the current Telegram forum supergroup.

## Telegram Behavior Toggles

Optional flags to suppress default Telegram behaviors. All default to `true` (enabled).

```toml
[gateway.telegram]
# Set 👀/✅/❌ reactions on the user's message to indicate processing status.
progress_reactions = true

# Send answers as a threaded reply to the user's message rather than a new message.
reply_to_user_message = true

# Show a "Tool calls:" status message during runs with tool activity.
show_tool_status = true
```
