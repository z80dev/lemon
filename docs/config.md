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
# threshold_percent = 80      # optional: compact above 80% of the context window
# threshold_tokens = 150000   # optional: fixed token threshold (overrides percent)

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

Tool policies are parsed strictly by `LemonCore.ToolPolicy`. Unknown profiles,
unknown or conflicting keys, malformed allow/deny/block/approval values, and
unsupported approval modes fail closed rather than falling back to full
access. Omitting `[profiles.<id>.tool_policy]` retains the explicit runtime
default; supplying an invalid table produces a deny-all policy.

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

Entering plan mode automatically selects `model_roles.plan` only when configured,
whether the native session is live, stopped, or being created before its first run.
The stopped path uses the saved session's project configuration and journals the
planning model without starting an agent or requesting a model response. Project
overrides still take precedence over user-global roles; a profile's bootstrap
workspace does not replace the session's project configuration.
Exiting or approving a plan restores the execution model recorded on entry,
including after durable session resume. Invalid planning models fail before the
mode, selected model, branch, or new-session resume binding changes. `@commit` is
available to explicit model selectors and delegated tasks; it does not
automatically invoke a commit tool.

Compaction and abandoned-branch summaries choose `model_roles.compaction` first,
then `model_roles.smol` **only if configured**, otherwise the active session model.
An explicit compaction `:model` option takes precedence. Summary credentials and
provider stream options are resolved for that selected model together, including
background compaction, without changing the main session's model. Explicit
summary credential/stream-option overrides are retained.

### Native Task Subagents (`[runtime.task]`)

`[runtime.task]` tunes the native `task` tool. Like other sections it layers
global → project; every key is optional:

```toml
[runtime.task]
max_depth = 2              # -1 unlimited; 0 = the main session cannot delegate
max_runtime_ms = 0         # per-child wall-clock limit; 0 disables it
idle_ttl_ms = 300000       # park a completed live child after 5 min; 0 keeps it idle
request_budget = 200       # soft assistant-request budget per run; 0 disables it
request_budget_notice = true # send one wrap-up steer at the soft budget
worktree_merge = "none"    # default merge for worktree: true tasks: none | patch | branch
disabled_agents = ["sonic"]

[runtime.task.agent_models]
reviewer = "@slow"         # model or @role per persona ID
```

- `max_depth`: nesting limit. The main session is depth 0 and each child is one
  deeper; a session may delegate only while its depth is below `max_depth`, and
  children created at the cap never receive the `task` tool.
- `max_runtime_ms`: wall-clock limit for each child session; the child fails
  with a timeout error when it is exceeded.
- `request_budget`: completed assistant requests per child run, including schema
  correction requests. At the soft limit, the child receives one concise wrap-up
  steering message (unless `request_budget_notice = false`). At `ceil(1.5 × budget)`
  it is gracefully stopped and returns its latest visible output as partial,
  with `details.budget_exhausted = true`, `request_count`, and a stop annotation.
  `0` disables both thresholds. The task's optional `request_budget` parameter
  overrides this default per item, including batch/swarm children. Woken and
  revived children start a fresh count. Invalid structured output at exhaustion
  returns an explicit error result with the partial text, without correction
  retries; valid JSON is still decoded into `structured_output`.
- `idle_ttl_ms`: how long a successfully completed child stays live and idle.
  After the TTL, Lemon releases its session but retains its transcript and
  address. `0` keeps it idle until the parent session ends. A direct
  `write agent://<id-or-name>` wakes an idle child or revives a parked child with
  the same session ID, prior conversation, cwd/worktree, tools and model.
  The receipt's `delivery` is `woken`, `revived`, or `injected` (already running);
  a failed worker launch reports `failed`. Replies use async auto-delivery,
  including children originally launched synchronously. Concurrent messages
  share one revival. Broadcasts still target only running/queued relatives.
  Cancelled/killed children, failed children, and children whose cwd/worktree or
  transcript was removed refuse revival and point to `history://<id>`.
  Revival is scoped to the existing parent task family, not daemon restart.
- `worktree_merge`: what a successful `worktree: true` child does when the call
  omits `merge`: `none` keeps the worktree, `patch` applies the child's changes
  to the parent checkout, `branch` commits them to a kept review branch.
- `disabled_agents`: persona IDs hidden from the tool's agent list and refused
  at launch.
- `agent_models`: per-persona model or `@role` that replaces the persona's own
  `model`/`role`; an explicit task `model` still wins.

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

`LEMON_NODE_CAPABILITIES` (or `--capabilities`) sets the destination-local tool
ceiling to `all` or a comma-separated list such as `read,write,bash`. Every
remote execution context is intersected with this ceiling before the local
executor starts.

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
engine. Delegated subagents always run natively; `[runtime.task]` (above) only
tunes depth, runtime, merge-back and persona availability/models.

