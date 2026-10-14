# Lemon Configuration (TOML)

Lemon uses a single canonical configuration file in TOML format. Configuration is layered:

1. Global: `~/.lemon/config.toml`
2. Project: `<project>/.lemon/config.toml` (overrides global)
3. Environment variables (override file values; `.env` may auto-populate missing env vars at startup)
4. Credential references resolved through Lemon's encrypted store, explicitly
   enabled external sources, and the ordinary same-name environment fallback

Runtime state and policy are separate from config. Per-session or per-route "current"
model/thinking values override config defaults at runtime, but they are not persisted in
`config.toml`.

Operational backup policy is also intentionally separate from TOML. Use
`lemon backup contract|create|list|verify|restore`; there are no implicit
backup directories or credential-inclusion settings in `config.toml`. See
[Back up and restore Lemon user state](user-guide/backups.md) for the versioned
`~/.lemon` data contract.

## Example

```toml
[providers.anthropic]
api_key_secret = "llm_anthropic_api_key_raw"

# Claude Max / Claude Code subscription auth
# auth_source = "oauth"
# oauth_secret = "llm_anthropic_api_key"

[providers.openai]
api_key_secret = "OPENAI_API_KEY"

# OpenAI-compatible local or hosted endpoint.
# Store a placeholder secret such as "local" if the endpoint ignores API keys.
# base_url = "http://127.0.0.1:11434/v1"

[providers.opencode]
api_key_secret = "OPENCODE_API_KEY"
base_url = "https://opencode.ai/zen/v1"

# OpenCode Go uses the same OPENCODE_API_KEY credential.
[providers.opencode_go]
api_key_secret = "OPENCODE_API_KEY"

[defaults]
provider = "anthropic"
model = "anthropic:claude-sonnet-4-20250514"
thinking_level = "medium"

[runtime.compaction]
enabled = true
reserve_tokens = 16384
keep_recent_tokens = 20000

[runtime.retry]
# Session-level retry of transient provider failures (429, 5xx, overloaded,
# network) that happen before any output. Exponential backoff from
# base_delay_ms; a retry-after hint from the provider replaces the backoff.
enabled = true
max_retries = 3
base_delay_ms = 1000

[runtime.secret_obfuscation]
# Opt-in. Replaces secrets in provider-visible session text with placeholders
# and restores them in tool arguments; see security/secret-obfuscation.md.
enabled = false

[runtime]
# Explicitly trusted extension directories. Files here can be compiled and executed.
extension_paths = []
# Optional cap on tool-using turns per prompt. Unset or 0 = unlimited (default).
# max_tool_turns = 200

[runtime.extensions]
# Disable all extension code execution while keeping manifest diagnostics available.
enabled = true
# Keep default global/project extension directories diagnostics-only unless trusted.
auto_load_default_paths = false

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

[automation]
# Optional: opt-in daily brief at this server-local time (HH:MM, 24-hour).
# daily_brief = "08:00"

[gateway]
max_concurrent_runs = 2
auto_resume = false
enable_telegram = false
enable_discord = false
enable_xmtp = false

[gateway.telegram]
# `lemon gateway setup telegram` stores the token in encrypted secrets, pairs
# your chat via /start, and writes these three keys.
bot_token_secret = "telegram_bot_token"
# Required: chats allowed to use the bot. With no allowlist the bot is unpaired
# and ignores every chat (it only answers /whoami and a pairing hint).
allowed_chat_ids = [12345678]
# allow_all_chats = true         # explicit opt-out: accept every chat when allowed_chat_ids is empty
default_account_id = "default"   # optional account for ./bin/lemon send account-scoped lookups
default_chat_id = 12345678       # optional default for ./bin/lemon send --to telegram
default_thread_id = 35           # optional forum topic/thread

[gateway.discord]
# `lemon gateway setup discord` stores the token in encrypted secrets and
# writes this secret reference plus the restricted channel scope.
bot_token_secret = "discord_bot_token"
default_channel_id = 123456789012345678
allowed_channel_ids = [123456789012345678]
deny_unbound_channels = true
# allowed_guild_ids = [123456789012345678] # optional additional restriction

[gateway.xmtp]
env = "production"                  # production | dev | local
wallet_address = "${XMTP_WALLET_ADDRESS}"
wallet_key_secret = "xmtp_wallet_key"
db_path = "~/.lemon/xmtp-db"
poll_interval_ms = 1500
connect_timeout_ms = 15000
require_live = true
mock_mode = false

[gateway.voice]
enabled = false
websocket_port = 4047
public_url = "https://example.com"
twilio_account_sid_secret = "twilio_account_sid"
twilio_auth_token_secret = "twilio_auth_token"
twilio_phone_number = "+1234567890"
deepgram_api_key_secret = "deepgram_api_key"
elevenlabs_api_key_secret = "elevenlabs_api_key"
elevenlabs_voice_id = "21m00Tcm4TlvDq8ikWAM"
elevenlabs_output_format = "ulaw_8000"
llm_model = "gpt-4o-mini"
max_call_duration_seconds = 600
silence_timeout_ms = 5000

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

`LemonCore.ProfileStore` is the lifecycle owner for user-managed profiles.
Commands such as `lemon profile create research` patch only the selected
`[profiles.<id>]` table, preserving unrelated global-config keys and comments.
Managed records may include `name`, `description`, `avatar`, `model`,
`system_prompt`, `node`, `status`, `profile_version`, `created_at`, and
`updated_at`. Home/workspace paths and the stable `agent:<id>:main` session key
are derived from the validated ID rather than stored; do not add credentials or
filesystem paths to the profile table. See
[User-managed profiles](user-guide/profiles.md) for clone, credential-safe
export, recoverable deletion, and named-node routing.

## Cumulative usage budgets

Set optional caps in the global `~/.lemon/config.toml` or project
`.lemon/config.toml` (project values override global values):

```toml
[budgets]
max_run_tokens = 100000
max_run_cost_usd = 2.50
max_session_tokens = 500000
max_session_cost_usd = 10.00
```

Omitted limits are unlimited. Token caps are nonnegative integers; dollar caps
are finite nonnegative numbers. **Zero blocks requests**, unlike an omitted
limit. A run is one prompt: its counters reset on the next prompt. Session
counters accumulate across prompts and durable resumes. They are separate from
context-window occupancy: compaction, rewind, branch navigation and clear do not
refund spend. Forks inherit the source session's entire cumulative ledger,
including spend outside the selected branch; subsequent spend is independent.
A genuinely new, unrelated session starts a new session budget.

These caps apply to the **prompt agent loop**, including its reported retry
attempts and the decision to execute tools or request another turn. Compaction
and project-memory maintenance model calls are **not counted** in these counters.
Subagent sessions have their own run/session counters; this is not an aggregate
account-wide billing limit.

Tokens use the provider's reported total, or input + output + cache-read +
cache-write when a total is unavailable. Long-lived cache writes are a subset of
cache writes, not an additional token charge. Dollar amounts are catalog-based
**estimates**, not billing invoices. Reported usage from interrupted requests and
retries counts while enforcing a cap; usage the provider never reports cannot be
invented. Legacy sessions derive their starting ledger from all stored assistant
messages, including inactive branches.

Limits are checked before a request and after reported usage, before another
request or tool execution. Providers normally report usage only at the end:
**one in-flight request can overshoot a positive cap**. These are stopping
policies, not hard billing caps. Already-exhausted or zero caps prevent requests.
Tool calls requested by the response that exhausts a cap are recorded as rejected
error results without executing their side effects. Increase the configured cap
if you intentionally want to continue an exhausted session.

## Native Execution and Subagents

Lemon uses its native executor for every top-level TUI and gateway run. Configure
its provider, model, and thinking defaults in `[defaults]`; no engine selection
key is supported.

Delegated tasks run as native in-process subagents (child `CodingAgent.Session`
executions) when the agent invokes its `task` tool. There are no vendor CLI task
runners and no `[runtime.cli.*]` configuration.

### Model Roles

`[model_roles]` is a string-to-string map in the same canonical config, layered
global → project like other sections. Roles are explicit selectors, not model IDs
or subagent personas:

```toml
[defaults]
model = "@default"

