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

[agent.cli.opencode]
# Optional model override passed to `opencode run --model`.
model = "gpt-4.1"

[agent.cli.pi]
# Optional extra flags prepended to the `pi` command.
extra_args = []
# Optional provider/model overrides passed to `pi --provider/--model`.
provider = "openai"
model = "gpt-4.1"

[agent.cli.claude]
dangerously_skip_permissions = true

[tui]
theme = "lemon"
debug = false

[logging]
# Optional: write logs to a file for later analysis.
# If unset/empty, file logging is disabled and logs go to stdout/stderr only.
file_path = "~/.lemon/log/lemon.log"
# Optional: handler level for the file (defaults to "debug").
level = "debug"

[gateway]
max_concurrent_runs = 2
default_engine = "lemon"
auto_resume = false
enable_telegram = false

[gateway.telegram]
bot_token = "123456:token"
allowed_chat_ids = [12345678]

[agents.default]
name = "Daily Assistant"
default_engine = "lemon"
system_prompt = "You are my daily assistant."
model = "anthropic:claude-sonnet-4-20250514"

[agents.default.tool_policy]
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
- `<PROVIDER>_API_KEY`, `<PROVIDER>_BASE_URL` (e.g., `ANTHROPIC_API_KEY`, `OPENAI_BASE_URL`)
- `LEMON_CODEX_EXTRA_ARGS`, `LEMON_CODEX_AUTO_APPROVE`
- `LEMON_CLAUDE_YOLO`
- `LEMON_LOG_FILE`, `LEMON_LOG_LEVEL`

## Dotenv Autoload

Lemon can auto-load a `.env` file at startup:

- `./bin/lemon-dev` / `lemon-tui`: loads `<cwd>/.env` where `<cwd>` is the agent working directory (`--cwd`, or current directory).
- `clients/lemon-web/server` bridge: loads `<cwd>/.env` from `--cwd` (or current directory).
- `./bin/lemon-gateway`: loads `.env` from the directory where you launch the script.

By default, existing environment variables are preserved. `.env` values only fill missing variables.

## OpenAI Codex (ChatGPT OAuth)

Lemon supports the **Codex subscription** provider as `openai-codex` (it uses the ChatGPT OAuth JWT, not `OPENAI_API_KEY`).

Recommended setup:

1. Authenticate with Codex CLI once: `codex login` (ChatGPT)
2. Set your default provider/model:

```toml
[agent]
default_provider = "openai-codex"
default_model = "gpt-5.2"
```

Lemon will automatically read your access token from `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`) and refresh it as needed.

To force a token explicitly, set:
- `OPENAI_CODEX_API_KEY` (preferred)
- `CHATGPT_TOKEN` (fallback)

## Sections

- `providers.<name>`: API keys and base URLs per provider.
- `agent`: default model/provider and agent behavior.
- `agents.<agent_id>`: assistant profiles (identity + defaults) used by gateway/control-plane.
- `agent.compaction`: context compaction settings.
- `agent.retry`: retry settings.
- `agent.cli`: CLI runner settings (`codex`, `claude`, `kimi`, `opencode`, `pi`).
- `tui`: terminal UI settings.
- `gateway`: Lemon gateway settings, including `queue`, `telegram`, `projects`, `bindings`, and `engines`.
- `logging`: optional file logging configuration.

## Gateway Projects and Bindings

When LemonGateway handles a Telegram message, it can optionally map that chat (or topic/thread) to a named
**project**. A project is just a **working directory root** (repo path) plus optional defaults.

Why it matters:
- The gateway will run engines with `cwd` set to the project root (so file edits/commands happen in the right repo).
- The gateway will load per-project config from `<project_root>/.lemon/config.toml` (which can override agent profiles,
  models, tool policy, etc. compared to your global `~/.lemon/config.toml`).

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
- If you omit `project`, LemonGateway will run without a project `cwd` (so engines fall back to their process working
  directory), and only global config will apply.
- You can also bind at the topic/thread level by setting `topic_id` in the binding (takes precedence over the chat-level
  binding when a matching topic exists).
- `topic_id` corresponds to Telegram's `message_thread_id` (only present in forum topics).
- LemonGateway loads `gateway.*` config on startup; after changing `gateway.projects` or `gateway.bindings`, restart the
  gateway process.

Tip:
- In Telegram, you can switch the current chat's working directory at runtime with `/new <project_id|path>`. If you pass a
  path, Lemon will register it as a project named after the last path segment (e.g. `~/dev/lemon` => project `lemon`).

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
uploads_dir = "incoming"
media_group_debounce_ms = 1000  # optional (default: 1000ms)

# Optional safety rails
allowed_user_ids = [123456789]  # if empty, group uploads require admin
deny_globs = [".git/**", ".env", ".envrc", "**/*.pem", "**/.ssh/**"]
max_upload_bytes = 20971520     # optional (default: 20MB)
max_download_bytes = 52428800   # optional (default: 50MB)
```

Commands:
- `/file put [--force] <path>`: upload a Telegram document into the bound project.
- `/file get <path>`: fetch a file (or zip a directory) back into Telegram.

## Trigger Mode (Mentions-Only)

In Telegram group chats, you can gate runs so Lemon only triggers when explicitly invoked:
- `/trigger`: show current trigger mode.
- `/trigger mentions`: only run on `@botname`, reply-to-bot, or slash commands.
- `/trigger all`: run on all messages.
- `/trigger clear`: clear a topic override (forum topics only).