## External MCP Configuration

Lemon imports project MCP definitions from supported coding-tool configs;
Lemon's own `.lemon/mcp.json` entries take precedence. Other tools' user-global
configs require `LEMON_MCP_EXTERNAL_USER_DISCOVERY=1` (the omp user config is
read by default, and `CLAUDE_CONFIG_DIR` opts in Claude user files).
Disabled entries still claim their names; importing configuration does not
launch an MCP server. See [MCP management](skills.md#manage-named-mcp-servers).

OpenCode `opencode.json` and `opencode.jsonc` files accept comments and trailing
commas. After JSONC decoding, Lemon substitutes `{env:NAME}` and `{file:path}`
once within string **values**, including command arguments, environment
values, URLs and headers; object keys are not interpolated. Environment
values retain their exact bytes, including quotes, backslashes, newlines and
leading/trailing whitespace. An unset environment variable substitutes an
empty string.

File placeholders resolve relative to the containing config file, accept
absolute paths, and resolve `~/` against the discovery home when one is
available. File contents are trimmed of leading/trailing whitespace; a missing
or unreadable file (or `~/` without a discovery home) substitutes an empty
string. Neither inserted environment values nor inserted file contents are
interpreted again as JSON, interpolation directives or file imports.

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
- `LEMON_TUI_THEME`, `LEMON_TUI_DEBUG` — TUI appearance and debug mode
- `LEMON_SECRET_OBFUSCATION_ENABLED` — overrides `[runtime.secret_obfuscation] enabled`
- `<PROVIDER>_API_KEY`, `<PROVIDER>_BASE_URL` (e.g., `ANTHROPIC_API_KEY`, `OPENAI_BASE_URL`, `OPENCODE_API_KEY`, `ZAI_API_KEY`, `MINIMAX_API_KEY`); local servers use `OLLAMA_BASE_URL`/`OLLAMA_HOST`, `LM_STUDIO_BASE_URL`, `LLAMA_CPP_BASE_URL` and `LITELLM_BASE_URL` only when config sets no `base_url` (see [OpenAI-Compatible Endpoints](#openai-compatible-endpoints))
- `LEMON_WASM_ENABLED`, `LEMON_WASM_RUNTIME_PATH`, `LEMON_WASM_TOOL_PATHS`, `LEMON_WASM_AUTO_BUILD`
- `LEMON_TERMINAL_BACKENDS_ALLOW`, `LEMON_TERMINAL_BACKENDS_DENY`, `LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL`
- `LEMON_DOCKER_TERMINAL_IMAGE`, `LEMON_DOCKER_TERMINAL_MEMORY`, `LEMON_DOCKER_TERMINAL_CPUS`, `LEMON_DOCKER_TERMINAL_PIDS_LIMIT`, `LEMON_DOCKER_TERMINAL_NETWORK`
- `LEMON_DOCKER_TERMINAL_READ_ONLY_ROOTFS`, `LEMON_DOCKER_TERMINAL_TMPFS_SIZE`, `LEMON_DOCKER_TERMINAL_ALLOWED_IMAGES`
- `LEMON_SSH_TERMINAL_TARGET`, `LEMON_SSH_TERMINAL_WORKDIR`, `LEMON_SSH_TERMINAL_PORT`, `LEMON_SSH_TERMINAL_CONNECT_TIMEOUT`, `LEMON_SSH_TERMINAL_STRICT_HOST_KEY_CHECKING`, `LEMON_SSH_TERMINAL_ALLOWED_TARGETS`
- `LEMON_GATEWAY_HEALTH_PORT`, `LEMON_ROUTER_HEALTH_PORT`
- `LEMON_NODE_OPERATOR_TOKEN`, `LEMON_NODE_TOKEN`, `LEMON_NODE_ALLOW_INSECURE_CONTROLLER`, `LEMON_NODE_CAPABILITIES`
- `LEMON_LOG_FILE`, `LEMON_LOG_LEVEL`
- `BRAVE_API_KEY`, `PERPLEXITY_API_KEY`, `OPENROUTER_API_KEY`, `FIRECRAWL_API_KEY`

Terminal backend policy validates Docker image/network/resource settings and
SSH port/timeout/host-key settings before `exec` launches a backend. Invalid
Docker limits, invalid Docker image/network names, invalid SSH ports, invalid
SSH connect timeouts, and unsupported strict-host-key values fail closed at the
policy boundary instead of reaching Docker or OpenSSH.

Background `exec` launches fail closed when admission is unavailable: there is
no direct-execution fallback, including `exec_sync` or internal callers passing
`use_lane_queue: false`. Each logical launch has a fixed identity, bound to its
session owner and a validated request fingerprint. Reusing that identity with
the same request reconciles the original receipt; changing the request or owner
is a conflict. Intentionally running the same command twice creates two identities.
Accepted receipts track the existing process. A missing reply or lost process
owner can produce `outcome_unknown`, which is not a rejection and must not trigger
automatic replay. Inspect/reconcile the fixed identity; any recovery that repeats
external effects must be explicitly requested. Receipt projections exclude
commands, environment values, and exception details. Clearing completed output
retains a small redacted identity tombstone so clearing logs cannot authorize a
duplicate launch.

### Background process admission

Background process admission limits are umbrella application configuration,
not TOML or agent-controlled tool inputs:

```elixir
config :coding_agent,
  background_process_limit: 8,
  background_pending_limit: 32,
  background_admission_timeout_ms: 5_000,
  background_admission_wait_ms: 1_000
```

The process limit holds capacity for the managed command's live lifetime, not
just the launch callback. `lane_caps.background_exec` remains a separate launch
concurrency cap; main/subagent lanes retain their existing callback semantics.
The pending limit bounds waiting admissions per LaneQueue; the acceptance ledger
also bounds in-flight registrations. Process/pending limits are integers up to
1,000,000 (process minimum 1, pending minimum 0). Admission deadline/wait values
must be integers from 1 to 86,400,000 milliseconds. Invalid settings fail
explicitly at startup, without echoing the invalid value.

The caller wait budget yields `{:queued, identity}` independently of execution
lifetime. Queued cancellation, deadline expiry, or abandonment prevents later
start. An explicitly supplied `owner_pid` keeps a deliberately yielded queued
launch owned after the submitting tool task returns; losing that owner cancels
pending work. Accepted work outlives its transient submitting caller, but is
signaled when its supplied owner exits. Without `owner_pid`, accepted work
deliberately continues until completion, explicit cancellation, or its separately
requested execution timeout. Use foreground commands with background execution,
not shell daemonization, for an inspectable managed lifetime.

Cancellation is a request: `:killing` does not free capacity. On local Unix
launches, the runtime binds and persists an isolated process-group identity
before permitting the command to execute. A root shell's Port exit is not a
workload-termination witness: surviving descendants keep an `outcome_unknown`
receipt and the lifetime slot. The owning session reconciles actual group
membership and releases once only after no live members remain. It retains the
group through root exit so later cancellation can target verified descendants,
never a recycled positive root PID. Lost ownership or failed observation remains
unknown and charged, not a license to signal an unverified group.
Before forwarding stdin that may end the root, the runtime durably retains live
members observed under the root's matching identity. After root exit, verified
cancellation requires a surviving previously bound member with matching birth
identity. If the root and all previously bound members disappear before another
member can be bound, the numeric PGID alone is insufficient proof: cancellation
remains unknown and charged, requiring independently verified recovery.

A host process group cannot prove termination of remote SSH/container work,
PTY work in a separate session, or Windows job descendants; wrapper exits in
these cases conservatively remain unknown and charged. Repeating cancellation
after the host wrapper disappears still requires the backend-aware full-workload
witness; an empty host group cannot confirm remote or separately contained work.
A lost BEAM process owner also retains its persisted identity and capacity. Nothing is automatically
relaunched. Queue/store restart reconciles surviving registered processes before
admission.
The internal operator API `ProcessManager.confirm_external_termination(id, owner)`
may release unknown capacity only after independently verifying termination of
the entire owned workload, not merely the root shell; it is an assertion, not a
liveness probe or agent tool, and refuses a launch still starting. The original
uncertain receipt remains uncertain.

`ProcessManager.admission_counts/0` exposes bounded active, queued, rejected,
expired, canceled, unknown, and occupied counts, with no commands or secrets.
Unknown historical outcomes are distinct from currently occupied capacity.
Receipt/count lookup failures report unavailability, never an empty/idle state.
Synchronous completion-wait expiry retains the fixed identity as
`{:error, {:outcome_unknown, identity}}`; reconcile instead of rerunning.
Direct `ProcessSession.start_link` is an internal/test primitive, not an agent
admission bypass. This contract prevents duplicate managed starts for an identity;
it does not claim exactly-once external side effects.

Unknown Bash launch receipts are tool errors with retained `process_id`,
`status: "unknown"` and `classification: "outcome_unknown"`, not failed-start
receipts. Startup rejections preserve their actual pre-execution failure reason.
Every durable load, including late permission recovery or reopening, restores
capacity and live owner monitors before permitting a new admission.

Cleared identity tombstones and historical unknown receipts do not expire.
The default finished-process TTL (86,400 seconds) and cleanup interval
(300 seconds) do not bound ledger rows; recovery, count and artifact scans grow
with that history. Observable retained local workloads reconcile after 100 ms
plus scan cost using a system-wide `ps` snapshot. Ownership-lost and nonlocal
unknown workloads do not schedule this polling. These are local containment
contracts, not proof of remote workload termination.


The Bun TUI uses the runtime's model and thinking defaults from `[defaults]`.
The `[tui]` section controls terminal presentation settings loaded at startup.

Async followup queue defaults for background `task` completions and delegated `agent`
completions are currently umbrella app config, not TOML. The default lives in
`config/config.exs` as `config :coding_agent, :async_followups, default_queue_mode: :steer_backlog`.
Per-call tool inputs still override it: `task.queue_mode` and `agent.followup_queue_mode`.

### Background process output capture

Background `bash` capture limits are umbrella application configuration, not
TOML or environment overrides:

```elixir
config :coding_agent, :process_output,
  max_retained_bytes: 1_048_576,
  max_artifact_bytes: 16_777_216,
  max_owner_artifact_bytes: 134_217_728,
  max_runtime_artifact_bytes: 536_870_912
```

`ProcessManager.exec/1` and `ProcessSession.start_link/1` accept the same
per-call options, which override application defaults. Every byte limit must
be a positive integer; invalid limits refuse launch before opening an output
file or running the command. `max_log_lines` remains an additional positive
line-count bound (default 1,000).

Capture is bounded, not backpressure or cancellation. The process continues
running when capture fills; its status and external effects are unchanged.
The private 0600 artifact keeps the **head** of output, at most the capacity
reserved before launch. The in-memory diagnostic buffer keeps the **tail**,
at most `max_retained_bytes` including held partial lines and consumed
newlines. Lines longer than `min(65_536, max(max_retained_bytes - 1, 1))`
bytes are emitted as segments. A one-byte budget charges a segment and its
newline separately. Old lines are evicted before adding bounded copied bytes.
The process/store's retained binary payload is at most twice the per-process
memory budget; stored logs mirror the process tail, not an independent ring.
Parsing scans bounded windows without concatenating or splitting an entire
incoming chunk. Additional live binary scratch is at most two line segments.
This is a reachable-output-payload bound, not a bound on BEAM heap/GC overhead:
the received port message, polling result copies, transport buffers and
subscriber/mailbox accumulation remain outside it (subscriber fanout is #88).

`poll`, `read_output`, and `bash_output` expose structured `output` counters:
`received_bytes`, `retained_bytes`, `discarded_bytes`, `artifact_bytes`,
`artifact_capacity`, `artifact_discarded_bytes`, `artifact_truncated`,
`artifact_error`, `artifact_size_unknown`, `artifact_reclaimed`, and
`finalized`. Retained-byte costs include newlines even though displayed lines
omit them. `received_bytes = retained_bytes + discarded_bytes`; for a known
artifact size, `received_bytes = artifact_bytes + artifact_discarded_bytes`.
Filling an artifact exactly is not truncation until another byte is received.
An incomplete artifact is labelled **Partial output**, never full output.

Reservations are serialized by the existing process store. Live captures
charge their full reserved capacity, so concurrent sessions cannot overfill
the owner/runtime budgets. Finalization returns unused capacity, charging
the bytes actually saved. When admitting another capture, the store reclaims
stopped sessions' artifacts oldest first within the owner, then runtime-wide
if needed. Live sessions' files are not reclaimed; if their reservations
consume a budget, the new capture receives a smaller capacity, possibly zero.
Ownerless sessions share one owner budget, and all owners share the runtime
budget. Reclamation preserves log/status records, clears the file reference
and sets `artifact_reclaimed`; old artifact handles stop resolving. Owner
authorization is unchanged. Pre-quota persisted artifacts also count.

All record mutations and deletion share the reservation owner's serialization,
so concurrent cursor/status updates cannot restore a reclaimed path or erase a
reservation. A store-only restart preserves surviving registered captures.
New capture reservations must be persisted and synced before launch; unavailable
accounting storage or an unmeasurable legacy artifact fails admission instead of
treating unknown disk usage as zero. Existing captures keep their charged
reservation if later persistence fails.

A write failure closes the output device once, preserves the bounded tail
and real execution status, and exposes only a fixed error classification.
The closed file is checked for a partially written prefix so counters remain
truthful. If its size cannot be checked, `artifact_size_unknown` is true,
`artifact_discarded_bytes` is `nil`, and the full reservation remains charged.
Failed file removal preserves its record/reference and storage charge;
successful explicit cleanup/TTL cleanup releases them. TTL cleanup may remove
an expired completed capture while its finalized session still lingers for
final polling: its output device is already closed. A live capture that is not
finalized remains charged even if cancellation/timeout has classified its
record as terminal. No repeated writes are attempted after failure or after
the capture limit is reached.


## Memory

The `[memory]` section controls per-turn automatic recall. Its `auto_recall`
setting is a boolean that defaults to `true`; set it to `false` to disable the
bounded **Relevant memory** block attached to user messages. Automatic recall
also stays off when `[features] session_search = "off"`.

```toml
[memory]
auto_recall = true
write_approval = false # require human approval for remember mutations when true
```

`memory.write_approval` gates every `remember` add, replacement, and deletion
across user, memory, and project targets. Agent skill authoring has its own switch:

```toml
[skills]
write_approval = false # require human approval for skill_manage mutations when true
```

Both switches default to `false` and use normal global/project config precedence.
Enabled writes use the existing execution approval UI with bounded, escaped,
credential-redacted target/action/content previews and a digest binding the full
mutation to its owner/workspace. `skill_manage report` remains read-only.
Approval never bypasses existing content screening, audit, pinning or isolation.
Denial leaves the target unchanged; an unavailable/expired approval also denies.
Prompts expire after 60 seconds unless the trusted runtime supplies a timeout.
Background learning reviews (including draft creation), cron runs, and channels
without approval controls fail closed without consuming saved grants.
Interactive native sessions and Telegram/Discord use their existing approval flow.
These switches gate agent tool writes, not explicit operator memory/skill services.


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

Malformed TOML is a load error, not an empty configuration; missing files still
use defaults. `lemon config validate` lists both checked files on success and
failure. Fix syntax errors in the named file, then run
`lemon config validate --verbose`. For removed settings, run
`lemon config migrate`. Doctor records invalid configuration as failing checks
and continues with the remaining diagnostics.

Normal configuration loads, including `lemon config show` and
`mix lemon.config show`, also validate and reject invalid resolved values rather
than quietly running with them. `LemonCore.Config.Modular.load(validate: false)`
is an explicit programmatic opt-out for inspecting unresolved validation issues;
removed settings and malformed TOML are always rejected. Validation messages name
the input files and expected TOML types or allowed choices, never the supplied
value. Resolved errors list both files because environment and project overrides
can combine with global settings.

Both `show` commands use the same redacted summary: `false` and `0` are values;
only absent values display `(not set)`. Fields overridden by declared environment
variables are marked `(from LEMON_...)` (or the active alias), without printing
environment secrets.

Use `[tui] theme` or `LEMON_TUI_THEME` for appearance; this is the only runtime
theme setting. Lemon runs agents natively rather than through vendor CLI engines.

The example leaves Telegram credentials and project/chat bindings commented
out; enable only real bindings and use `bot_token_secret` instead of writing a
token into TOML. XMTP's `wallet_address`, `wallet_key`, and `private_key` support
whole-value `${NAME}` environment references, resolved before the bridge connects.
Unset references are omitted; use `wallet_key_secret` to read an encrypted secret.

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
uses the current default endpoint and environment credential. The picker and
native model selectors (including configured defaults, qualified selectors and
provider-native colon IDs) instead use the full effective provider settings:
the same endpoint, headers and first healthy selected-pool/default credential
as requests. This also applies to dynamic presets with no explicit `models`
list. Native lookup is cache-only; a scope without discovered metadata uses
conservative preset context, output and capability defaults rather than another
endpoint's or principal's cached values. An explicit preset provider retains
native colon IDs (for example, Ollama's `qwen:7b`) even on a cold cache or after
credential rotation; a registered provider prefix alone does not change that
identity. Explicit model structs retain their caller-supplied metadata.
Discovery refuses redirects and URLs with embedded credentials, queries or
fragments; use `headers` for endpoint auth.

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

Qualified `[defaults] model` selectors resolve their provider before default
provider routing, including when no `[defaults] provider` is set. Provider-native
IDs such as `qwen3:32b`, and models explicitly listed under the selected provider,
remain that provider's model IDs rather than being split as new selectors.

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
- Header names are case-insensitive. Requests apply provider `headers` as
  defaults, then per-model `headers`, then explicitly supplied caller stream
  headers. For example, provider `X-Tenant = "A"` and model `x-tenant = "B"`
  send one `x-tenant: B`; a caller's `X-TENANT = "C"` sends one `x-tenant: C`.
  This precedence applies to all four supported compatible wire APIs.
  Provider-required protocol rules still apply (for example, custom Anthropic
  beta tokens extend rather than remove the required beta tokens).
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
  Picker discovery and subsequent model resolution use the same first healthy
  credential from the selected routing pool as native requests, followed by
  the configured default credential candidate. An unresolved pool reference
  does not authorize another pool or a built-in provider's ambient key.
  Cache listings and model metadata are isolated by the actual resolved
  credential (hashed, never stored in cache metadata), endpoint, wire API
  and headers.
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

The wrapper preserves explicit authentication-refusal results instead of
converting them into unset API keys. In particular, missing or invalid Codex
`auth_source` cannot enable provider-level fallback to ambient tokens.

Idle and live model switches bind request options to their actual owning model
before classification or completion. Selected-login refusal stays authoritative
after a switch; switching to a keyless provider clears the previous authority.
Fallback sanitation uses the current invocation's options owner, not the session's
startup provider. Same-provider explicit headers and pool precedence are preserved.
Same-provider rebinding retains the original caller header layer separately:
provider defaults remain below the destination model's headers, and only genuine
caller overrides take precedence. Headers derived from the source model never
become caller overrides on a later request.

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

`MIX_ENV=test mix run --no-start scripts/live_provider_ownership_smoke.exs`
exercises public native Session and Agent model switches, missing-selected-login
refusal (including plan-role selection), successful keyless transitions,
switch-then-fallback header isolation and same-provider rebinding with no caller
headers and with genuine caller overrides, using fixture credentials and loopback
HTTP only. Its refusal and credential-leak checks scan complete captured events
and logs, including large tool-schema snapshots.

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

## Tool Approval Modes

```toml
[runtime.tools]
approval_mode = "write" # ask | write | yolo
```

| Mode | Approvals required |
| --- | --- |
| `ask` | All non-read tools (`write` and `exec`) |
| `write` | Executable tools (`exec`) only |
| `yolo` | No tier-based approvals |

Leaving the setting unset preserves existing behavior, including configured
per-tool and source-specific approval requirements. Reads/search/web fetches
are `read`; built-in file/state mutations are `write`; shell/process control,
eval/debug, browser evaluation, MCP/WASM/extension and unknown tools are `exec`.
LSP navigation and edit previews are `read`; applying edits, raw requests and
server reloads are `exec`.

Config supplies only the default. A canonical tool policy can set
`approval_mode = "ask"`, `"write"` or `"yolo"` in
`[profiles.<id>.tool_policy]` or through the existing PolicyStore session/runtime
policy. Explicit policy modes win over the config default. Policy intersections
retain the stricter mode, so delegated work cannot weaken parent approval gates.
The existing `approvals` map (`always`/`never`) overrides tier defaults in every
mode; `require_approval`, parent floors, and explicitly configured MCP approval
requirements remain mandatory. An `on_tool_call` hook's revised arguments are
used for approval resolution and the approval preview, not the original input.

## Anchored Edit Visibility

Enable seen-line enforcement in user or project `.lemon/config.toml`:

```toml
[runtime.tools.edit]
enforce_seen_lines = true # default false
```

Every replaced/deleted line and insertion anchor must have been displayed by a
numbered read of that snapshot in the current session. Omitted summary bodies and
window gaps do not count; refusals provide a range-read hint without writing.
Historical recovery checks visibility before translating unchanged anchors.
Plain `old_text`/`new_text` replacements are unaffected. The setting must be a
boolean; default false preserves clients that construct tags without tracked
reads. Tool hosts can explicitly override it with the `:enforce_seen_lines` option.
See [file tools](tools/files-and-search.md#anchored-edit-recovery-and-formatting)
for visibility and snapshot-retention details.

## Web Tools (`websearch` / `webfetch`)

Lemon includes web tools under `runtime.tools.web`. For full setup and troubleshooting, see:
- [`docs/tools/web.md`](tools/web.md)
- [`docs/tools/firecrawl.md`](tools/firecrawl.md)

```toml
[runtime.tools.web.search]
enabled = true
provider = "brave"   # brave | exa | perplexity | tavily | kagi | jina | duckduckgo | searxng | extension id
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

# tavily, kagi and jina take the same shape (api_key or api_key_secret);
# TAVILY_API_KEY / KAGI_API_KEY / JINA_API_KEY are used when unset.
[runtime.tools.web.search.providers.tavily]
api_key_secret = "TAVILY_API_KEY"

[runtime.tools.web.fetch]
enabled = true
max_chars = 50000
timeout_seconds = 30
cache_ttl_minutes = 15
max_redirects = 3
max_body_bytes = 5242880 # Streaming response limit (5 MiB); body_too_large is terminal.
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

## Computer Use

Native app control through LCU is off by default. See
[`docs/tools/computer-use.md`](tools/computer-use.md) for requirements and
approvals. `LEMON_COMPUTER_USE_*` environment variables override these keys.

```toml
[runtime.tools.computer_use]
enabled = false
chrome = false
# lcu_root = "~/.local/share/lcu/current"
# node = "<lcu_root>/agent-tools/node/bin/node"
declined_origins = []
```

## Conversation checkpoints

```toml
[runtime.tools.checkpoint]
enabled = false
```

Enable the paired model tools `checkpoint(goal)` and `rewind(report)` to collapse
exploratory conversation into a retained branch summary. This never restores
files and needs no confirmation; operator `/rewind` is unchanged.
The filesystem tool is named `fs_checkpoint` (no `checkpoint` alias).
See [checkpoint tools](tools/checkpoint.md).

## Tool intent

Tool schemas include an optional string `i` by default: a concise, 2–6 word
present-participle phrase such as `"Reading model role settings"`. Lemon strips
this presentation-only field before argument validation/coercion and execution,
uses it as the approval rationale, and retains it in tool-call start event
arguments (ACP uses it as the tool-call title). Intent is not authorization and
is never added to tool-call telemetry. Persisted assistant arguments are unchanged.

```toml
[runtime.tools]
intent_tracing = true # false omits the injected property from provider schemas
```

Direct `LemonAgent.Agent` and `CodingAgent.Session` callers can override this with
`:intent_tracing`; stateless loops use `AgentLoopConfig.intent_tracing`. Disabling
schema injection does not let stray presentation fields reach tools. A tool
whose schema already defines `i` is exempt: Lemon preserves its native parameter
and does not treat it as intent. Closed union alternatives receive the optional
property individually. Lemon's OpenAI providers explicitly use non-strict tool
schemas, so `i` remains optional without changing `required` or
`additionalProperties`.

## Tool Disclosure

Every tool a session exposes sends its name, description and JSON schema with
each model request. `[runtime.tools.disclosure]` can move tools behind two
bridge tools: `tool_search` (look up a deferred tool and read its schema) and
`tool_invoke` (call it by name). A bridged call runs the same policy, approval,
checkpoint, cancellation and per-session mutation-lock path as a direct call,
and `tool_invoke` never runs in parallel with other calls. Plan mode judges a
bridged call by the tool it reaches.

```toml
[runtime.tools.disclosure]
enabled = true           # false keeps every tool directly exposed
budget_tokens = 40000    # legacy profile: defer only above this estimate
catalog_tokens = 2000    # size of the deferred-tool list in tool_search's description
max_results = 5          # default tool_search result count
profile = "legacy"       # "legacy" (default) or "coding" (opt-in experiment)
pinned = []              # tool names that always stay directly exposed
```

- **`legacy`** (default): built-in tools stay exposed. The MCP, extension and
  WASM tools are deferred only when the estimated schema cost of the whole
  catalog exceeds `budget_tokens`; below it the tool list is unchanged.
- **`coding`**: an experiment for coding sessions. Only the coding core stays
  directly exposed — `read`, `write`, `edit`, `patch`, `ls`, `find`, `grep`,
  `ast_grep`, `lsp_diagnostics`, `fs_checkpoint`, `bash`, `bash_output`,
  `kill_process`, `websearch`, `webfetch`, `read_skill`, `recall`, `todo`,
  `ask`, enabled `checkpoint` / `rewind`, `task`, `wait`, `agent_message` and `parent_question` — plus `pinned`
  names. Every other resolved tool, including browser, media, automation and
  other optional built-ins, is deferred whenever there is one to defer;
  `budget_tokens` is not consulted. Whether this improves cost, latency or task
  success is not established, so it is not the default.

Tools the session policy denies are never searchable or invokable. Tools passed
as `extra_tools` always stay exposed, and sessions started with an explicit
`tools` list skip disclosure. Names `tool_search` and `tool_invoke` are
reserved; a real tool using either name is dropped while disclosure is active.

WASM host aliases resolve from this same frozen, policy-authorized runtime
catalog, not only the schemas currently shown to the model. A permitted optional
built-in such as `browser_tabs` therefore remains a host capability under either
profile. Host calls retain the catalog's wrapped implementation and the current
plan-mode gate; reload replaces that inventory so removed authority is not kept
alive by an old host lookup. Neither WASM tools nor the disclosure bridge tools
can be host targets, preventing recursive calls through the deferred catalog.

Target closures are wrapped before disclosure partitions the catalog. Direct,
bridged and host execution restore secret arguments before target hooks and
approval checks. Plan-mode bridge and host writes reuse the session's restricted
write/edit wrappers, including the final directory check after hook replacement;
schema deferral does not create another execution authority.

The tool list is computed at session start and on extension reload, never per
turn. `extensions_status` reports the active profile, the exposed and deferred
tool names, estimated schema tokens before and after disclosure, and a
`catalog_digest`: a SHA-256 over the exposed schemas, the deferred tools, their
sources and the session's tool policy. Matching digests identify matching
schemas, source metadata and policy; they do not attest to external tool state
or outcome. An authority change recomputes the catalog at the next run's session
startup/resume boundary, or when explicitly supplied to a lifecycle reload, and
changes its identity even if the visible schemas remain identical. Denied tools
are removed from the rebuilt bridge, not merely hidden from its search results.
The `[:coding_agent, :tool_disclosure, :applied]` telemetry event also carries the
profile and safe catalog digest, with before/after schema estimates and tool
counts as measurements, so isolated trial collectors need not log raw schemas.
Diagnostic event version `1` adds `:search` events with a matched count and
success/error status, and `:invoke_rejected` events with a bounded rejection
reason (`unknown_tool`, `invalid_arguments` or `invalid_request`). These events
contain no query, tool name, arguments or error text. Pre-aborted calls do not
count as discovery or incorrect-call failures.

For a controlled trial, scope the profile to the trial instead of the user's
global config: put the section in the benchmark project's `.lemon/config.toml`
(applies only to sessions in that project), set
`LEMON_TOOL_DISCLOSURE_PROFILE=coding` on a separately launched runtime (it
overrides file config for that process only), or start sessions
programmatically with `CodingAgent.Session.start_link(tool_disclosure: [profile: :coding])`.

## Sections

- `providers.<name>`: API keys and base URLs per provider.
- `defaults`: global default provider, model, and thinking level for native execution.
- `runtime`: runtime behavior and tool settings.
- `runtime.tools.web`: `websearch` / `webfetch` providers, guardrails, cache, and Firecrawl fallback.
- `runtime.tools.wasm`: WASM sidecar runtime controls and discovery paths.
- `runtime.tools.disclosure`: deferring tool schemas behind `tool_search` / `tool_invoke` (see [Tool Disclosure](#tool-disclosure)).
- `profiles.<agent_id>`: assistant profiles (identity + defaults) used by gateway/control-plane.
- `runtime.compaction`: context compaction settings. Automatic compaction runs when the request
  exceeds the context window minus `reserve_tokens`. Optional `threshold_percent` (integer 1–100,
  percent of the window) or `threshold_tokens` (positive integer; wins over the percent) lower that
  threshold; they never raise it above the reserve limit. Invalid values fail config validation.
  `/context` and `sessions.context` report the effective threshold.
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

## Learning Reminders (skills.json)

Learning reminder settings use the existing skills configuration, **not**
`config.toml`: global `~/.lemon/agent/skills.json` (or `LEMON_AGENT_DIR/skills.json`)
and project `<cwd>/.lemon/skills.json`. Project keys override global keys.

```json
{
  "learning_nudge": {
    "enabled": true,
    "memory_turn_interval": 10,
    "skill_tool_threshold": 15
  }
}
```

| Key | Default | Meaning |
| --- | --- | --- |
| `enabled` | `true` | Enable main-session in-band reminders; `false` skips reminders and forgets that session's counters on its next turn. |
| `memory_turn_interval` | `10` | User turns without `remember` before suggesting a save; repeats at this interval if no save is made. |
| `skill_tool_threshold` | `15` | Tool dispatches in the previous completed run, without `skill_manage`, before a one-turn skill creation/patch suggestion. |
| `background_review.enabled` | `false` | Replace in-band reminders with isolated reviews of completed eligible private main-session runs. |
| `background_review.model` | parent model | Optional Lemon model specification (for example `openai:gpt-4o-mini`); uses configured provider credentials. |
| `background_review.min_interval_ms` | `300000` | Minimum time between review submissions per live session (maximum 86400000); reviews never overlap. |
| `background_review.max_digest_bytes` | `4096` | Maximum redacted untrusted digest bytes (clamped to 256–16384 to retain the trust envelope); individual summaries use memory ingest's 2000-byte truncation budget plus its truncation marker. |
| `background_review.max_tool_turns` | `3` | Maximum assistant tool-use turns (maximum 10). |
| `background_review.timeout_ms` | `60000` | Review execution timeout (maximum 300000). |

Numeric settings must be positive integers; invalid values use their defaults.
Configuration is read at the next user turn. With background review disabled,
the fixed reminder text is bounded volatile context with no extra model calls,
memory reads, automatic saves or transcript scans. Enabling background review
costs **one additional model run per accepted trigger**, using the parent model
unless `background_review.model` selects a cheaper configured model. Reviews use
only private `remember` and draft-create/non-pinned-patch `skill_manage`, never
shared grants or channel delivery. Subagents, cron/sub-sessions, review sessions
and internal followups are excluded. Limits/counters disappear on session exit
or restart. See [learning reminders](user-guide/skills.md#learning-reminders).