[model_roles]
default = "openai:gpt-4o"
smol = "openai:gpt-4o-mini"
slow = "@review"
plan = "@slow"
commit = "@smol"
review = "anthropic:claude-sonnet-4-20250514"
task = "@smol"          # Optional: omitted task.model otherwise inherits its parent
compaction = "@smol"    # Optional: takes precedence over configured smol
```

Native session model overrides and explicit `task.model` accept `@default`,
`@smol`, `@slow`, `@plan`, `@commit`, and any configured custom role. Aliases expand recursively.
Concrete model specs retain their existing behavior; bare `smol` is still a model
ID, not the `@smol` role. Role names remain strings and are never converted into
atoms. Empty/non-string mappings, unknown custom aliases, and alias cycles
produce configuration/model-resolution errors rather than silently ignoring an
override. A configured role still needs to resolve to a valid concrete model.

Without a mapping, these built-ins use the configured default for a native
session and the current parent model for a task. They do not select a new provider
or a hard-coded small/slow model. A default of `@default` requires a role mapping
that ultimately reaches a concrete model; it cannot fall back to itself.
Omitting `task.model` preserves parent inheritance unless `model_roles.task` is
configured; an explicit task model takes precedence.

Entering plan mode automatically selects `model_roles.plan` only when configured.
Exiting or approving a plan restores the execution model recorded on entry,
including after durable session resume. `@commit` is available to explicit model
selectors and delegated tasks; it does not automatically invoke a commit tool.

Compaction and abandoned-branch summaries choose `model_roles.compaction` first,
then `model_roles.smol` **only if configured**, otherwise the active session model.
An explicit compaction `:model` option takes precedence. Summary credentials and
provider stream options are resolved for that selected model together, including
background compaction, without changing the main session's model. Explicit
summary credential/stream-option overrides are retained.

### Automatic Thinking

Set `[defaults] thinking_level = "auto"` to classify each user prompt before its
model turn. Configure `model_roles.tiny` or `model_roles.smol` explicitly for the
classifier; `tiny` takes precedence. The classifier receives bounded latest-user
text with no tools, and selects `low`, `medium`, `high`, or `xhigh`. Its effort is
mapped to the active model's declared supported levels, so `auto` is never sent
to a provider. Models without reasoning support receive no reasoning option.

Classification runs in the supervised agent task, not the session server, with a
five-second deadline. A missing classifier, failure, timeout, or invalid answer
uses supported `medium` effort and continues the turn. An explicit `ultrathink`
request selects the active model's highest supported effort without a classifier
call. The configured `auto` selector persists across turns and session resumes;
the internal classifier response is not appended to the conversation.
Classifier calls are separate maintenance usage, not part of the main agent-turn
budget ledger. An already-exhausted main-response budget prevents classification.



### Named Execution Nodes

The `agent` tool can route a delegated run to an authenticated execution node
with its optional `node` parameter. Omit `node` or use `"local"` for the
controller host. A named value must be online in the controller's live node
registry. This placement is a per-run tool parameter, not a TOML engine or
provider setting:

```json
{
  "action": "run",
  "agent_id": "default",
  "prompt": "Run the focused checks.",
  "node": "worker-1"
}
```

Join a destination from a source checkout with:

```bash
LEMON_NODE_OPERATOR_TOKEN=... ./bin/lemon node join \
  --name worker-1 \
  --controller wss://controller.example/ws \
  --pair \
  --cwd /srv/project
```

On first connection, `--pair` creates the durable controller identity and
stores its issued seven-day session plus recovery credential in a mode-0600
file under `~/.lemon/nodes/execution/`; the containing directory is mode 0700.
Each record is keyed by a hash of the durable node ID and includes the exact
controller URL, so reuse fails closed for a different controller. The token
store requires that exact URL even for direct durable-ID lookup and returns no
recovery material for a missing or mismatched controller. Later starts
omit `--pair`. Re-run with `--pair` after session expiry to keep the same
identity and controller-side name while rotating the session and revoking older
tokens and live sockets. Concurrent challenge exchange can mint only one
credential, and result settlement is accepted only from the connection and
session generation that received the invocation. Controller renames do not
change the local key. Compatible legacy records
without recovery credentials use the explicit operator-authorized
`--pair --repair --node-id ID` migration path.

`LEMON_NODE_OPERATOR_TOKEN` supplies pairing authority and is used only during
pairing. `LEMON_NODE_TOKEN` supplies an existing session token. Prefer these
environment variables to `--operator-token` / `--token` so credentials do not
enter shell history. These values are runtime CLI inputs, not `config.toml`
keys.

Non-loopback controllers require `wss://` by default. Plaintext `ws://` needs
`--allow-insecure-controller` or
`LEMON_NODE_ALLOW_INSECURE_CONTROLLER=true`, and that override is acceptable
only for development or a verified authenticated and encrypted overlay such as
Tailscale.

Provider credentials and default cwd are destination-local. If the `agent`
tool omits `cwd`, the destination uses the directory passed to `node join`; an
explicit `cwd` is resolved and validated on that machine. Only JSON-safe run
data crosses the controller WebSocket. Source executor options, resolved
provider credentials, callbacks, and BEAM state do not. Explicit cancellation
is delivered to the targeted worker; disconnects fail pending invocations.
Remote execution still uses the native `CodingAgent.Executor`, never a vendor
CLI runner.

### Removed Top-Level Engine Configuration

Remove these legacy keys and tables from global and project configuration:

| Removed configuration | Migration |
|---|---|
| `engine`, `[defaults].engine`, `default_engine`, and `engine_preference` | Remove the key. Keep `[defaults]` provider, model, and thinking settings for native execution. |
| `[gateway].default_engine`, `[gateway.projects.<id>].default_engine`, and `[[gateway.bindings]].default_engine` | Remove the key. Retain project `root`, binding `project`/`agent_id`, and queue settings as needed. |
| `[gateway.engines.<id>]` | Remove the entire table. Custom and external gateway executors are not supported. |
| `[runtime.cli.<vendor>]` | Remove the entire table. Vendor CLI task runners were removed; delegated tasks run as native in-process subagents. Config validation rejects `[runtime.cli]`. |

There is no TOML replacement for selecting a top-level external or custom
engine, and no TOML knob for delegated subagents beyond the native `task` tool's
own parameters.

## Environment Overrides

Environment variables override file values. Common overrides:

- `LEMON_DEFAULT_PROVIDER`, `LEMON_DEFAULT_MODEL`
- `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` — shared WebSocket operator credential;
  required by default for every WebSocket operator connection. Named node
  pairing supplies the same value from `LEMON_NODE_OPERATOR_TOKEN` on the
  joining host. The source `./bin/lemon-tui` launcher generates an ephemeral
  value when it owns a fresh local runtime; persistent or existing runtimes
  require the operator to provide the same high-entropy value to both runtime
  and client. Token origin does not control process lifetime: every runtime
  started by `./bin/lemon-tui` is stopped with the TUI. Start a persistent
  source runtime with `./bin/lemon daemon`, then attach with the same token.
- `LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK` — explicit legacy
  compatibility opt-in (`true`/`false` or `1`/`0`) for tokenless operator
  connections from direct loopback peers. Defaults to `false`; never enable it
  for a reverse-proxied control plane.

The browser monitoring client intentionally has no build-time or URL-based
operator-token setting. Lemon does not yet implement the short-lived delegated
browser-session exchange needed to authenticate that client safely. Never
place the shared server token in `VITE_*` configuration.
- `LEMON_PROVIDER_ROUTING_ENABLED`, `LEMON_PROVIDER_FALLBACK_PROVIDERS`, `LEMON_PROVIDER_ROUTING_REQUIRE_CREDENTIALS`
- `LEMON_THEME`, `LEMON_DEBUG`
- `LEMON_SECRET_OBFUSCATION_ENABLED` — overrides `[runtime.secret_obfuscation] enabled`
- `<PROVIDER>_API_KEY`, `<PROVIDER>_BASE_URL` (e.g., `ANTHROPIC_API_KEY`, `OPENAI_BASE_URL`, `OPENCODE_API_KEY`, `ZAI_API_KEY`, `MINIMAX_API_KEY`); local servers use `OLLAMA_BASE_URL`/`OLLAMA_HOST`, `LM_STUDIO_BASE_URL`, `LLAMA_CPP_BASE_URL` and `LITELLM_BASE_URL` only when config sets no `base_url` (see [OpenAI-Compatible Endpoints](#openai-compatible-endpoints))
- `LEMON_CODEX_EXTRA_ARGS`, `LEMON_CODEX_AUTO_APPROVE`
- `LEMON_CLAUDE_YOLO`
- `LEMON_WASM_ENABLED`, `LEMON_WASM_RUNTIME_PATH`, `LEMON_WASM_TOOL_PATHS`, `LEMON_WASM_AUTO_BUILD`
- `LEMON_TERMINAL_BACKENDS_ALLOW`, `LEMON_TERMINAL_BACKENDS_DENY`, `LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL`
- `LEMON_DOCKER_TERMINAL_IMAGE`, `LEMON_DOCKER_TERMINAL_MEMORY`, `LEMON_DOCKER_TERMINAL_CPUS`, `LEMON_DOCKER_TERMINAL_PIDS_LIMIT`, `LEMON_DOCKER_TERMINAL_NETWORK`
- `LEMON_DOCKER_TERMINAL_READ_ONLY_ROOTFS`, `LEMON_DOCKER_TERMINAL_TMPFS_SIZE`, `LEMON_DOCKER_TERMINAL_ALLOWED_IMAGES`
- `LEMON_SSH_TERMINAL_TARGET`, `LEMON_SSH_TERMINAL_WORKDIR`, `LEMON_SSH_TERMINAL_PORT`, `LEMON_SSH_TERMINAL_CONNECT_TIMEOUT`, `LEMON_SSH_TERMINAL_STRICT_HOST_KEY_CHECKING`, `LEMON_SSH_TERMINAL_ALLOWED_TARGETS`
- `LEMON_GATEWAY_HEALTH_PORT`, `LEMON_ROUTER_HEALTH_PORT`
- `LEMON_NODE_OPERATOR_TOKEN`, `LEMON_NODE_TOKEN`, `LEMON_NODE_ALLOW_INSECURE_CONTROLLER`
- `LEMON_LOG_FILE`, `LEMON_LOG_LEVEL`
- `BRAVE_API_KEY`, `PERPLEXITY_API_KEY`, `OPENROUTER_API_KEY`, `FIRECRAWL_API_KEY`

Terminal backend policy validates Docker image/network/resource settings and
SSH port/timeout/host-key settings before `exec` launches a backend. Invalid
Docker limits, invalid Docker image/network names, invalid SSH ports, invalid
SSH connect timeouts, and unsupported strict-host-key values fail closed at the
policy boundary instead of reaching Docker or OpenSSH.

The Bun TUI uses the runtime's model and thinking defaults from `[defaults]`.
The `[tui]` section controls terminal presentation settings loaded at startup.

Async followup queue defaults for background `task` completions and delegated `agent`
completions are currently umbrella app config, not TOML. The default lives in
`config/config.exs` as `config :coding_agent, :async_followups, default_queue_mode: :steer_backlog`.
Per-call tool inputs still override it: `task.queue_mode` and `agent.followup_queue_mode`.

## Memory

The `[memory]` section controls per-turn automatic recall. Its `auto_recall`
setting is a boolean that defaults to `true`; set it to `false` to disable the
bounded **Relevant memory** block attached to user messages. Automatic recall
also stays off when `[features] session_search = "off"`.

```toml
[memory]
auto_recall = true
```

## Feature Flags

Feature flags gate in-progress behaviour changes so they can be shipped incrementally
without ad-hoc environment variables.

```toml
[features]
session_search               = "default-on" # durable memory ingest and search (default)
routing_feedback             = "default-on" # task fingerprinting + routing feedback (default)
skill_synthesis_drafts       = "default-on" # skill synthesis draft pipeline (default)
```

`session_search` defaults to `"default-on"`: durable memory ingest and search
are active on a stock install (retention 30 days, max 500 documents per scope;
runs whose summaries look like they contain a secret are dropped entirely, not
redacted). Set it to `"off"` to disable. The learning-loop flags
(`routing_feedback`, `skill_synthesis_drafts`) also default to `"default-on"`.

Valid rollout states:

| State | Meaning |
|---|---|
| `"off"` | Feature fully disabled (kill-switch). |
| `"opt-in"` | Legacy pre-promotion state; behaves like `"off"` unless the caller explicitly opts in. |
| `"default-on"` | Enabled unless explicitly disabled. |

Each flag can be overridden via an environment variable using the pattern
`LEMON_FEATURE_<FLAG_NAME>` (SCREAMING_SNAKE_CASE):

```bash
LEMON_FEATURE_SESSION_SEARCH=off       # kill switch for durable memory
LEMON_FEATURE_ROUTING_FEEDBACK=default-on
```

Config validation fails cleanly if a flag is set to an unrecognised state.

## Canonical Sections

Use only these top-level sections:

- `defaults`
- `runtime`
- `budgets`
- `features`
- `secrets.sources.<source_id>`
- `profiles.<agent_id>`
- `providers.<name>`
- `gateway`
- `tui`
- `logging`
- `automation`

A deprecated `[agent]` table still loads, with a warning in the log, `lemon
doctor` and `lemon config validate`. It is read exactly as if it had been
moved:

| `[agent]` key | Read as |
|---|---|
| `default_provider`, `default_model`, `default_thinking_level` | `[defaults]` `provider`, `model`, `thinking_level` (an existing `[defaults]` key wins) |
| `theme` | `[tui]` `theme` |
| anything else, including `[agent.<sub>]` tables | `[runtime]` / `[runtime.<sub>]` (an existing `[runtime]` key wins) |

`lemon config migrate` rewrites the global config and the current project's
config this way, and `lemon setup` does the same when it finds an existing
file. Both keep comments and unrelated tables, write the original to
`config.toml.bak-<UTC timestamp>` first, and leave the file untouched when the
rewrite cannot be verified (for example multi-line values inside `[agent]`).

These sections fail validation and runtime loading:

- `[agents.<id>]` -> move to `[profiles.<id>]`
- `[tools.*]` -> move to `[runtime.tools.*]`

`lemon config migrate` renames both headers as well.

## External secret sources

External sources are read-only adapters integrated into
`LemonCore.Secrets.resolve/2`; they are not another secret store. Resolution is
ordered as follows:

1. Lemon's encrypted store;
2. enabled external sources ordered by `priority`, then source id;
3. the same-name environment variable when `env_fallback` is enabled.

A successful source that does not contain the requested name continues to the
next source. Any enabled source configuration, spawn, timeout, output, parse,
or bootstrap failure stops resolution before the ordinary environment
fallback. This fail-closed behavior prevents an unhealthy configured manager
from being silently bypassed. `env_fallback: false` disables both the external
and environment fallbacks; internal bootstrap reads use only the encrypted
store and ordinary environment path so sources cannot recurse.

Every source requires the exact TOML boolean `enabled = true`. A quoted
`"true"`, unknown setting, unknown source type, relative executable path with a
slash, shell command string, or out-of-range limit fails validation. Programs
are started directly from an argv array, never through a shell. Each child gets
only a small operating environment (`HOME`, platform path/temp/locale fields,
and `NO_COLOR`) plus explicitly passed variables. Stdout and stderr are
captured together under one byte limit and are never returned in errors,
status, logs, or proof output.

Common source settings:

| Setting | Default | Contract |
| --- | --- | --- |
| `type` | required | `onepassword`, `bitwarden`, or `command` |
| `enabled` | `false` | Only the exact boolean `true` enables execution |
| `priority` | `100` | Integer `0..1000`; lower runs first |
| `executable` | provider default | Absolute path or bare executable name |
| `timeout_ms` | `3000` | Integer `100..30000` |
| `max_output_bytes` | `65536` | Integer `1..1048576`, stdout and stderr combined |
| `cache_ttl_ms` | `0` | Integer `0..300000`; `0` disables caching |

The optional cache is bounded to 32 process-local entries and disappears on
restart. It never persists source values to config or the encrypted store.

### 1Password

Map each Lemon secret name to an `op://` reference. Lemon invokes `op read
--no-newline [--account ACCOUNT] -- REFERENCE` separately for each mapping.
If `auth_secret` is set, Lemon resolves that bootstrap credential only from its
existing encrypted store or same-name environment fallback and gives it to the
child as `auth_env`. Without `auth_secret`, an already authenticated local `op`
session or the named ambient auth variable may be used.

```toml
[secrets.sources.onepassword]
type = "onepassword"
enabled = true
priority = 10
executable = "op"
timeout_ms = 3000
max_output_bytes = 65536
cache_ttl_ms = 0
account = "team"
auth_secret = "op_service_account_token"
auth_env = "OP_SERVICE_ACCOUNT_TOKEN"
refs = { anthropic_api_key = "op://Lemon/Anthropic/api-key", openai_api_key = "op://Lemon/OpenAI/api-key" }
```

### Bitwarden Secrets Manager

Bitwarden uses `bws secret list PROJECT_ID --output json` and accepts only a
JSON list of unique non-empty `{"key": ..., "value": ...}` objects. Store the
bootstrap access token in Lemon under `access_token_secret`, or provide the
same-name environment variable. `access_token_env` controls the variable name
passed to `bws`; an optional `server_url` must be credential-free HTTPS with no
query or fragment.

```toml
[secrets.sources.bitwarden]
type = "bitwarden"
enabled = true
priority = 20
executable = "bws"
project_id = "team-project-id"
access_token_secret = "bws_access_token"
access_token_env = "BWS_ACCESS_TOKEN"
# server_url = "https://vault.example.com"
```

### Arbitrary command

Command sources accept only an argv array. Output is UTF-8 `NAME=VALUE`, one
entry per line; blank lines and lines beginning with `#` are ignored. Names
must be unique and values non-empty. `pass_env` copies only the listed ambient
variables. `secret_env` maps a child environment name to an existing Lemon
encrypted-store/same-name-environment secret; it never resolves another
external source.

```toml
[secrets.sources.local_helper]
type = "command"
enabled = true
priority = 30
argv = ["/usr/local/bin/lemon-secret-helper", "export", "--profile", "prod"]
timeout_ms = 2000
max_output_bytes = 32768
cache_ttl_ms = 0
pass_env = ["HELPER_PROFILE"]
secret_env = { HELPER_TOKEN = "helper_bootstrap_token" }
```

Inspect readiness without invoking any source, then perform a redaction-safe
live test:

```bash
lemon secrets sources status --json
lemon secrets sources test --json
lemon secrets sources test local_helper
```

These commands reveal source id/type, readiness, provenance, counts, output
byte count, duration, and stable error kinds only. They never reveal secret
values. `lemon secrets check` reports a resolved credential only as `present`.

## Dotenv Autoload

Lemon can auto-load a `.env` file at startup:

- `./bin/lemon-tui`: loads `<cwd>/.env` where `<cwd>` is the agent working directory (`--cwd`, or current directory).
- `./bin/lemon-gateway`: loads `.env` from the directory where you launch the script.

By default, existing environment variables are preserved. `.env` values only fill missing variables.

## OpenAI Codex (ChatGPT OAuth)

Lemon supports the **Codex subscription** provider as `openai-codex` (it uses the ChatGPT OAuth JWT, not `OPENAI_API_KEY`).
The canonical config key is `providers.openai-codex`; `providers.openai_codex` is also accepted for backward compatibility by native Lemon/CodingAgent runs.

Primary setup paths use the installed `lemon` command, or the matching source
wrapper from a checkout:

```bash
# Installed release
lemon setup
lemon model --provider openai-codex

# Source checkout
./bin/lemon setup
./bin/lemon model --provider openai-codex

# Contributor-level Mix alternatives
mix lemon.setup
mix lemon.onboard.codex
```

What it does:
- Resolves Codex OAuth credentials via `LemonAi.Auth.OpenAICodexOAuth`
- Stores credentials in encrypted secrets
- Writes `providers.openai-codex.auth_source = "oauth"` plus `providers.openai-codex.oauth_secret`
- Optionally updates `[defaults]` provider/model
- Uses an interactive arrow-key TUI for selection steps when running in a real terminal
- Listens on the localhost OAuth callback automatically and falls back to manual paste only if the callback cannot be captured

The onboarding flow opens the OpenAI auth URL directly and stores the returned OAuth credentials in Lemon secrets.

On a headless machine, or when port 1455 is busy, use the device-code sign-in
instead: `lemon model openai-codex --auth device` prints
`https://auth.openai.com/codex/device` and a one-time code, waits for you to
approve it on any device, and stores the same refreshable login (it also works
with `--non-interactive`).

To force a token explicitly, set:
- `OPENAI_CODEX_API_KEY` (preferred)
- `CHATGPT_TOKEN` (fallback)

## OpenAI-Compatible Endpoints

Lemon ships built-in presets for local inference servers and hosted open-model
APIs that speak the OpenAI Chat Completions protocol. A preset provider accepts
any model ID (`ollama:qwen3:32b`, `lm_studio:qwen2.5-coder-7b`, ...); model IDs
may contain `:`. Model specs accept the underscore or dashed id (`lm-studio:...`);
`[providers.<id>]` tables also accept omp spellings such as `llama.cpp` and
`ollama-cloud`.

### Local servers (no API key needed)

| Provider | Default `base_url` | Base-URL env | Optional key env |
| --- | --- | --- | --- |
| `ollama` | `http://127.0.0.1:11434/v1` | `OLLAMA_BASE_URL`, `OLLAMA_HOST` | `OLLAMA_API_KEY` |
| `lm_studio` | `http://127.0.0.1:1234/v1` | `LM_STUDIO_BASE_URL` | `LM_STUDIO_API_KEY` |
| `llama_cpp` | `http://127.0.0.1:8080/v1` | `LLAMA_CPP_BASE_URL` | `LLAMA_CPP_API_KEY` |
| `vllm` | `http://127.0.0.1:8000/v1` | — | `VLLM_API_KEY` |
| `litellm` | `http://localhost:4000/v1` | `LITELLM_BASE_URL` | `LITELLM_API_KEY` |

Requests go out without an `Authorization` header unless a key resolves (env
variable, `api_key`/`api_key_secret`, or the default secret `llm_<id>_api_key`).
`base_url` in config wins over the base-URL environment variables; environment
values are normalized to a `/v1` root (`OLLAMA_HOST=gpu-box` becomes
`http://gpu-box:11434/v1`). A `base_url` written in config must include the
OpenAI-compatible root (usually `/v1`).

```toml
[providers.ollama]
base_url = "http://gpu-box:11434/v1"

[defaults]
provider = "ollama"
model = "ollama:qwen3:32b"
```

### Hosted presets (API key required)

| Provider | `base_url` | Key env |
| --- | --- | --- |
| `ollama_cloud` | `https://ollama.com/v1` | `OLLAMA_CLOUD_API_KEY` |
| `together` | `https://api.together.xyz/v1` | `TOGETHER_API_KEY` |
| `deepinfra` | `https://api.deepinfra.com/v1/openai` | `DEEPINFRA_API_KEY` |
| `nvidia` | `https://integrate.api.nvidia.com/v1` | `NVIDIA_API_KEY` |
| `novita` | `https://api.novita.ai/openai/v1` | `NOVITA_API_KEY` |
| `baseten` | `https://inference.baseten.co/v1` | `BASETEN_API_KEY` |
| `venice` | `https://api.venice.ai/api/v1` | `VENICE_API_KEY` |
| `synthetic` | `https://api.synthetic.new/openai/v1` | `SYNTHETIC_API_KEY` |
| `nanogpt` | `https://nano-gpt.com/api/v1` | `NANO_GPT_API_KEY` |
| `zenmux` | `https://zenmux.ai/api/v1` | `ZENMUX_API_KEY` |
| `aimlapi` | `https://api.aimlapi.com/v1` | `AIMLAPI_API_KEY` |
| `siliconflow` | `https://api.siliconflow.com/v1` | `SILICONFLOW_API_KEY` |
| `siliconflow_cn` | `https://api.siliconflow.cn/v1` | `SILICONFLOW_CN_API_KEY` |
| `gmi_cloud` | `https://api.gmi-serving.com/v1` | `GMI_API_KEY` |
| `qianfan` | `https://qianfan.baidubce.com/v2` | `QIANFAN_API_KEY` |
| `aiand` | `https://api.aiand.com/v1` | `AIAND_API_KEY` |
| `wafer_serverless` | `https://pass.wafer.ai/v1` | `WAFER_SERVERLESS_API_KEY` |
| `kilo` | `https://api.kilo.ai/api/gateway` | `KILO_API_KEY` |

Store a key with `lemon secrets set llm_<provider>_api_key <key>` or reference
one with `[providers.<provider>].api_key_secret`. Lemon never sends
`OPENAI_API_KEY` to a non-OpenAI provider.

### Model discovery

Preset models carry conservative defaults (128k context, 16k output; Ollama
8k output) until discovered. `lemon models --provider <preset> --discover`
lists what an endpoint serves (`GET /models`; Ollama uses `/api/tags` and
`/api/show` for context length), using `--base-url`, the base-URL environment
variable, or the default, and the provider's key environment variable when set.
This low-level CLI discovery does not read `[providers]` overrides or encrypted
credentials; use the picker for config-aware discovery, or pass `--base-url`
and the preset's environment key explicitly.
The TUI `/model` picker (daemon `models.list`) includes discovered models for
hosted presets with a credential and for local servers that are configured in
`[providers.<id>]` or through their base-URL environment variable; listings are
cached for five minutes and an unreachable server contributes no models.
Discovery caches are scoped to the endpoint, wire API, credential, headers and
model defaults; one account's listing is not reused for another account or
endpoint. Cache identifiers hash auth material. Registry-only preset lookup
uses the current default endpoint and environment credential, while the picker
uses its effective provider config. Discovery refuses redirects and URLs with
embedded credentials, queries or fragments; use `headers` for endpoint auth.

Any other OpenAI-compatible endpoint can still use the `openai` provider with a
custom `base_url`. Hosted provider ids with bundled catalogs (`opencode`,
`openrouter`, `zai`, `minimax`, `kimi`, `xai`, `mistral`, `groq`, `deepseek`,
`qwen`, ...) take the same `[providers.<id>]` table with `api_key_secret` and
optional `base_url`.

## Custom Providers and Models

A `[providers.<id>]` table whose id is not a built-in provider defines a custom
endpoint (the equivalent of omp's `models.yml` providers). Its models are
selected as `<id>:<model>` or `<id>/<model>` in `default_model`, `/model`,
`model_roles`, task/compaction selectors and `provider_routing.fallback_providers`,
and they appear in the TUI `/model` picker once the provider has a credential.

```toml
[providers.my-gateway]
api = "openai_completions"        # openai_completions | openai_responses |
                                  # anthropic_messages | google_generative_ai
                                  # (omp dashed spellings are accepted too)
base_url = "https://llm.internal/v1"
api_key_env = "MY_GATEWAY_KEY"     # or api_key_secret / api_key
# auth = "none"                    # keyless endpoint: no Authorization header
headers = { "X-Team" = "platform" }
# discovery = "openai"             # list models from {base_url}/models ("ollama": /api/tags)

[[providers.my-gateway.models]]
id = "qwen3-coder"
name = "Qwen3 Coder"               # default: id
context_window = 131072            # default: 128000
max_tokens = 16384                 # default: 16384
reasoning = false                  # default: false
input = ["text"]                   # "text" and/or "image"; default ["text"]
# cost = { input = 0.5, output = 1.5, cache_read = 0, cache_write = 0 }  # USD per 1M tokens
# headers = { "X-Model" = "qwen" } # override provider headers per model
```

- Credentials resolve from `api_key_env`, then `api_key`, then
  `api_key_secret`; a custom provider never receives another provider's key
  (no `OPENAI_API_KEY` fallback). With `auth = "none"` the provider is ready
  without a key. OpenAI-, Anthropic- and Google-compatible requests omit their
  generated credential header when no key resolves; configured headers still
  apply. Google-compatible endpoints use their own provider's options, not
  the built-in Google account's key or URL.
- `api` and `base_url` are required. A provider with `discovery` or without a
  `models` list accepts any model id (unlisted ids use the defaults above);
  `discovery` also lists the endpoint's models in the picker, cached by the
  shared model cache. Use `discovery = { type = "openai", timeout_ms = 5000 }`
  to bound the listing request. Discovery needs `api = "openai_completions"` or
  `"openai_responses"`; with `discovery = "ollama"`, `base_url` may be the
  server root (`http://127.0.0.1:11434`) and requests go to its `/v1` API.
  Wire roots are protocol-specific: OpenAI APIs usually use `/v1`, Anthropic
  uses an origin/prefix to which `/v1/messages` is appended, and Google uses
  a root such as `/v1beta` to which `/models/<id>:streamGenerateContent` is appended.
- On a built-in provider (`anthropic`, `openai`, ...), `headers` are sent with
  every request and `[[providers.<id>.models]]` entries add catalog models or
  replace the catalog entry with the same id, inheriting the provider's wire API
  and base URL.
- `lemon config validate` reports unknown `api`/`auth`/`discovery` values, a
  missing `base_url` when `api` or `discovery` is set, models without `id`, and
  invalid model limits, inputs and prices.
- Not supported (omp-only): per-model `compat` overrides, `modelOverrides`,
  `!command` secrets, and `proxy`/`litellm` discovery.

## Provider Onboarding (CLI)

For an installed release, start provider onboarding with `lemon model`. From a
source checkout, use the matching `./bin/lemon model` wrapper. The direct Mix
tasks below remain the contributor interface.

```bash
# Installed release
lemon model
lemon model --provider anthropic
lemon model --provider openai-codex
lemon model --provider gemini
lemon model --provider zai
lemon model --provider minimax

# Source checkout
./bin/lemon model
./bin/lemon model --provider anthropic
./bin/lemon model --provider openai-codex
./bin/lemon model --provider gemini
./bin/lemon model --provider zai
./bin/lemon model --provider minimax

# Contributor-level Mix alternatives
mix lemon.onboard
mix lemon.onboard anthropic
mix lemon.onboard codex
mix lemon.onboard gemini
mix lemon.onboard zai
mix lemon.onboard minimax
mix lemon.onboard.antigravity
mix lemon.onboard.copilot
```

`lemon setup` is the idempotent first-run journey: it derives config, secrets,
and provider readiness; creates missing config and a secrets master key without
replacing existing state; skips a provider that is already usable; and checks a
new provider configuration before it reports setup complete. Setup always runs
offline checks and normally runs a live provider check. Use
`lemon setup --skip-verify` only to defer that live check when offline.

The focused `lemon model` command onboards one provider. It requires a usable
encrypted secrets store; use `lemon setup` when a fresh machine still needs the
config/secrets bootstrap and readiness verification.

Provider onboarding flows:
- Let you choose a provider when none is passed
- Use an interactive arrow-key TUI for provider/auth/model selection when a TTY is available
- Run provider OAuth flow by default when supported, or prompt for an API key/token otherwise
- Capture localhost OAuth callbacks automatically when the provider redirect URI is local
- Store credentials in encrypted secrets with provider metadata
- Write the relevant `providers.<provider>` config keys
- Support `--set-default`, `--model`, and `--config-path`

API-key-only providers in the catalog are offered too: `google` (Gemini API),
`groq`, `cerebras`, `deepseek`, `mistral`, `huggingface`, `qwen` (DashScope),
`vercel_ai_gateway`, `opencode`, `opencode_go`, `minimax_cn`, `fireworks`,
`zai`, `kimi` and `minimax`, plus every hosted OpenAI-compatible preset
(`together`, `deepinfra`, `nvidia`, …). The pasted key is stored as
`llm_<provider>_api_key` and referenced through
`[providers.<provider>].api_key_secret`. For presets, `--set-default` lists the
models the endpoint reports for that key, and `--model` accepts any model id.

Provider readiness is visible through the source and packaged
`lemon providers status` command. It uses the same
`LemonAgent.ModelRuntime.Credentials` credential resolver as model execution, so env keys, encrypted
secret references, OAuth/default-secret paths, and provider-specific credential
shapes are checked the same way runtime calls check them. The response reports
booleans such as `credentialReady`, `apiKeyConfigured`,
`apiKeySecretConfigured`, `oauthSecretConfigured`, `baseUrlConfigured`, and
`envConfigured`; it does not return raw API keys, secret names, base URLs, or
env var names.


Fallbacks and credential-pool references can be edited through the same
packaged/source command boundary:

```bash
# Installed release (use ./bin/lemon from a source checkout)
lemon providers fallback add zai
lemon providers pool set burst --provider openai --provider zai \
  --strategy round_robin --activate
lemon providers pool credential add burst openai secret:openai_backup
lemon providers status --json
```

Only explicit `secret:NAME` and `env:NAME` references are accepted for pool
credentials; values remain owned by the encrypted secret store or process
environment. The command preserves unrelated comments, validates the complete
resulting TOML, and atomically replaces the selected global or project config.
Mutations apply by default; use `--dry-run` to preview. Removing a fallback,
deleting or updating an existing pool, and removing or clearing credential
references require the exact confirmation value shown by the preview:

```bash
lemon providers fallback remove zai --dry-run --json
lemon providers fallback remove zai --confirm zai
```

To keep several logins for one provider, sign in again under another secret
name and add that name to a pool; OAuth logins referenced from a pool refresh
like the default login:

```bash
lemon model anthropic --auth oauth --secret-name llm_anthropic_work
lemon providers pool credential add burst anthropic secret:llm_anthropic_work
```

The most recent onboarding selects its secret in the provider config; it does
not delete other stored accounts. To inspect or delete a different stored
account, use `lemon model anthropic --status --secret-name llm_anthropic_work`
or `--logout --secret-name llm_anthropic_work`. Named logout leaves the active
provider config unchanged unless that exact secret is the configured login.
Pool references to a deleted secret remain in config but no longer resolve;
remove them separately with `lemon providers pool credential remove`.


Memory-provider readiness is included in support-bundle
`memory_diagnostics.json`. These surfaces expose provider ids, enabled state,
source labels, scopes, timeout shape, and module load state without memory
document contents, raw provider config, secret values, prompts, tool output,
or provider error payloads.

Doctor support bundles include a core-owned `provider_diagnostics.json` snapshot
for offline support. That snapshot reports provider setup shape, credential
reference counts, ambient-provider booleans, and routing/pool/profile shape
without depending on runtime provider modules. It intentionally omits raw API
keys, secret names, raw base URLs, env var names, model prompts, and provider
responses.

Provider route previews are controlled by `runtime.provider_routing`:

```toml
[runtime.provider_routing]
enabled = true
fallback_providers = ["zai", "anthropic"]
fallback_models = ["openai:gpt-4o-mini", "@slow"]
default_pool = "burst"
default_profile = "ops"
require_credentials = true

[runtime.provider_routing.credential_pools.burst]
providers = ["openai", "zai", "anthropic"]
strategy = "round_robin" # priority | round_robin

[runtime.provider_routing.profiles.ops]
fallback_providers = ["zai"]
credential_pool = "burst"
distribution = { openai = 70, zai = 20, anthropic = 10 }
```

`lemon providers status` includes a redacted `routingConfig` block for effective
fallback/pool configuration and a `routing` block with the requested
provider/model, selected provider/model, fallback candidates, candidate
readiness booleans, selected routing profile, selected credential pool,
profile distribution weights, pool provider names, pool strategy, and
credential-reference counts. Pool/profile names and provider names are visible;
raw API keys, secret names, base URLs, and env var names are not.

Coding-agent default model resolution consumes the same routing policy
conservatively: if the default provider is not credential-ready and a configured
fallback/profile/pool provider is credential-ready with the same model id in
`LemonAi.Models`, Lemon selects that fallback before starting the supervised agent
loop. Pools default to priority order; `strategy = "round_robin"` rotates the
pool's starting provider through `LemonAgent.ModelRuntime.ProviderPoolRotator`,
a supervised BEAM process. Explicit user model specs are never rewritten at
resolution time.

The supervised coding-agent loop also wraps streams for default-model and
explicit-model sessions. `fallback_models` selects an ordered chain of concrete
`provider:model` selectors or `@role` aliases; alternatives on the same provider
are allowed. Existing `fallback_providers` routes remain useful when providers
host the same model id. Each candidate resolves its own provider options and
credentials; credentials from one provider are never reused for another.

Before output is committed, provider failures can move to the next model and
rate/usage limits can rotate through configured credential-pool entries.
Authentication failures refresh the same OAuth credential once on HTTP 401, then
rotate if refresh fails or the refreshed token is rejected. Static keys and
environment references cannot refresh. Provider retry hints are retained for
credential cooldowns. The model/credential that commits is pinned for subsequent
turns in that session, preserving provider caches.

For generic OAuth providers, `auth_source = "oauth"` makes the selected stored
login authoritative for both initial resolution and 401 refresh:
`oauth_secret`, then `api_key_secret`, then the provider's default secret name.
A missing selected login fails closed rather than using an ambient environment
key, inline key, or another account's default login. Other auth modes keep their
existing environment-first API-key precedence.

Malformed requests (for example HTTP 400) are terminal, including failures before
a stream starts. Context overflow reaches the existing once-per-turn compaction
recovery instead of replaying an unchanged prompt on another provider.

No automatic retry, credential rotation, or model fallback occurs after text,
thinking, or a tool-call event is committed, including whitespace text and
content carried only by a terminal message. The failure is surfaced with its
partial output, without executing unfinished tool calls. Caller cancellation
stays cancellation. This rule also applies to `[runtime.retry]` transient retries.

For a manual source-checkout smoke run without live credentials, run
`MIX_ENV=test mix run --no-start scripts/provider_fallback_smoke.exs`. It starts
an isolated native session and loopback fixture endpoint, rejects the primary
model with HTTP 503, and verifies the configured alternate model answers and
the session is persisted. The smoke script is not part of the CI test lane.

Google Gemini CLI onboarding (`lemon model --provider gemini`, or
`./bin/lemon model --provider gemini` from a checkout) resolves OAuth
credentials via `LemonAi.Auth.GoogleGeminiCliOAuth`, stores the encrypted payload
in `providers.google_gemini_cli.api_key_secret`, writes
`providers.google_gemini_cli.auth_source = "oauth"`, and can take
`--project-id <gcp-project-id>` to force a specific Code Assist project. The
contributor task is `mix lemon.onboard gemini`. At runtime, Lemon re-resolves
the active Gemini project from `providers.google_gemini_cli.project_id`,
`providers.google_gemini_cli.project_secret`, `LEMON_GEMINI_PROJECT_ID`,
`GOOGLE_CLOUD_PROJECT`, `GOOGLE_CLOUD_PROJECT_ID`, or `GCLOUD_PROJECT`, with
those values overriding the `projectId` stored inside the OAuth payload.

The onboarding alias `gemini` maps to the runtime provider `google_gemini_cli`. This is distinct from the AI Studio provider `google`, which expects a separate API key such as `GOOGLE_GENERATIVE_AI_API_KEY`.

Other subscription and browser sign-ins offered by `lemon model <provider>`:

| Provider | Sign-in | Stored as |
| --- | --- | --- |
| `openrouter` | Browser PKCE sign-in (callback on `http://localhost:54549/callback`, or paste the redirect URL); a pasted `sk-or-` key is checked and accepted | A durable OpenRouter API key in `providers.openrouter.api_key_secret` |
| `xai` | SuperGrok / X Premium+ device code (`--auth oauth`); API key remains the default | Refreshable login in `providers.xai.api_key_secret`, `auth_source = "oauth"` |
| `kimi_coding` (`kimi-code`) | Kimi Code device code (default) | Refreshable login in `providers.kimi_coding.api_key_secret`, `auth_source = "oauth"` |
| `zai` | GLM Coding Plan sign-in (`--auth oauth`): paste the full final `zcode://zai-auth/callback?...` redirect (or `code#state`, not a bare code); Lemon finds or creates an API key named `lemon` | A durable Z.AI API key in `providers.zai.api_key_secret` |

Refreshable logins renew shortly before expiry and when a provider rejects the
token. While `auth_source = "oauth"` is set, the provider's API-key environment
variables (for example `XAI_API_KEY` or `KIMI_API_KEY`) do not override the
stored login. `lemon model <provider> --status` reports the stored login or key
without printing it; `--logout` deletes it and its config references but does
not revoke it at the provider. `KIMI_CODE_OAUTH_HOST` overrides the Kimi auth
host; the `ZAI_OAUTH_*` variables override the Z.AI endpoints for allowlist
changes.

Token-grant requests do not follow redirects. Device-code deadlines include
time spent waiting for browser instructions and HTTP requests. Refresh and
persistence are serialized per stored login; waiting callers reload the same
secret before reusing or rotating it. A removed/replaced login is not recreated
from a stale reader, and expired or explicitly rejected tokens are never
returned as successful authentication after a failed refresh. Endpoint/HTTP
overrides exposed by library APIs are trusted caller options intended for
testing and controlled integrations, not untrusted remote input.

Antigravity OAuth client credentials resolve from Lemon secrets first:
- `google_antigravity_oauth_client_id`
- `google_antigravity_oauth_client_secret`

Environment variables are supported as fallback:
- `GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_ID`
- `GOOGLE_ANTIGRAVITY_OAUTH_CLIENT_SECRET`

Common non-interactive usage:

```bash
# Installed release
lemon model --provider antigravity --token <token> --set-default --model gemini-3-pro-high
lemon model --provider gemini --project-id your-gcp-project
lemon model --provider gemini --token <token> --set-default --model gemini-2.5-pro
lemon model --provider openai-codex --token <token> --set-default --model gpt-5.2
lemon model --provider github-copilot --enterprise-domain company.ghe.com
lemon model --provider github-copilot --skip-enable-models
lemon model --provider github-copilot --token <token> --set-default --model gpt-5
lemon model --provider zai --token <token> --set-default --model glm-5
lemon model --provider minimax --token <token> --set-default --model MiniMax-M2.7

# Source checkout
./bin/lemon model --provider antigravity --token <token> --set-default --model gemini-3-pro-high
./bin/lemon model --provider gemini --project-id your-gcp-project
./bin/lemon model --provider gemini --token <token> --set-default --model gemini-2.5-pro
./bin/lemon model --provider openai-codex --token <token> --set-default --model gpt-5.2
./bin/lemon model --provider github-copilot --enterprise-domain company.ghe.com
./bin/lemon model --provider github-copilot --skip-enable-models
./bin/lemon model --provider github-copilot --token <token> --set-default --model gpt-5
./bin/lemon model --provider zai --token <token> --set-default --model glm-5
./bin/lemon model --provider minimax --token <token> --set-default --model MiniMax-M2.7

# Contributor-level Mix alternatives
mix lemon.onboard.antigravity --token <token> --set-default --model gemini-3-pro-high
mix lemon.onboard.gemini --project-id your-gcp-project
mix lemon.onboard.codex --token <token> --set-default --model gpt-5.2
mix lemon.onboard.copilot --enterprise-domain company.ghe.com
mix lemon.onboard zai --token <token> --set-default --model glm-5
mix lemon.onboard minimax --token <token> --set-default --model MiniMax-M2.7
```

Anthropic provider auth supports either API keys or a Claude Pro/Max
subscription login.

API key flow:

```bash
lemon model anthropic --auth api_key
# or store the key directly:
mix lemon.secrets.set llm_anthropic_api_key_raw <token>
```

Subscription flow (browser sign-in, stored encrypted and refreshed automatically):

```bash
lemon model anthropic --auth oauth
```

```toml
[providers.anthropic]
auth_source = "oauth"
oauth_secret = "llm_anthropic_api_key" # written by sign-in; this is the default name
```

`auth_source` decides precedence: `"oauth"` uses only the subscription login
and ignores `ANTHROPIC_API_KEY`; `"api_key"` or no value uses the API key. A
stored login whose refresh is rejected fails closed. When no Lemon login is
stored, `auth_source = "oauth"` falls back to ambient Claude Code credentials
from `~/.claude/.credentials.json` or `CLAUDE_CODE_OAUTH_TOKEN` /
`ANTHROPIC_TOKEN`, preferring refreshable Claude Code credentials over a static
env token. See [Claude subscription sign-in](user-guide/cli.md#claude-subscription-sign-in-anthropic-oauth)
for `--status`, `--logout`, and refresh behavior.

## Web Tools (`websearch` / `webfetch`)

Lemon includes web tools under `runtime.tools.web`. For full setup and troubleshooting, see:
- [`docs/tools/web.md`](tools/web.md)
- [`docs/tools/firecrawl.md`](tools/firecrawl.md)

```toml
[runtime.tools.web.search]
enabled = true
provider = "brave"   # brave | exa | perplexity | duckduckgo | searxng | extension id
max_results = 5
timeout_seconds = 30
cache_ttl_minutes = 15

[runtime.tools.web.search.failover]
enabled = true
provider = "perplexity"

[runtime.tools.web.search.perplexity]
# Optional if PERPLEXITY_API_KEY / OPENROUTER_API_KEY is set.
api_key = "<perplexity-api-key>"
base_url = "https://api.perplexity.ai"
model = "perplexity/sonar-pro"

[runtime.tools.web.search.providers.searxng]
# Required only when selecting the SearXNG provider.
base_url = "https://search.example.com"
# Optional bearer token or Lemon secret name.
api_key_secret = "SEARXNG_API_KEY"

[runtime.tools.web.search.providers.exa]
# Optional if EXA_API_KEY is set.
api_key = "<exa-api-key>"

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

## Browser backends and existing Chrome

Browser tools default to Lemon's managed local Chromium backend. These
environment variables select an existing CDP browser or the opt-in MV3 relay:

| Variable | Default | Purpose |
|---|---|---|
| `LEMON_BROWSER_DRIVER_PATH` | auto | Browser Node driver path |
| `LEMON_BROWSER_CDP_ENDPOINT` | none | HTTP discovery or direct `ws`/`wss` CDP endpoint |
| `LEMON_BROWSER_ATTACH_ONLY` | `false` | Never launch a replacement browser |
| `LEMON_BROWSER_CDP_PORT` | `18800` | Managed local Chrome CDP port |
| `LEMON_BROWSER_RELAY_PORT` | `9224` | Loopback MV3 relay port |
| `LEMON_BROWSER_RELAY_TOKEN` | none | Required relay shared secret |
| `LEMON_BROWSER_BACKEND` | `local` | `local`, `controller`, `hybrid`, `browserbase`, `browser_use`, `firecrawl`, or `camofox` |
| `LEMON_BROWSER_HYBRID_LOCAL_BACKEND` | `local` | Local/private route used by `hybrid` |
| `LEMON_BROWSER_HYBRID_PUBLIC_BACKEND` | none | Required public route used by `hybrid` |
| `BROWSERBASE_API_KEY` / `BROWSERBASE_PROJECT_ID` | none | Browserbase hosted sessions |
| `BROWSER_USE_API_KEY` | none | Browser Use Cloud hosted sessions |
| `CAMOFOX_URL` / `CAMOFOX_API_KEY` | none | Camofox REST/Firefox server |

For the existing-Chrome relay, set `LEMON_BROWSER_CDP_ENDPOINT` to
`ws://127.0.0.1:<port>/cdp?token=<token>` and set attach-only mode. Treat that
endpoint as a secret: Lemon redacts common credential query parameters and
reports only endpoint hashes in status surfaces. Backend/controller identity is
explicit and fail-closed; an unavailable controller never falls back to a
different browser profile. See [`docs/tools/web.md`](tools/web.md).

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
- `defaults`: global default provider, model, and thinking level for native execution.
- `runtime`: runtime behavior and tool settings.
- `runtime.tools.web`: `websearch` / `webfetch` providers, guardrails, cache, and Firecrawl fallback.
- `runtime.tools.wasm`: WASM sidecar runtime controls and discovery paths.
- `profiles.<agent_id>`: assistant profiles (identity + defaults) used by gateway/control-plane.
- `runtime.compaction`: context compaction settings.
- `runtime.retry`: session retry of transient provider failures (backoff + retry-after).
- `runtime.max_tool_turns`: optional per-prompt cap on tool-using turns (default unlimited).
- `runtime.secret_obfuscation`: opt-in placeholder obfuscation of secrets in provider-visible text ([details](security/secret-obfuscation.md)).
- `tui`: terminal UI settings.
- `gateway`: Lemon gateway settings, including `queue`, `telegram`, `discord`, `sms`, `voice`, `xmtp`, `projects`, and `bindings`.
- `logging`: optional file logging configuration.
- `automation`: opt-in proactive automation (`daily_brief`).

## Automation

`[automation]` holds opt-in proactive automation. It currently has one key:

```toml
[automation]
daily_brief = "08:00"   # HH:MM, 24-hour, server-local wall-clock time
```

- `daily_brief` (default: unset) — when set, Lemon keeps one heartbeat cron job,
  `cron_daily_brief`, running every day at that time in the server's local
  timezone (DST-aware) for the default agent's main session
  (`agent:default:main`). The agent sends a short brief to your paired owner
  chat, or replies `HEARTBEAT_OK` and sends nothing.
- The job is reconciled when Lemon boots: a new or changed time takes effect at
  the next start, and removing the key removes the job.
- `lemon setup` offers to write this key (default: off); `lemon setup
  --daily-brief HH:MM` writes it non-interactively.
- A value that is not a `HH:MM` 24-hour time fails config validation
  (`automation.daily_brief: must be a HH:MM 24-hour time`).

See [Reminders, heartbeats, and the daily brief](user-guide/reminders-and-heartbeats.md).

## Gateway Projects and Bindings

When LemonGateway handles a Telegram message, it can optionally map that chat (or topic/thread) to a named
**project**. A project is a **working directory root** plus optional agent and
queue defaults.

Why it matters:
- The native executor runs with `cwd` set to the project root (so file edits/commands happen in the right repo).
- The gateway loads per-project config from `<project_root>/.lemon/config.toml` (which can override agent profiles,
  models, tool policy, etc. compared to your global `~/.lemon/config.toml`).
- If a chat has no bound project, runs use `gateway.default_cwd` when configured, otherwise the
  assistant home (`~/.lemon/agent/workspace`, or `$LEMON_AGENT_DIR/workspace`). Channel runs never
  default to your `$HOME`.

### Projects

Define projects under `[gateway.projects.<project_id>]`:

```toml
[gateway.projects.myrepo]
root = "/path/to/myrepo"
```

### Bindings

Bindings connect an incoming chat scope to a project, agent profile, and queue defaults:

```toml
[[gateway.bindings]]
transport = "telegram"
chat_id = 123456789

# Optional: bind this chat to a project (must match the `[gateway.projects.<id>]` key)
project = "myrepo"

# Optional: choose which agent profile to use (defaults to "default")
agent_id = "default"

queue_mode = "steer"
```

Notes:
- If you omit `project`, LemonGateway will run with `cwd` set to `gateway.default_cwd` when configured, otherwise the
  assistant home (`~/.lemon/agent/workspace`).
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

This installs bridge dependencies in `apps/lemon_channels/priv/node_modules`, next to `xmtp_bridge.mjs`, where Node resolves its imports.

### 2. Configure gateway XMTP

```toml
[gateway]
enable_xmtp = true

[gateway.xmtp]
env = "production"                  # production | dev | local
wallet_address = "${XMTP_WALLET_ADDRESS}"
wallet_key_secret = "XMTP_WALLET_KEY"  # secret ref; env fallback works if XMTP_WALLET_KEY is set
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
- `wallet_key_secret` is the canonical credential field. It can point to a Lemon secret name or to an env var name when using secret resolution with env fallback.
- Non-text XMTP messages currently receive a text-only fallback response.

## Voice

Voice transport is configured under `[gateway.voice]`.

```toml
[gateway.voice]
enabled = true
websocket_port = 4047
public_url = "https://example.com"
twilio_account_sid_secret = "twilio_account_sid"
twilio_auth_token_secret = "twilio_auth_token"
twilio_phone_number = "+1234567890"
deepgram_api_key_secret = "deepgram_api_key"
elevenlabs_api_key_secret = "elevenlabs_api_key"
elevenlabs_voice_id = "21m00Tcm4TlvDq8ikWAM"
elevenlabs_output_format = "ulaw_8000"
llm_model = "gpt-4o-mini"
system_prompt = "You are a helpful phone assistant."
max_call_duration_seconds = 600
silence_timeout_ms = 5000
```

Canonical voice settings are loaded from `gateway.voice`. Legacy `:lemon_gateway` app env
fallbacks remain only as temporary compatibility shims and should not be used for new setup.

## Telegram Voice Transcription

If enabled, Telegram voice notes are transcribed and the transcript is routed as a normal text message.

```toml
[gateway.telegram]
voice_transcription = true
voice_transcription_provider = "openai_transcribe"       # "openai_transcribe" | "local_transcript"
voice_transcription_model = "gpt-4o-mini-transcribe"  # optional
voice_max_bytes = 10485760                            # optional (default: 10MB)

# Optional OpenAI-compatible endpoint override. Credentials default to [providers.openai].
voice_transcription_base_url = "https://api.openai.com/v1"
```

Use `voice_transcription_provider = "local_transcript"` for local transcript
handling without an API key. Use `openai_transcribe` for real speech-to-text.

`mix lemon.doctor` checks this configuration: when voice transcription is
disabled the check is skipped, and when the provider requires an API key that
is missing it warns.

## Telegram File Transfer

Enable `/file put` and `/file get` (and optional auto-save for plain document uploads).

```toml
[gateway.telegram.files]
enabled = true
auto_put = true
auto_put_mode = "upload"  # "upload" | "prompt"
auto_send_generated_files = true       # optional: send generated files automatically after a run
auto_send_generated_max_files = 3      # optional: max generated files auto-sent per run (default: 3)
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

If no project is bound for the chat, the active root falls back to `gateway.default_cwd` (or the assistant home,
`~/.lemon/agent/workspace`).

When `auto_send_generated_files = true`, Lemon tracks generated files requested
by browser/media tools and sends up to
`auto_send_generated_max_files` files back to Telegram automatically at completion (using the same `max_download_bytes`
limit as `/file get`). `auto_send_generated_images` remains accepted as a
backward-compatible alias. SVG outputs are uploaded as Telegram documents
instead of photos because Telegram rejects SVG photo processing.

## Discord File Transfer

Enable Discord file transfer and optional generated-file auto-send.

```toml
[gateway.discord.files]
enabled = true
auto_put = true
auto_send_generated_files = true       # optional: send generated files automatically after a run
auto_send_generated_max_files = 3      # optional: max generated files auto-sent per run (default: 3)

# Optional safety rails
max_upload_bytes = 26214400            # optional (default: 25MB)
max_download_bytes = 26214400          # optional (default: 25MB)
```

When `auto_send_generated_files = true`, Lemon tracks generated files requested
by browser/media tools and sends up to `auto_send_generated_max_files` files
back to Discord automatically at completion. Generated files must fit within
`max_download_bytes`; explicit file-send requests are still delivered through
the normal attachment path. `auto_send_generated_images` remains accepted as a
backward-compatible alias.

## Discord Trigger Mode and Message Content Intent

Discord defaults to mention-gated routing in group channels and public threads.
Use `/trigger all` to opt a channel or thread into free-response routing for
unmentioned messages, and `/trigger mentions` to restore the default behavior.

```toml
[gateway.discord]
message_content_intent_enabled = true  # diagnostics declaration only
default_account_id = "default"          # optional account for ./bin/lemon send account-scoped lookups
default_channel_id = "1475727416549969980"  # optional default for ./bin/lemon send --to discord
default_thread_id = "1475727416549969991"   # optional thread
```

`message_content_intent_enabled` does not change Discord application settings.
It lets `channel_diagnostics.json` record that the operator has enabled the
privileged Message Content Intent in the Discord Developer Portal. Free-response
Discord support requires that portal setting plus a passing live external-sender
proof; mention-triggered Discord prompts do not depend on this declaration.

## Telegram Context Compaction

When a Telegram run approaches the model context limit, Lemon can proactively mark the session for compaction so the
next user message is automatically rewritten with a compact transcript and sent as a fresh session.

```toml
[gateway.telegram.compaction]
enabled = true
context_window_tokens = 400000  # optional override; if unset Lemon infers from the model and native executor
reserve_tokens = 16384          # optional safety margin before limit
trigger_ratio = 0.9             # optional; 0.9 means trigger at 90% of context window
```

## Telegram Pairing and Access

The Telegram adapter fails closed. It accepts updates only from chats listed in
`gateway.telegram.allowed_chat_ids`. With an empty or missing allowlist the bot is
**unpaired**: it drops every message and callback, logs a warning, and replies at
most once per chat every 10 minutes with
"This bot is not paired. Run `lemon gateway setup telegram`." `lemon doctor` reports
an enabled, unpaired Telegram adapter as a failure (`channels.telegram.allowlist`).

- `/whoami` is answered in any chat, paired or not, with the chat id and your user id.
  Use it to find the id of a group you want to add to `allowed_chat_ids`.
- `lemon gateway setup telegram` pairs interactively: it asks you to send `/start` to the
  bot, waits up to `--pair-timeout` seconds (default 120), and writes the chat id. For
  scripts: `lemon gateway setup telegram --non-interactive --token <token> --chat-id <id>`
  (`--chat-id` is repeatable).
- `allow_all_chats = true` explicitly accepts every chat when no allowlist is set. Anyone
  who finds the bot can then run the agent; doctor reports it as a warning.

In group chats (`group`, `supergroup`, `channel` peers) the router requires an approval
for every `bash`, `write`, `edit`, `patch`, and `hashline_edit` call,
because any member can prompt the agent.

## Trigger Mode (Mentions-Only)

Telegram group chats (like Discord) default to mentions-only: Lemon runs only on `@botname`, a reply to the bot, or a
slash command. Direct messages always run.
- `/trigger`: show current trigger mode.
- `/trigger mentions`: only run on `@botname`, reply-to-bot, or slash commands (default).
- `/trigger all`: run on all messages in this chat or topic (group admins only).
- `/trigger clear`: clear a topic override (forum topics only).
- `/cwd [project_id|path|clear]`: show, set, or clear the chat/topic working directory override used by future `/new` sessions.

Forum topic management:
- `/topic <name>`: create a new topic in the current Telegram forum supergroup.
