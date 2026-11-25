# Lemon Configuration (TOML)

Lemon uses a single canonical configuration file in TOML format. Configuration is layered:

1. Global: `~/.lemon/config.toml`
2. Project: `<project>/.lemon/config.toml` (preferences and policy narrowing only; see
   [Project config trust](#project-config-trust))
3. Environment variables (override file values; the operator's `~/.lemon/.env` may
   auto-populate missing env vars at startup; see [Dotenv Autoload](#dotenv-autoload))
4. Credential references resolved through Lemon's encrypted store, explicitly
   enabled external sources, and the ordinary same-name environment fallback

Runtime state and policy are separate from config. Per-session or per-route "current"
model/thinking values override config defaults at runtime, but they are not persisted in
`config.toml`.

## Project config trust

A project `.lemon/config.toml` arrives with the repository, so anyone who can
commit to a repository you open can write it. Lemon therefore lets a project
file set only these keys; every other project key keeps the global value.

Preferences (the project value wins):

- `defaults.provider`, `defaults.model`, `defaults.thinking_level`
- `[model_roles]`; `[tui]` (`prompt_history` may only be turned off; the
  terminal client applies the same rule)
- `[model_routing]`: only `max_cost_usd`, and only lowered. `enabled` and
  `rules` are operator-only, because routing picks the model each request is
  sent to; a project routing table is ignored and reported. Move routing rules
  you relied on in a project file to the global config. A routing rule's
  `@role` (and the default-model fallback) resolves against the global
  `[model_roles]` and `[defaults]`, never a project override of that role.
- `[runtime.compaction]`, `[runtime.task.agent_models]`
- `runtime.tools.auto_resize_images`, `runtime.tools.edit.enforce_seen_lines`,
  `[runtime.tools.bash.interceptor]`
- `[runtime.tools.disclosure]` (`profile` limited to `auto`, `coding`, `legacy`)
- `name`, `description`, `avatar` of a profile the global file already defines
  (`profiles.default` always exists); a profile's `model` is global-only and
  is ignored and reported in a project file. When a delegated run takes its
  model from the profile or the router default, the session resolves that
  selector (an `@role` included) against the global config only, never a
  project `[model_roles]` override. A delegated persona model or explicit
  `@role` is resolved in the delegating session, which passes the concrete
  `provider:model` it admitted (and a project origin, when it has one), so the
  delegated run's own working directory cannot redefine it

Policy that may only be narrowed:

- `runtime.tools.approval_mode`: only stricter (`yolo` < unset < `write` < `ask`)
- `runtime.task.per_call_model` (lower) and `per_call_model_allow` (intersect)
- `runtime.task.disabled_agents` (added to the global list)
- `runtime.max_tool_turns`, `[budgets]` caps: no higher than the global cap
- `runtime.tools.bash.git_guard`, `runtime.secret_obfuscation.enabled`,
  `memory.write_approval`, `skills.write_approval`: only `true`
- `memory.auto_recall`: only `false`; `[features]` flags: only `"off"`
- `runtime.tools.lsp.servers.<id>.disabled`: only `true`
- `profiles.<id>.tool_policy`: intersected with the effective global profile
  policy, including the inherited `runtime.tools.approval_mode`; a project
  policy with a weaker `approval_mode`, a per-tool approval other than
  `always`, or `workspace_read_exempt = true` that the global policy does not
  already grant is ignored

Everything else is **operator-only** and must live in `~/.lemon/config.toml`:
`[providers.*]` (including `base_url`, `location`, credentials and secret
references), `[secrets]` and external secret sources, `[gateway]` (including
voice reply hosts and keys), web search/fetch hosts, keys and SSRF switches
(`allow_private_network`, `allowed_hostnames`), `runtime.extension_paths` and
`[runtime.extensions]`, `[runtime.shell]`, `runtime.git_path`, LSP server
commands/args/env, WASM settings, `[runtime.provider_routing]` and credential
pools, `[logging]`, `[automation]`, update settings, and any key not listed
above.

An ignored project key is never silently dropped: runtime loading logs a
warning, and `lemon config validate` and `lemon doctor` report one error per
key naming the file and key. `lemon providers` refuses to write provider
routing to `--scope project`.

Operational backup policy is also intentionally separate from TOML. Use
`lemon backup contract|create|list|verify|restore`; there are no implicit
backup directories or credential-inclusion settings in `config.toml`. See
[Back up and restore Lemon user state](user-guide/backups.md) for the versioned
`~/.lemon` data contract.

## Optional GenAI span export

OpenTelemetry export is disabled by default. It is deployment/application
configuration, not a `config.toml` table or session policy. In the embedding
application's `config/runtime.exs` (before `:lemon_agent` starts):

```elixir
config :lemon_agent, :gen_ai_spans,
  enabled: true,
  exporter: LemonAgent.GenAISpans.OpenTelemetry
```

`lemon_agent` declares only an **optional** `opentelemetry_api` dependency.
Install/start an OpenTelemetry SDK and the desired transport exporter in the
host application, and configure its processors, endpoint, authentication and
sampling there. The API alone does not record spans; the adapter is compiled
only when that API is present. Packaged deployments must include these optional
apps explicitly to use the adapter.

For another exporter, set `:exporter` to a module implementing
`LemonAgent.GenAISpans.Exporter` and supply its `:exporter_config` term. No
OpenTelemetry dependency is needed for custom exporters. All callbacks receive
only allowlisted labels/usage and native monotonic timestamps; no prompt,
response, tool arguments/results, credentials or raw exception terms are
exported. There is no content-capture setting. Restart `:lemon_agent` after
changing this configuration.

See [telemetry](telemetry.md#optional-genai-span-export) for attributes,
duration units, lifecycle limitations and the exporter contract.

## Listener exposure (breaking default change)

The control plane (`4040`), LemonWeb (`4080`),
and node gateway (`4044`) bind **127.0.0.1 by default**, including releases.
Existing LAN clients must explicitly opt in and restart:

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `LEMON_CONTROL_PLANE_BIND_IP` | `127.0.0.1` | Main operator WebSocket / HTTP listener |
| `LEMON_WEB_BIND_IP` | `127.0.0.1` | Operator browser interface |
| `LEMON_CONTROL_PLANE_NODE_BIND_IP` | `127.0.0.1` | Node-only gateway |
| `LEMON_CONTROL_PLANE_NODE_PORT` | `4044` | Node-only port; `0` disables it |
| `LEMON_CONTROL_PLANE_REMOTE_HTTP` | empty | Comma-separated subset of `openai,acp` |
| `LEMON_CONTROL_PLANE_ALLOWED_ORIGINS` | empty | Comma-separated exact browser origins allowed on `/ws` and `/acp/ws` |

Loopback peers of the main and A2A listeners must send a `Host` of `localhost`,
a loopback IP, the listener's bind address, or (main) a host from
`LEMON_CONTROL_PLANE_ALLOWED_ORIGINS` / (A2A) the hostname of `public_url`
(any path ignored); anything else, including `*.localhost`, is 403 before
parsing, which defeats DNS rebinding. `/ws` and `/acp/ws` refuse a WebSocket
upgrade whose `Origin` is not exactly (scheme, host, port) the control plane's
own origin, LemonWeb's origin (`http://` + `localhost`/loopback/bind IP +
`LEMON_WEB_PORT`, plus `LEMON_WEB_HOST` with its URL scheme and port), or a
`LEMON_CONTROL_PLANE_ALLOWED_ORIGINS` entry; other localhost ports are refused.
Native clients that omit `Origin` (Lemon's CLI, TUI and ACP clients) are
unaffected; a native client that does send `Origin` must send one of those
exact accepted values, or add its origin to `LEMON_CONTROL_PLANE_ALLOWED_ORIGINS`.

Bind values must be literal IPv4 or IPv6 addresses. Non-loopback main and web
binds require `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` and refuse
`LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK=true`. Put TLS in front of
LemonWeb: an operator login over plaintext LAN HTTP exposes the credential.
Remote peers on the main listener get only `GET /ws` and `GET /healthz`;
everything else is 404 unless the corresponding HTTP API is explicitly enabled
with `LEMON_CONTROL_PLANE_REMOTE_HTTP` and its dedicated
`LEMON_OPENAI_COMPAT_API_TOKEN` / `LEMON_ACP_API_TOKEN`.

OpenAI and ACP require authentication locally too. If their dedicated token is
unset they accept the operator token, including the launcher's private
`~/.lemon/run/control-plane-<port>.token` file. The explicit default-off loopback
compatibility flag permits tokenless local APIs only when no token is configured;
it also gates tokenless local A2A. Never enable it behind a local reverse proxy.

Forward node traffic only to **4044**: its `/ws` accepts node and enrollment
credentials, never operator or tokenless clients; `/healthz` identifies
`lemon-node-gateway`. Occupied or disabled gateway ports are nonfatal but reported
unavailable by `LemonControlPlane.NodeGateway.status/0`. The launcher reserves a
gateway port alongside the main/web ports in `~/.lemon/ports.env`.

These runtime listeners are separate from the Lemon Bot product backend,
which defaults to `127.0.0.1:4100`. For browser access over SSH, keep it on
loopback and use the [Bot headless sign-in flow](getting-started/lemon-bot.md#headless-or-ssh-server).
For another execution machine, use the
[node-gateway or managed SSH route](user-guide/attaching-a-bot-machine.md#prepare-the-controller);
changing a bind address does not itself configure TLS or make an invite reachable.

Launchers default epmd and Erlang distribution to loopback. Explicit long-name
`--name` distribution opts out of the distribution-interface default; epmd's
`ERL_EPMD_ADDRESS` can be set explicitly. Run `lemon doctor` to inspect listener
binds. A pre-upgrade epmd may still listen on all interfaces: with Lemon stopped,
run `epmd -kill` or restart the computer.
The dedicated source control-plane and gateway launchers use the same defaults.
Source launchers generate or reuse `~/.lemon/cookie` (mode `0600`) unless a cookie
is explicitly supplied through `RELEASE_COOKIE`, `LEMON_GATEWAY_NODE_COOKIE`, or
`LEMON_GATEWAY_COOKIE`, never a cookie command-line argument. See the
[distribution cookie boot contract](security/threat-model.md#distribution-cookie).
Both primary launchers load the saved
`LEMON_CONTROL_PLANE_NODE_PORT` from `ports.env`, including `0` (disabled);
an explicit environment value takes precedence.

These listener settings are environment/application configuration, not new
`config.toml` tables. The [generated environment registry](config-registry.md)
lists declared types, defaults, aliases and owning applications. Regenerate it
from a source checkout with
`mix run --no-start scripts/generate_config_registry.exs`; this does not start
applications or resolve credentials.

### Worker and invitation environment

Worker CLI inputs are destination-local and do not belong in `config.toml`:

| Variable | Purpose |
| --- | --- |
| `LEMON_NODE_TRUST_LOOPBACK_LISTENER` | Default unset: require a loopback controller/tunnel listener owned by this user before sending credentials. Set exactly `1` only to explicitly trust a listener under another UID. |
| `LEMON_NODE_ALLOW_INSECURE_CONTROLLER` | Explicit override for non-loopback `ws://`; use only with a verified encrypted/authenticated overlay or development. Prefer `wss://`. |
| `LEMON_NODE_CAPABILITIES` | Destination-local tool ceiling: `all` or comma-separated tool names; `--capabilities` takes precedence. |
| `LEMON_NODE_LAUNCH_CWD` | Launch directory used when `node join --cwd` is absent; otherwise falls back to the process directory. |
| `LEMON_NODE_OPERATOR_TOKEN` | Pairing authority for operator-authorized enrollment; never distribute it to Bot/browser clients. |
| `LEMON_NODE_TOKEN` | Explicit existing node session token; normally let the worker use its private stored credential instead. |
| `LEMON_GATEWAY_HEALTH_PORT`, `LEMON_ROUTER_HEALTH_PORT` | Managed worker/enrollment processes set both to `0` to avoid competing with controller health listeners. |

`node join` isolates DETS state under
`~/.lemon/nodes/state/<sha256-of-trimmed-name>/`; configuration, skills, sessions
and SQLite credentials remain shared. `LEMON_AGENT_DIR` and `LEMON_STORE_PATH`
are not worker-isolation switches. See [worker status and recovery](user-guide/cli.md#inspect-a-named-worker).

On the **controller**, `LEMON_CONTROL_PLANE_PUBLIC_WS_URL` selects the reachable
secure WebSocket URL embedded in invitations (`ws://` is allowed only on
loopback). Route workers to the node-only gateway, not an exposed operator API.
`LEMON_NODE_SOURCE_CHECKOUT` selects an absolute destination-local checkout for
generated join recipes. `LEMON_NODE_INSTALL_VERSION` and
`LEMON_NODE_INSTALL_BASE_URL` select an exact supported artifact version and
HTTPS installation base; runtime feature checks still apply. These variables
configure invitation generation, not destination provider credentials.


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
# Global config or LEMON_EXTENSION_PATHS only; a project .lemon/config.toml value is
# ignored. Relative paths resolve against the global config directory (~/.lemon),
# never the session or project directory. A project's .lemon/extensions is never
# loaded; list its absolute path here to trust it.
extension_paths = []
# Optional cap on tool-using turns per prompt. Unset or 0 = unlimited (default).
# max_tool_turns = 200
# Optional absolute path of the git Lemon runs for its own repository reads
# (environment context, sessions.changes, @git-diff, omp discovery) and the TUI
# status line. Global config only. Unset: the first git in /usr/bin,
# /usr/local/bin, /opt/homebrew/bin, /bin; PATH is never searched. Git >= 2.31.
# git_path = "/usr/bin/git"

[runtime.extensions]
# false: no session compiles an extension file, installs an extension hook,
# registers an extension provider or starts the WASM runtime; manifest
# diagnostics stay available.
enabled = true
# true also loads the global ~/.lemon/agent/extensions (never a project dir).
# Like `enabled`, operator-only: ignored in a project .lemon/config.toml.
# Any configured extension that fails to load fails session start (reload stops
# the session). Extensions compile once per path set and recompile only when a
# source file's bytes change (or on an explicit reload).
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
notifications = "auto" # auto | osc | bell | off (Bun terminal client)
prompt_history = true # persist ↑ prompt recall to ~/.lemon/tui-history/history.sqlite3 (Bun terminal client)
vim_mode = false # start the Bun terminal client's composer in Vim-style modal editing

[logging]
# Optional: write logs to a file for later analysis.
# If unset/empty, file logging is disabled and logs go to stdout/stderr only.
file = "~/.lemon/log/lemon.log"
# Optional: handler level for the file (defaults to "debug").
level = "debug"

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
# unauthorized_dm_behavior = "pair" # opt-in owner-approved codes for unknown human DMs
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
# unauthorized_dm_behavior = "pair" # opt-in; DMs require an explicit allowed_channel_ids entry

[gateway.xmtp]
env = "production"                  # production | dev | local
wallet_address = "${XMTP_WALLET_ADDRESS}"
wallet_key_secret = "xmtp_wallet_key"
db_path = "~/.lemon/xmtp-db"
poll_interval_ms = 1500
connect_timeout_ms = 15000
require_live = true
mock_mode = false
# Required: XMTP inbox ids allowed to start runs. With no allowlist every
# inbound message is dropped.
allowed_inboxes = ["<sender inbox id>"]
# allow_all = true               # explicit opt-out: accept every sender when allowed_inboxes is empty

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
# workspace_read_exempt = true # optional tri-state boolean; false wins, nil neutral
[[gateway.bindings]]
transport = "telegram"
chat_id = 12345678
agent_id = "default"
```

Tool policies are parsed strictly by `LemonCore.ToolPolicy`. Unknown profiles,
unknown or conflicting keys, malformed allow/deny/block/approval values, and
unsupported approval modes fail closed rather than falling back to full
access. `workspace_read_exempt` is a sparse tri-state boolean (`true`, `false`,
or `nil` when omitted) controlling approval exemption for workspace reads.
Omitting `[profiles.<id>.tool_policy]` retains the explicit runtime
default; supplying an invalid table produces a deny-all policy.

The removed legacy tool-policy key `sandbox` is accepted but ignored, with one
warning per parsing process. It never changes tool grants, denials, approval
requirements or other restrictions, and is not serialized. Remove it from old
configuration: tool policy does not provide operating-system sandboxing.

`LemonCore.ProfileStore` is the lifecycle owner for user-managed profiles.
Commands such as `lemon profile create research` patch only the selected
`[profiles.<id>]` table, preserving unrelated global-config keys and comments.
Managed records may include `name`, `description`, `avatar`, `model`,
`system_prompt`, `node`, `working_directory` (`"node_default"` or `"profile_files"`),
`status`, `profile_version`, `created_at`, and `updated_at`.
Home/workspace/files paths and the stable `agent:<id>:main` session key
are derived from the validated ID rather than stored; do not add credentials or
filesystem paths to the profile table. See
[User-managed profiles](user-guide/profiles.md) for clone, credential-safe
export, recoverable deletion, and named-node routing.

## Automatic model routing

Automatic per-turn model routing is **opt-in**. It is disabled by default
(`enabled = false`, or the table omitted). Configure it in the global
`~/.lemon/config.toml` or project `.lemon/config.toml`; project tables override
global keys (the `rules` array is replaced as a whole, not merged):

```toml
[model_routing]
enabled = true
max_cost_usd = 0.05        # required when enabled; finite, >= 0

[[model_routing.rules]]    # ordered; first matching rule wins
model = "@smol"            # any model selector, including [model_roles] aliases
contains = "typo"          # optional; case-insensitive substring of latest user text
max_chars = 400            # optional; inclusive, nonnegative integer

[[model_routing.rules]]
model = "anthropic:claude-sonnet-5"
min_chars = 401            # optional; inclusive, nonnegative integer
```

Semantics:

- Rules are evaluated in order against the **latest user text**. A rule matches
  when every matcher it provides (`contains`, `min_chars`, `max_chars`) holds
  (AND); a rule without matchers always matches. The first matching rule picks
  the candidate model; later rules are never consulted as a fallback.
- If no rule matches, the session's default model is used.
- Every selected model, including the default, is checked against
  `max_cost_usd`. The check is a **per-request projection from catalog
  pricing** using a conservative bytes-based estimate of prompt plus tools and the
  maximum output; it is not a cumulative invoice guarantee. Anthropic manual
  thinking can expand the requested output limit, so those requests use the
  catalog maximum instead of the smaller caller limit. A model with unknown
  or all-zero pricing, or without a bounded maximum output, **fails closed** and
  the request is refused rather than silently routed elsewhere.
  Configured model price overrides must explicitly supply `input`, `output`,
  `cache_read`, and `cache_write` rates (including genuinely zero rates);
  omitted rates are unknown, not free. Configured additions whose exact provider
  and model ID are absent from the catalog also require complete explicit pricing;
  prices inherited from another model's template are not accepted.
- An **explicit user-selected model** (for example `/model` or an explicit
  override) always wins: it bypasses automatic routing and this cap.
  Explicit choices survive session resume. Automatic selection stays automatic
  across reset, save, and resume. Tree/entry navigation and committed rewinds
  restore the destination branch's selection provenance: automatic branches keep
  their rules and cap, while explicit branches keep their bypass. Older saved
  model selections without provenance are conservatively treated as explicit;
  start a new session to apply automatic routing to those conversations.
  Inherited/default task, coordinator, background, and side-query models preserve
  that provenance; an explicit child model override still bypasses routing.
  Persona `model`/`role` defaults and `[runtime.task.agent_models]` are automatic
  defaults, not explicit child overrides: task, coordinator and router-backed
  `agent` delegations still apply the rules and cap unless the invocation supplied
  a model or inherited an explicit parent selection.
  Profile `model` defaults (including `profile.chat`, `chat.send` with a profile,
  and model-less managed follow-ups) are automatic as well. An invocation model
  override remains explicit; legacy requests supplying a model without selection
  provenance also retain their explicit-selection behavior.
  Automation reviewer persona/role and configured reviewer/judge defaults retain
  automatic provenance; explicit job model pins and invocation overrides remain
  explicit.
  Entering and leaving plan mode (including resuming a saved plan) also preserves
  the execution model's automatic policy or explicit selection.
- `[budgets]` cumulative caps are separate and still apply.
- Assistant messages record the actual turn's `provider`/`model`. Each completed
  provider-invoked model call also emits a `Model: provider:model` activity entry
  in the TUI/web transcript; the run footer uses the last actual model rather
  than the requested default. Provider fallback candidates are checked against
  the same cap, and a candidate rejected before invocation is not model activity.

Model selectors and rule values are validated when a session starts, not by the
config loader; invalid routing config raises a safe configuration error.

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
attempts and native `task`/swarm descendants. Child usage updates and completion
reports count toward the parent's run and session limits exactly once; an
exhausted parent cannot launch further children. Running children check ancestor
limits before further requests/tools. An already in-flight request can overshoot
a cap, including requests from concurrently running children.

Descendant spend is stored separately for budget enforcement: each session's usage
reports and billing records still contain only its own provider usage. Late async
child usage charges the originating parent session, not a later prompt's run cap.
Compaction and project-memory maintenance model calls are **not counted**.
This is not an account-wide billing limit and does not cover router-delegated
`agent` runs. Models with all-zero or missing catalog pricing emit a budget warning
when a dollar cap is configured; requests remain allowed, so configure model
pricing or token caps to bound unpriced usage. Task scheduler concurrency settings
still apply; there is no hidden three-child or projected $0.10 budget gate.

Tokens use the provider's reported total, or input + output + cache-read +
cache-write when a total is unavailable. Long-lived cache writes are a subset of
cache writes, not an additional token charge. Dollar amounts are catalog-based
**estimates**, not billing invoices. Reported usage from interrupted requests and
retries counts while enforcing a cap; usage the provider never reports cannot be
invented. Legacy sessions derive their starting ledger from all stored assistant
messages, including inactive branches.

Limits are checked before a request and after reported usage, before another
request or tool execution. Before sending, Lemon projects the next request's
input plus maximum output tokens and catalog cost against both run and session
caps. Input uses the latest measured prompt size in the outgoing history, or
roughly one token per four characters of the system prompt, messages and tool
schemas. Output uses the request's `max_tokens`, or the model default. Cached
input is conservatively priced as ordinary input; catalog long-context prices
apply when the estimated input crosses their threshold.

A request is refused when recorded usage plus its projection exceeds a cap;
projections are not charged to the usage ledger. Unknown/zero model pricing
leaves dollar projections unavailable (the existing warning still applies), but
token projections still work. These estimates are stopping policies, not hard
billing guarantees: tokenization, cache writes and concurrent children can still
cause actual usage to exceed a cap. Already-exhausted or zero caps prevent requests.
Tool calls requested by the response that exhausts a cap are recorded as rejected
error results without executing their side effects. Increase the configured cap
if you intentionally want to continue an exhausted session.

## Optional session advisor

The native session API accepts `advisor: [...]`; it is **off by default**.
This is an explicit local session option, not a TOML setting. For example:

```elixir
CodingAgent.start_session(
  cwd: cwd,
  model: primary_model,
  advisor: [
    model: reviewer_model,
    max_notes: 3,
    max_note_chars: 2000,
    max_events: 1000,
    timeout_ms: 30_000,
    agent_options: [stream_options: reviewer_stream_options, get_api_key: reviewer_credentials]
  ]
)
```

The reviewer inherits the primary model unless `model:` is supplied. Supply
provider credentials/options through `agent_options`, using the same trusted
local API as `LemonAgent.Agent`. No paid review runs occur unless enabled.
Each review starts with only the newly subscribed event delta, at a primary
tool-turn boundary. Pending deltas wait for the current review, never for the
primary turn. Subscription overflow, buffer overflow, timeout or reviewer
failure retires the temporary advisor without restarting or failing the primary.

Its tools are the intersection of primary authority and the built-in `read`,
`grep`, `find`, `ls` allowlist; extensions and MCP cannot override those tools.
Inherited denials and approvals remain in force. Tool results are fenced as
untrusted context. The local `advise` tool normalizes whitespace, deduplicates
case-insensitively across updates and caps accepted notes per update.
Oversized/empty notes are suppressed. `critical` notes preempt the primary's
remaining tool queue; `warning` and `info` notes use non-preempting follow-up
delivery. Notes are advisory, not new user authority.

The numbers above are caller-policy defaults, not measured tuning results.
Completed advisor responses charge the primary run's `BudgetTracker`, including
unknown usage; an already-exhausted budget prevents another review. Concurrent
primary/reviewer requests can still finish after a limit is reached. No latency
or quality improvement is claimed; measure before enabling by default.

## Native Execution and Subagents

Lemon uses its native executor for every top-level TUI and gateway run. Configure
its provider, model, and thinking defaults in `[defaults]`; no engine selection
key is supported.

Delegated tasks run as native in-process subagents (child `CodingAgent.Session`
executions) when the agent invokes its `task` tool. There are no vendor CLI task
runners and no `[runtime.cli.*]` configuration.

### Model response timeouts

Model responses allow 300,000 ms of inactivity and a separate 1,800,000 ms hard
ceiling. Every provider event (thinking, text, tool arguments or other activity)
resets inactivity, not the hard ceiling. Idle expiry reports
`:stream_idle_timeout` directly or `:dispatcher_stream_idle_timeout` through the
dispatcher; hard expiry retains `:timeout` / `:dispatcher_stream_timeout`.

Embedding callers configure `stream_idle_timeout` and `stream_timeout` in the
agent's `stream_options` (`LemonAi.Types.StreamOptions` or a model-runtime option
map). Both accept `:infinity`. These are response limits, not a whole-run deadline;
tool execution does not consume a response's idle window. They are not TOML keys.
Dispatcher application defaults (replacing `stream_result_timeout_ms`) are:

```elixir
config :lemon_ai, LemonAi.CallDispatcher,
  stream_idle_timeout: 300_000,
  stream_timeout: 1_800_000
```

Explicit per-call options override these dispatcher defaults. Direct provider
calls use their `StreamOptions` values without consulting dispatcher config.


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
global → project (except `per_call_model*`, which a project can only narrow);
every key is optional:

```toml
[runtime.task]
max_depth = 2              # -1 unlimited; 0 = the main session cannot delegate
max_runtime_ms = 0         # per-child wall-clock limit; 0 disables it
idle_ttl_ms = 300000       # park a completed live child after 5 min; 0 keeps it idle
request_budget = 200       # soft assistant-request budget per run; 0 disables it
request_budget_notice = true # send one non-preempting wrap-up notice at the soft budget
speculative_launch = true  # start read-only tasks[] items while the call is still streaming
worktree_merge = "none"    # default merge for worktree: true tasks: none | patch | branch
disabled_agents = ["sonic"]
per_call_model = "on"      # off (default) | on: may task/agent calls choose a model?
per_call_model_allow = ["anthropic/claude-sonnet-4-5", "@smol"] # optional allowlist

[runtime.task.agent_models]
reviewer = "@slow"         # model or @role per persona ID
```

Task children with an `output_schema` default to `schema_mode = "strict"`.
This adds a `submit_result` tool whose arguments must match the schema; prose,
including JSON in a final response, does not submit a result. Invalid submissions
return validation errors for correction in the same turn; the third invalid
submission ends the turn with an error. If the child finishes without submitting,
it receives up to two reminders to call `submit_result`, then fails with
`Task ended without submit_result`. An accepted value ends the turn and is
returned in `details.structured_output`. Request-budget exhaustion follows the
partial-output decoding behavior below instead of sending further reminders.

Set the task call's `schema_mode = "permissive"` to omit `submit_result` and
validate the child's final JSON text instead, with up to two correction requests.
Successfully decoded values also land in `details.structured_output`.

- `max_depth`: nesting limit. The main session is depth 0 and each child is one
  deeper; a session may delegate only while its depth is below `max_depth`, and
  children created at the cap never receive the `task` tool.
- `max_runtime_ms`: wall-clock limit for each child session; the child fails
  with a timeout error when it is exceeded.
- `request_budget`: completed assistant requests per child run, including schema
  correction requests. At the soft limit, the child receives one concise wrap-up
  notice after its already-issued tool batch, before its next model request
  (unless `request_budget_notice = false`). At `ceil(1.5 × budget)`
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
- `speculative_launch`: start each read-only `tasks[]` item as soon as its
  object has streamed, instead of when the whole call has. Only a read-only
  persona or an effective tool policy limited to `read`/`grep`/`find`/`ls`/
  `agent_message` starts early: items inherit top-level options, and one
  written after `tasks` (`worktree`, `tool_policy`, `cwd`) must never reach a
  child that could already have edited the shared checkout, so write-capable and
  `worktree: true` items launch at dispatch. Dispatch adopts children whose
  parameters match the finished call and cancels every speculative child
  otherwise (also when the call is never executed); cancelled children are
  terminalized without followups and release their budget reservations. Only
  calls that would run without review speculate: an approval requirement for
  `task` (for example `approval_mode = "write"`), extension tool hooks or plan
  mode disable it. `false` launches every item at dispatch.
- `worktree_merge`: what a successful `worktree: true` child does when the call
  omits `merge`: `none` keeps the worktree, `patch` applies the child's changes
  to the parent checkout, `branch` commits them to a kept review branch.
- `disabled_agents`: persona IDs hidden from the tool's agent list and refused
  at launch.
- `agent_models`: per-persona model or `@role` that replaces the persona's own
  `model`/`role`; an approved per-call task `model` still wins.
- `per_call_model`: whether the model may choose a child's model through the
  `model` parameter of `task` (including `tasks[]` items and swarm nodes) and
  `agent`, and a task child's `thinking_level`. The default `off` refuses such a
  call before any child starts; persona `model`/`role`, `agent_models` and
  `model_roles.task` still route children because they are operator and persona
  configuration, not model choices. While `off`, the `task` schema (top level,
  `tasks[]` items and swarm nodes) omits `model` and `thinking_level` and the
  `agent` schema omits `model`; a call that sends them anyway is still refused.
  `on` adds the parameters, and the `model` description lists the allowlist, if
  any.
- `per_call_model_allow`: with `per_call_model = "on"`, the only accepted
  `model` values, each `"provider/model"` or `"@role"`. A `@role` request must
  match an entry literally; any other request matches an entry literally or
  through the `provider/model` it resolves to (`openai:gpt-4o` matches
  `openai/gpt-4o`). Unset accepts any model; `[]` accepts none.
  `on` with no allowlist was not made the default because it lets the model pick
  any configured model, including expensive ones.

These two keys are operator authority. A project `.lemon/config.toml` may lower
`per_call_model` (`on` → `off`) and intersect `per_call_model_allow` with the
global list (a project list alone narrows an unrestricted global `on`), but it
can never turn the gate on or add a model. Invalid values fail configuration
validation.

The same gate applies to child selections that come from the repository rather
than the operator: a project persona's `model`, `role` or thinking level
(`.lemon/agents`, `.omp/agents`, `.claude/agents`), a project
`runtime.task.agent_models` entry, any `@role` that resolves through a project
`model_roles` entry (a literal `@role` allowlist entry does not match it), and a
project `defaults.model` that a child would inherit. With `per_call_model = "off"`, or a
model outside `per_call_model_allow` (a different provider included), the
selection is logged and the child uses the operator's configuration instead:
operator `model_roles.task`, else the parent model, else the operator default.
A project persona's thinking level and a project `defaults.thinking_level` a
child would inherit apply only with `per_call_model = "on"`; otherwise the
operator's level is used (logged). Global and bundled personas and global
`agent_models` are operator settings and are not gated.

Provenance is decided from the global and project layers of the same config
load as the session's settings, never from the files as they are later, and
each session records whether its current model came from the project (a
project role or default, including plan mode's `@plan`) or the operator (an
explicit choice or operator configuration). The record follows every model
change (plan mode, branch navigation, an explicit switch) and is journaled, so
a child inheriting the parent's model is gated whenever that model came from
the project. A `@role` is judged by where it actually resolves: through
operator aliases, project-defined roles, and the fallback of an unconfigured
built-in role (`@default`, `@smol`, `@slow`, `@plan`, `@commit`), which uses
the parent model and its origin, else the default. A bundled persona such as
`sonic` (`@smol`) is therefore gated when `smol` is unconfigured and the parent
runs on a project-origin model, and a literal `@role` allowlist entry only
matches a role that resolves to an operator-origin model.

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
omit `--pair`. Valid node activity extends the seven-day session window;
an inactive worker may still expire. Recovery rotates the session and revokes
older tokens and live sockets while retaining the durable identity.
Concurrent challenge exchange can mint only one
credential, and result settlement is accepted only from the connection and
session generation that received the invocation. Controller renames do not
change the local key. Compatible legacy records
without recovery credentials use the explicit operator-authorized
`--pair --repair --node-id ID` migration path.

`LEMON_NODE_OPERATOR_TOKEN` supplies pairing authority and is used only during
pairing. `LEMON_NODE_TOKEN` supplies an existing session token. Prefer these
environment variables to `--operator-token` / `--token` so credentials do not
enter shell history. These values are runtime CLI inputs, not `config.toml`
keys. The `lemon` launchers (source and release) remove both variables at
startup and hand them to `lemon node` only on an anonymous pipe (fd 3) that
the VM drains before any application starts; nothing is written to disk, and
an unreadable handoff refuses to start. They never appear in the VM's initial
environment (`/proc/<pid>/environ`, `ps -E`) or in any child process.
Node child processes (bash, PTY, process, eval, debug, language servers,
host commands, task-worktree Git and stdio MCP servers) never inherit Lemon
secrets: every `LEMON_*` variable with a `_`-separated word `TOKEN`, `SECRET`,
`SECRETS`, `KEY`, `COOKIE`, `PASSWORD`, `PASSPHRASE`, `PASS`, `AUTH`,
`CREDENTIAL` or `CREDENTIALS` (node, operator, WebSocket and bot tokens,
secret-store master keys, web signing keys, `LEMON_*_API_KEY`), any
`LEMON_NODE_*TOKEN*` variable, and the `RELEASE_COOKIE` distribution cookie.
Ordinary provider keys such as `OPENAI_API_KEY` are still inherited.

The credential store directory `~/.lemon/nodes/execution/` (under the Lemon
home, `$HOME/.lemon`) is mode 0700 with mode-0600 files. Model-directed tools
treat it, and every other Lemon credential file, as off limits:

- `nodes/execution/` (node session and recovery tokens);
- the secrets master key (`secrets_master_key`, or the configured `key_file`);
- the encrypted secrets store: `store/` and the configured store database with
  its `-wal`, `-shm` and `-journal` files;
- `cookie` (Erlang distribution cookie) and `web_secret_key_base`;
- `env` and the runtime `.env` (`LEMON_DOTENV_DIR/.env` when set);
- control-plane operator tokens: `run/*.token` and the launcher's
  `run/.control-plane-*` temporaries (logs and pid files in `run/` stay
  readable);
- the bot backend's `master.key`, `local-access.key` and its
  `.local-access.key.*` temporaries, in `lemon_bot/` and in
  `$LEMON_BOT_DATA_DIR`.

Lemon keeps no MCP OAuth token cache on disk. `LemonCore.CredentialPaths` is
the single check every model-reachable reader consults before it opens a file:
file tools (`read`, including JSON, SQLite and archive selectors, `write`,
`edit`, `patch`, `ls`, `grep`, `find`, `ast_grep`), `semantic_find`, LSP
document synchronization and location excerpts, media analysis and
transcription inputs, and browser `file:` navigation, content reads, captures
and uploads (`allowLocalDocument` does not override it, including for tabs that
already show such a document). Paths are compared after resolving symlinks and
`..` the way the kernel does, also catching case-folded spellings and hard
links; searches over a parent directory skip them. Creating, renaming or
deleting a directory that contains a credential path is refused, and
filesystem checkpoints never copy a credential file. `bash` (command text,
`cwd` and `env`) and `eval` (cell code) refuse text that names them; that check
is best effort, because a shell can build the path at run time.

None of this is an OS boundary. Node tools run as the same OS user as the
node, so code they run (bash, eval, process, PTY) can still read anything that
user can: the stored session and recovery tokens and the other files above,
the node VM's initial environment (`/proc/<pid>/environ`, `ps -E`), and, where
the OS allows same-user debugging, the memory of the node process. Running the
node under a dedicated account does not change this, because its tools still
share that account; Lemon does not run tools as a separate user. When a node's
credentials must stay out of reach of its tools:

- withhold code execution with `LEMON_NODE_CAPABILITIES`, for example
  `read,write,edit,ls,grep,find`, so the only tools that reach the node are the
  ones that enforce the credential deny-list;
- run the node under a dedicated OS account that holds nothing else of value;
- if a node may have been compromised, re-pair it with `--pair` (which rotates
  the session and revokes older tokens and live sockets) or remove it on the
  controller.

Design notes for a separate tool user (not implemented). Prefixing tool
commands with `sudo -u TOOLUSER` is not enough: the node user cannot signal
processes owned by another user, so process-group teardown, timeouts and
liveness checks fail with `EPERM`, and a `SIGKILL` to `sudo` orphans the
command. A correct design needs a runner process that runs as the tool user
(started by root or the service manager, not setuid) and listens on a Unix
socket only the node user can reach. The node sends it spawn requests (argv,
cwd, scrubbed env, stdio passed as file descriptors) and it owns the resulting
process groups: it delivers signals, enforces deadlines and reports exit and
group status. `LemonCore.NativeProcess` and `LemonCore.ProcessGroup` route
every tool launch and teardown through it. The credential files stay owned by
the node user (mode 0700/0600) and the workspace is shared through a group, so
tools keep their files and lose the credentials.

`LEMON_NODE_CAPABILITIES` (or `--capabilities`) sets the destination-local tool
ceiling to `all` or a comma-separated list such as `read,write,bash`. Every
remote execution context is intersected with this ceiling before the local
executor starts.

Non-loopback controllers require `wss://` by default. Plaintext `ws://` needs
`--allow-insecure-controller` or
`LEMON_NODE_ALLOW_INSECURE_CONTROLLER=true`, and that override is acceptable
only for development or a verified authenticated and encrypted overlay such as
Tailscale. Plaintext `ws://` without the override is accepted only for a
literal loopback IP or bare `localhost`, which is pinned to `127.0.0.1` rather
than resolved; `*.localhost` names are refused. A `wss://` controller must
present a certificate that chains to the OS trust store and matches the URL
host; there is no option to skip certificate verification. Install a private
CA in the system trust store, then restart Lemon: OTP caches the CA roots on
first use, so a running BEAM does not see trust-store changes.

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

Lemon imports MCP definitions from supported coding-tool configs; Lemon's own
`.lemon/mcp.json` entries take precedence. Project files, the project
`.lemon/mcp.json` included, start nothing until the operator trusts that
project's exact files with `lemon mcp trust`; the digest-bound trust record
lives in `<agent_dir>/mcp_project_trust.json`, never in the project, and every
spawn or reconnect re-checks it. Other tools' user-global configs require
`LEMON_MCP_EXTERNAL_USER_DISCOVERY=1` (the omp user config is read by default,
and `CLAUDE_CONFIG_DIR` opts in Claude user files). Disabled entries still
claim their names; importing configuration does not launch an MCP server. See
[MCP management](skills.md#manage-named-mcp-servers) and
[project trust](skills.md#project-trust).

Only user-level files read host values. Project files never substitute
`${VAR}`, `{env:}` or `{file:}`, or use Codex `env_vars`, `env_http_headers` or
`bearer_token_env_var`, and a project `.lemon/mcp.json` never names OAuth
`client_secret_secret` or `token_secret`; such project servers are rejected
with a `host_value_reference` finding.

OpenCode `opencode.json` and `opencode.jsonc` files accept comments and trailing
commas. In user-level OpenCode files, after JSONC decoding, Lemon substitutes
`{env:NAME}` and `{file:path}` once within string **values**, including command
arguments, environment values, URLs and headers; object keys are not
interpolated. Environment values retain their exact bytes, including quotes,
backslashes, newlines and leading/trailing whitespace. An unset environment
variable substitutes an empty string.

File placeholders resolve relative to the containing config file, accept
absolute paths, and resolve `~/` against the discovery home. File contents are
trimmed of leading/trailing whitespace; a missing or unreadable file
substitutes an empty string. Neither inserted environment values nor inserted
file contents are interpreted again as JSON, interpolation directives or file
imports.

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
  compatibility opt-in (`true`/`false` or `1`/`0`) for tokenless operator,
  OpenAI/ACP HTTP and A2A access from direct loopback peers. Defaults to `false`; never enable it
  for a reverse-proxied control plane.

The browser monitoring client intentionally has no build-time or URL-based
operator-token setting. Lemon does not yet implement the short-lived delegated
browser-session exchange needed to authenticate that client safely. Never
place the shared server token in `VITE_*` configuration.
- `LEMON_PROVIDER_ROUTING_ENABLED`, `LEMON_PROVIDER_FALLBACK_PROVIDERS`, `LEMON_PROVIDER_ROUTING_REQUIRE_CREDENTIALS`
- `LEMON_TUI_THEME`, `LEMON_TUI_DEBUG` — TUI appearance and debug mode
- `LEMON_TUI_NOTIFICATIONS=auto|osc|bell|off` — overrides the Bun TUI's global `[tui] notifications`; legacy `0` means `off`, `1` means `auto`
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
no direct-execution fallback, including internal callers passing
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
concurrency cap. `:coding_agent, :task_max_concurrency` (default `8`) caps
concurrently running native task lineages: a child's descendants (synchronous
launches and joins included) reuse its slot instead of deadlocking the pool.
`/bg` background sessions use their own pool,
`:coding_agent, :background_run_max_concurrency` (default `8`), so idle
background sessions never block a task. A join without an explicit timeout
yields (children keep running) after `:coding_agent, :task_join_timeout_ms`
(default 30 minutes). The unused main/subagent lanes no longer exist.
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
with that history. Local workload liveness is reconciled on the root Port's
exit-status event, explicit cancellation and boot recovery, not a periodic
system-wide `ps` timer. Retained unknown workloads remain charged until verified
termination. These are local containment contracts, not proof of remote workload
termination.

The internal evaluation harness can additionally opt into
`LemonCore.NativeProcess` tracking by calling `configure!/1` with a fresh private
ledger path before application boot. This is independent of managed-process
admission and is not a user TOML setting. With no ledger configured, native
launches keep their existing behavior. Tracked Bash and external-secret launches
sync an intent before opening a stdin-gated local wrapper, then sync its
birth-bound group witness before releasing execution. Configuration durably
establishes the ledger file and newly created directory entries; acknowledged
records use stable-storage barriers, including `F_FULLFSYNC` on Darwin.
Existing ledger paths are refused without DETS repair. A missing ledger service,
failed persistence or unavailable witness refuses release rather than falling
back to an untracked launch. Ledger snapshots retain uncertain or unsupported
workloads as occupied; an empty group is termination evidence only for a valid,
unlost witness. PTY helpers can create separate sessions, so their wrapper group
alone is not a whole-workload termination proof. Shared
`LemonCore.ProcessGroup` signalling uses an absolute OS executable and fixed argv,
never a PATH-selected binary or shell command.


The Bun TUI uses the runtime's model and thinking defaults from `[defaults]`.
The `[tui]` section controls terminal presentation settings loaded at startup.
The Bun client reads global `~/.lemon/config.toml` with project
`.lemon/config.toml` overrides at startup. `LEMON_TUI_NOTIFICATIONS` takes
precedence over `notifications`. `auto` (default) uses OSC 9/777 on recognized terminals and BEL
(`\x07`) elsewhere. `osc` forces OSC without a bell fallback, `bell` uses BEL
only, and `off` disables both. Pending `ask` questions, approvals, and run
completion share this mode and use fixed notification text, never question or
conversation content. Tern's program-status inbox/banners remain controlled by
Tern's settings; `bell` explicitly rings there too. Non-TTY, `TERM=dumb`, or
`LEMON_TUI_TERMINAL_INTEGRATION=0` suppresses these side channels entirely.
See `clients/tui/README.md` for copy commands and keyboard access.

`theme` is owned by the terminal client: `/theme dark|light|auto` writes it,
and the client also reads `system` (same as `auto`) and the palette names
`lemon-dark`/`lemon-light`. Core config validation only requires a non-blank
string, so any value the client writes loads.

### TUI keybindings

Use `[tui.keys]` to replace any action's default keys. Quote action IDs (otherwise
TOML interprets dots as nested tables). Project bindings override global bindings
per action, not the entire key table.

```toml
[tui.keys]
"lemon.palette.open" = "alt+p"
"lemon.plan.toggle" = ["alt+shift+p", "ctrl+shift+p"]
"lemon.model.cycle" = "alt+v"
"lemon.picker.thinking" = [] # unbind; "none" also works
```

Each value is one key string or an array. `[]` and `"none"` unbind the action.
Chords use `ctrl`, `shift`, `alt`, or `super`, followed by `+` and a pi-tui key:
a letter, digit, punctuation symbol, or named key such as `enter`, `escape`,
`tab`, `space`, `backspace`, `delete`, `insert`, `home`, `end`, `pageUp`,
`pageDown`, arrows, or `f1`–`f12`. Key names are case-insensitive. Modified keys
depend on your terminal's keyboard protocol; some terminals cannot distinguish
every chord.

The [key reference](user-guide/tui-commands.md#configurable-keybindings) lists every
bindable action ID and its defaults, including pi-tui editor and selector actions.
Lemon's local composer policies (abort/quit, history recall, attachments and
submission-mode cycling) and picker-local shortcuts remain separate.
`lemon.plan.toggle` runs the same toggle as `/plan`; `lemon.model.cycle` uses the
model picker's cached `models.list` order, wraps at the end, and changes only the
current session (not the global default). Both start **unbound**.

Unknown actions, invalid values, and conflicts are ignored and combined into one
startup notice; rejected actions retain their defaults. Conflicts include a
user binding that collides with another action's unchanged default, so unbind or
remap the original owner in the same table before reusing its key. Existing
context-specific default overlaps are retained. Without `[tui.keys]`, all
existing defaults stay unchanged. These client-owned settings are accepted by
`lemon config validate`; action/key validation happens in the TUI at startup.

### TUI prompt history

The Bun TUI remembers submitted prompts across sessions for ↑ / ↓ recall.
Persistence is **on by default**. Only submission writes prompt records: typing,
recalling and discarding drafts do not persist them. Discarded drafts remain
recallable in the current session's in-memory ring.

History is a local SQLite database at
`~/.lemon/tui-history/history.sqlite3` (`$HOME/.lemon`). It uses Bun's built-in
SQLite, not a daemon, external database service or third-party storage package.
The history directory must be owned by the current user and mode `0700`; database
and any SQLite sidecars are mode `0600`, even with a permissive umask. Existing
loose file modes are tightened. Symlinked or hardlinked history files, symlinked
user-directory components, foreign-owned files and insecure directories are
rejected rather than followed. An existing `.lemon` directory may be `0755`, but
must not be writable by other users.

Each append, oldest-first prune and clear is a short SQLite `BEGIN IMMEDIATE`
transaction. Records are ordered by the database's transaction serialization,
not file names or modification times. Concurrent TUIs cannot overwrite one
another from stale recall snapshots. An adjacent repeat is suppressed against
the last committed prompt. SQLite's busy timeout is 1.5 seconds per lock wait:
contention fails with an actionable notice rather than polling indefinitely.
Storage errors leave this session's in-memory recall usable.

The retained-history bounds remain **100 prompts and 256 KiB** (UTF-8 bytes of
the JSON-encoded prompts including one newline each), dropping the oldest first.
A prompt larger than 256 KiB is session-only. These are **logical content limits,
not a byte-exact filesystem quota**. SQLite has page, index and schema overhead.
The database uses full auto-vacuum to return freed pages at commit, a page-count
allocation ceiling with room for overhead and an in-flight append, and DELETE
rollback journaling with a zero retained-journal limit. Connections close after
each operation; normal operation creates no growing WAL/SHM files. Temporary
rollback journals also consume disk space during transactions. This policy bounds
growth without claiming an unproven hard cap on database plus sidecar bytes.
SQLite FULL synchronous commits and rollback-journal recovery protect committed
records after a process crash.

On first use, the TUI imports bounded tails of legacy
`~/.lemon/tui-history.jsonl`, its numbered backups and timestamp/pid/random suffix
files. Older files are imported in a deterministic order, current JSONL last;
the original cross-file transaction order cannot be reconstructed. Invalid
lines are skipped and the same retention bounds apply. The import and a
one-time migration marker commit together before the sources are removed.
A crash during cleanup cannot import them twice. Close older TUI versions
before upgrading: they do not participate in SQLite transactions.

Prompts may contain secrets. The database stays on your machine; the daemon
never reads it and doctor support bundles do not include it. `lemon backup`
copies durable `~/.lemon` state, so clear history first if you do not want prompts
in a backup. Clearing is not cryptographic erasure of old backups, filesystem
snapshots or previously deleted blocks.

- `/clear-history` empties this TUI's recall rings and transactionally deletes
  saved rows, sets the migration fence and removes retained legacy sources,
  even with persistence disabled. The SQLite database stays in place so open
  writers cannot split onto an unlinked database. A concurrent append committed
  before clear is removed; one serialized after clear may survive. No stale
  client snapshot or delayed legacy cleanup can resurrect cleared records.
  Other TUIs' in-memory recall rings are not erased. Permission, lock and cleanup
  failures report an error, never a successful clear; a failed legacy cleanup
  may leave source files on disk, but the committed migration fence prevents
  reimport. Retry `/clear-history` after fixing the reported problem.
- Each row stores `created_at` (Unix seconds) and the submitting working directory
  (`cwd`, at most 1024 characters) next to the prompt for the Ctrl+R search
  overlay. Databases from earlier versions gain both columns in place, inside the
  same exclusive transaction as any other operation; existing prompts take the
  migration time and no `cwd`. `/clear-history` deletes them with the prompt.
- `[tui] prompt_history = false` (global or project config) turns persistence off:
  load and append do no history I/O, and recall lasts for the current session
  only. Any other non-`true` value also turns it off. Existing history remains
  until `/clear-history`. If config cannot be loaded (for example a project
  config syntax error), the TUI warns and keeps persistence off for that run.

```toml
[tui]
prompt_history = false
```


Async followup queue defaults for background `task` completions and delegated `agent`
completions are currently umbrella app config, not TOML. The default lives in
`config/config.exs` as `config :coding_agent, :async_followups, default_queue_mode: :followup`.
Per-call tool inputs still override it: `task.queue_mode` and `agent.followup_queue_mode`.
For async completions, `followup`, `steer`, and `steer_backlog` all deliver
non-preempting input: a live parent's already-issued tool batch finishes, then
the completion arrives before its next model request (not only when the whole
run ends). An unavailable parent falls back to a router `followup`.
`collect` retains router backlog delivery; explicit `interrupt` retains router
interruption. Human steering still skips calls that have not started.

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
`skill_manage` with `scope = "global"` always needs approval regardless (global
skills are Lemon operator state), and is refused without an interactive approver.
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

### Private git hosts for skill installs

Remote skill repositories must resolve to public addresses. An operator can name
internal git servers that may resolve to private addresses:

```toml
[skills]
allowed_private_git_hosts = ["gitea.internal"] # exact host names, case-insensitive
```

This is operator-only: it is read from the global `~/.lemon/config.toml`, and a
project `.lemon/config.toml` that sets it is ignored with an operator-only warning.
Listed hosts are still pinned to the address Lemon resolved, cloud metadata
addresses stay refused, and every other host keeps the public-only rule. Skill git
commands never use a proxy (`http_proxy`, `https_proxy`, `all_proxy` and
`http.proxy` are cleared so the pinned connection cannot be redirected), so a
repository reachable only through a proxy cannot be installed; mirror it on a
directly reachable host instead.

## Feature Flags

Feature flags gate in-progress behaviour changes so they can be shipped incrementally
without ad-hoc environment variables.

```toml
[features]
session_search               = "default-on" # durable memory ingest and search (default)
routing_feedback             = "default-on" # task fingerprinting + routing feedback (default)
skill_synthesis_drafts       = "default-on" # skill synthesis draft pipeline (default)
crash_resume                = "off"        # hard-crash continuation is explicitly opt-in
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

### Hard-crash recovery

`features.crash_resume` defaults to `"off"`. To opt in, set it to `"on"` (or
`"default-on"`), or set `LEMON_FEATURE_CRASH_RESUME=on`, before starting Lemon.
This controls both orphaned router runs and their interrupted native task children;
`"opt-in"` alone does not enable automatic boot recovery.

At boot Lemon reconciles durable admissions without a terminal result. With the
flag off, dispatched runs finish as interrupted with an unknown outcome, not as
successful or definitely unstarted. A claim that never crossed dispatch is marked
not started and is never automatically executed. With the flag on, resumable local
runs receive a continuation turn
under the **original run ID**. Their original request and native journal are
retained privately before execution. The notice lists unresolved tool intent IDs
and tool names (at most 100), and instructs the model to inspect state and ask before
repeating any state-changing action: an unknown tool result is never permission to
retry that tool. No original tool arguments appear in the notice.

Children that were running are continued once per resumed parent attempt, under
their original task IDs, before the parent's continuation prompt. Parent awaits
therefore keep working. Children whose parent is not resumed are not re-driven.
Real terminal task results remain first-writer-wins.
Worktree children reuse their existing checkout; recovery never recreates it or
automatically replays worktree preparation, merging or cleanup. Results explicitly
report that merge effects were not replayed. For an interrupted swarm coordinator,
only its already-running native descendants can continue: recovery does not rerun
the scheduler or launch previously pending nodes.

The existing carryover policy allows at most **three recovery attempts**, durably
counted before dispatch, even across repeated crashes. Explicit abort fences are
permanent and always prevent recovery. A run seen in both graceful carryover and
the crash scan is dispatched only once. Unportable requests, invocation-bound
capabilities and named-node executions are not automatically re-issued; they
converge to interrupted/unknown instead. Graceful restart carryover still works
independently of this flag. A recovery or replay call that times out is an
unknown outcome for that run ID alone: it stays pending for the next boot while
the remaining runs and carried items are still recovered.

From a local operator console,
`LemonRouter.RestartCarryover.CrashRecovery.operator_view(limit: 20)` returns recent
resumed/abandoned run IDs, attempt counts, bounded reason classifications and
timestamps. Results are capped at 100 and contain no prompts, paths, credentials,
tool arguments or raw errors. Store failures remain explicit errors.

## Canonical Sections

Use only these top-level sections:

- `defaults`
- `runtime`
- `model_routing`
- `budgets`
- `features`
- `secrets.sources.<source_id>`
- `profiles.<agent_id>`
- `providers.<name>`
- `gateway`
- `tui`
- `logging`
- `automation`
- `cron` (failure-alert cooldown only; see [Cron failure alerts](#cron-failure-alerts))
- `memory` and `skills` (see [Memory](#memory))

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

A running Lemon keeps serving its last good configuration when an edit makes
the file invalid: the failure is logged once (`Config reload failed …; serving
the last good config`) and no further load is attempted until the file changes
again, so fixing the file is picked up on the next check. Only a start with no
previously loaded config fails. Invalid values are reported, never replaced by
a default: a misspelled `[features]` state, a `[runtime] max_tool_turns` that is
not a non-negative integer (`0` or unset means unlimited) and a profile
`tool_policy`/`tool_policy_json` that does not parse are validation errors.

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

Source launchers (`./bin/lemon`, `./bin/lemon-gateway`, `./bin/lemon-control-plane`)
load one `.env` file at startup, and the config reloader re-reads it when it
changes:

- `$LEMON_DOTENV_DIR/.env` when `LEMON_DOTENV_DIR` is set in the launching
  environment (or `--dotenv-dir` for `lemon-control-plane`);
- otherwise `~/.lemon/.env`.

Environment variables override every config file, so this file is operator
authority. Lemon never reads `.env` from the launch or working directory: a
cloned repository's `.env` could otherwise redirect credentials or enable
executables. **Upgrade note:** if you relied on `<launch dir>/.env`, move it to
`~/.lemon/.env` or start Lemon with `LEMON_DOTENV_DIR=<dir>`.

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

## OpenAI Responses WebSocket (opt-in)

Native live coding sessions can reuse an OpenAI Responses WebSocket across turns.
Enable it separately for each provider in `~/.lemon/config.toml` (provider
settings are operator-only; a project file cannot set them):

```toml
[providers.openai.provider_options]
responses_websocket = true

[providers.openai-codex.provider_options]
responses_websocket = true
```

This applies only to the `openai_responses` and `openai_codex_responses` wire
APIs, including custom providers using `api = "openai_responses"`. Azure Responses,
Chat Completions and other APIs keep their existing transport. Omit the setting
or set it to `false` to keep the default SSE path.

The live session owns the transport; subsequent turns reuse it and may send only
new input with `previous_response_id`. Model switches and compaction close the
connection and discard the continuation baseline. Credential/header changes
invalidate it on the next request. The transport dies with its session; its pid
and continuation state are never written to session history or restored after
parking/restart. Summary/classifier calls do not borrow the conversation's
transport.

Contexts use chronological message order (oldest first), including histories
built with `LemonAi.Types.Context.add_*`. Reordering prior input or assistant
output invalidates the continuation prefix and correctly forces a full replay.

An invalid continuation anchor triggers a full replay. Three anchor rejections
disable chaining for that logical session, including across compaction resets.
This feature is experimental and off by default; no token or latency improvement
is claimed without a measured workload.

### Bounded live comparison (2026-11-16)

At source revision `abc566dcdb83f35d311fb9c2c66b889e3b6fcc9d`, ten paired
turns used the production `LemonAi.stream/3` API with
`openai-codex:gpt-6.1-sol`, low reasoning, a synthetic growing conversation,
and one session-owned WebSocket transport. SSE was the current-revision
`responses_websocket: false` control; arm order alternated each turn. This
was not a pre-epic comparison or an arena run: `4d94b3c8e` has no session-owned
WebSocket transport or this measurement helper, so the current disabled-feature
arm is the control rather than an old-revision harness.

| Measurement | SSE, n=10 | WebSocket enabled, n=10 |
| --- | ---: | ---: |
| First-content median / nearest-rank p90 (ms) | 1,857.10 / 2,345.51 | 2,047.72 / 2,383.22 |
| Terminal median / nearest-rank p90 (ms) | 1,914.61 / 2,417.77 | 2,160.04 / 2,458.52 |
| Uncached input tokens, sum | 11,050 | 10,026 |
| Cache-read tokens, sum | 0 | 1,024 |
| Total input including cache, sum | 11,050 | 11,050 |
| Output tokens, sum | 50 | 50 |
| Successful requests | 10 | 10 |

The median within-pair WebSocket-minus-SSE difference was **+79.75 ms** to first
content and **+85.48 ms** to terminal completion. Total reported input did not
decrease. One WebSocket response reported a cache hit; the arms shared a
prompt-cache key and caching was not disabled, so the uncached-input difference
is not evidence that continuation reduced model input or billing. The transport
retained an anchor after every completed turn and recorded zero anchor rejection
strikes. Small samples and provider/network variability do not establish a tail
latency improvement or a general regression.

A separate two-turn wire diagnostic (two additional requests per arm, excluded
from the table) reduced transport send traces to numerical metadata in memory.
Neither WebSocket frame contained `previous_response_id`: input item counts
were **1 then 3**, and encoded input sizes were **4,048 then 4,303 bytes**.
Therefore this live workload exercised WebSocket **full replay**, not successful
continuation; it does not establish a chaining benefit. Anchor presence alone
was insufficient. The live chaining measurement remains unmet for this workload;
the source behavior was not changed to force a result.

The exact measurement invocation was:

```sh
ERL_FLAGS='+S 2:2' mix run --no-compile --no-deps-check --no-start .transport_measure.exs websocket
ERL_FLAGS='+S 2:2' mix run --no-compile --no-deps-check --no-start .transport_measure.exs websocket-wire
```

The temporary helper was removed after publishing aggregate numerical results.
It resolved a host-configured Codex credential in memory through `omp token`,
disabled provider retries, consumed production `EventStream` events, and timed
from immediately before `LemonAi.stream/3` to first content and terminal
consumption. Credential resolution and VM/application startup were outside the
timed interval; no prompts, responses, credentials or raw traces were published.
Environment: MacBook Pro Mac15,9, Apple M3 Max, 128 GB, macOS 15.6, OTP 29
(ERTS 17.1.1), Elixir 1.20.5, two BEAM schedulers. The existing prepared dev
build was used without recompilation; its build provenance was not independently
attested. The sequential local session-memory probe ran concurrently; Docker
image builds had not started. Other host load was uncontrolled. See
[#566](https://github.com/z80dev/lemon/issues/566) for the published run report.

A bounded follow-up on 2026-11-16 used two `openai-codex:gpt-6.1-sol`
requests through a real `CodingAgent.Session` with low reasoning and provider
retries disabled. Both requests succeeded on the same connection with zero
anchor rejections. Turn 2 carried the preceding completed response ID and only
one new user input item instead of the three-item replay; encoded input was
1,619 then 1,621 bytes. The earlier non-chaining diagnostic used context helpers
that prepended history, unlike the provider/session chronological contract.
The helpers now append chronologically. Five live requests total were used for
diagnosis and this verification; this is not a latency or token-savings benchmark.

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

To configure these interactively, run `lemon setup provider --set-default` and
choose a **local server**, or pass `--provider ollama` (aliases such as
`--provider lm-studio` also work). Setup offers an optional API key, stores any
key in encrypted secrets, and writes `auth = "none"` when it is left blank.
Model discovery requests `GET {base_url}/models` only after explicit consent;
declining, an empty list, or a connection failure allows manual model entry.
`--model MODEL` and non-interactive local setup never discover models.
Existing configured base URLs are retained; otherwise setup uses the preset's
base-URL environment variables or default.

The **Custom OpenAI-compatible endpoint** menu entry prompts for a new provider
name, API base URL, and optional key. It writes `api = "openai_completions"` and
either `auth = "none"` or an encrypted `api_key_secret` reference. No automatic
runtime discovery setting is added. See the [setup guide](user-guide/setup.md#local-servers-and-custom-endpoints)
for commands and the separate live-verification behavior.

Readiness, `lemon doctor`, and offline setup verification accept these local
presets without an API key. Custom keyless endpoints must explicitly set
`auth = "none"`; a localhost URL alone does not waive a hosted provider's
credential requirement.

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

## omp auth broker and auth gateway

[omp](user-guide/omp.md) can centralize provider credentials in an auth broker
(`omp auth-broker serve`) and expose them through a credential-holding proxy
(`omp auth-gateway serve`). Lemon integrates with both; pick per provider.

| | Broker: `auth_source = "omp_broker"` | Gateway: `omp_gateway` provider |
| --- | --- | --- |
| Lemon holds | the broker bearer; reads access tokens and API keys | only the gateway bearer |
| Requests go | straight to the provider through Lemon's own provider modules | to the gateway, which calls the provider |
| Models | Lemon's catalog for that provider | everything the gateway serves (`GET /v1/models`) |
| Refresh | performed by the broker | performed by the broker, behind the gateway |

`lemon setup omp` does the broker setup below for you: it starts the broker as
the `omp-broker` service when needed, writes `auth_source = "omp_broker"` for
the providers you pick and verifies them (see
[Use omp's logins](user-guide/setup.md#use-the-providers-youre-signed-in-to-in-omp)).

### Broker-backed credentials

Set `auth_source = "omp_broker"` on any provider, built-in or custom:

```toml
[providers.anthropic]
auth_source = "omp_broker"

[providers.openai-codex]
auth_source = "omp_broker"
omp_account = "email:me@example.com|org:org-123"  # optional OAuth identityKey

[providers.team-router]        # custom endpoint using omp's OpenRouter key
api = "openai_completions"
base_url = "https://openrouter.ai/api/v1"
auth_source = "omp_broker"
omp_provider = "openrouter"
```

The broker endpoint is resolved like omp's own client (Lemon does not read
omp's `config.yml`):

- URL: `OMP_AUTH_BROKER_URL` (environment, else a Lemon secret of that name),
  default `http://127.0.0.1:8765`.
- Token: `OMP_AUTH_BROKER_TOKEN` (environment, else a Lemon secret), else omp's
  `auth-broker.token` under `~/<PI_CONFIG_DIR or .omp>` (or
  `profiles/<OMP_PROFILE>`), as written by `omp auth-broker token` / `serve`.

`omp_provider` defaults to the Lemon provider id with dashes (`openai_codex` →
`openai-codex`, `google_gemini_cli` → `google-gemini-cli`), except
`kimi_coding` → `kimi-code`, `kimi` → `moonshot` and `opencode` →
`opencode-zen`; custom providers must set it. Lemon lists every broker account
for the provider in omp's order: OAuth sign-ins win over login API keys over
other API keys, accounts without an active rate-limit block first. With
`omp_account` only that identity is used and API keys never are; `omp usage
accounts` lists identity keys.

The selection is authoritative: environment keys, inline keys and Lemon
secrets do not replace it, and a broker failure resolves no credential instead
of falling back. Lemon never receives or stores refresh tokens. After the first
fetch it keeps the broker snapshot per endpoint current with a long-poll
(`GET /v1/snapshot?wait=…` with `If-None-Match`), so rotations, revocations and
blocks apply immediately. If the long-poll fails it falls back to a 15 second
cache (5 seconds after a failed fetch), and an endpoint unused for about 10
minutes stops being polled. Lemon asks the broker to refresh an access token
within a minute of expiry, and after a provider rejects a token re-reads the
broker, then requests `POST /v1/credential/:id/refresh?reason=auth-recovery`.
If the broker hands back the rejected token again the refresh fails rather than
retrying it. Gemini
CLI and Antigravity receive `{"token","projectId"}`; GitHub Copilot sign-ins
are not supported through the broker. `lemon doctor`, setup readiness and
provider status check the broker credential without a local secret store; as
with a Lemon Claude login, a Claude subscription token has no non-generating
live check.

When a provider rate-limits a broker credential (429 or quota exhaustion),
Lemon posts a catch-all rate-limit block for it to the broker
(`POST /v1/credential/:id/block`, scope `""`, until Lemon's cooldown or the
provider's retry-after), so omp and other broker clients avoid that account
too, and retries the same turn on the next broker account before falling back
to another provider. Block reporting is asynchronous and best-effort. For
`openai-codex` the catch-all block covers both the chat and spark meters. This
is the only write Lemon makes to the broker; it never writes credentials.

The broker bearer can read every credential the broker holds. Keep the broker
on loopback or an encrypted overlay (Tailscale, WireGuard) and use `https://`
across untrusted networks.

### The `omp_gateway` provider

`omp_gateway` (aliases `omp-gateway`, `omp-auth-gateway`) sends requests to an
omp auth gateway, which resolves the provider credential itself. Lemon only
holds the gateway bearer:

```toml
[providers.omp_gateway]
base_url = "http://gateway.tailnet:4000/v1"  # default http://127.0.0.1:4000/v1

[defaults]
provider = "omp_gateway"
model = "omp_gateway:anthropic/claude-sonnet-4-5"
```

The bearer resolves from `OMP_AUTH_GATEWAY_TOKEN`, `api_key`,
`api_key_secret`, the secret `llm_omp_gateway_api_key`, then omp's
`auth-gateway.token`. A client token from the gateway's `--clients` file works
the same way and limits Lemon to that client's models and accounts. For a
`--no-auth` gateway set any placeholder `api_key`. `OMP_AUTH_GATEWAY_URL` sets
the base URL when the config does not.

Model ids are the gateway's `provider/id` pairs. Each model uses the wire
closest to its native API so provider features survive translation: Anthropic
Messages models use `/v1/messages`, OpenAI/Codex/Azure Responses models use
`/v1/responses`, everything else uses `/v1/chat/completions`. Reasoning
support, pricing and limits come from Lemon's catalog entry for the same
provider and id when one exists; the gateway listing supplies names, limits and
input modalities. The `/model` picker lists every chat model the gateway
serves once a bearer resolves; judge, image, speech, embedding, rerank and
video models are skipped. Requests carry `x-omp-app: lemon` and
`x-omp-hostname` for the gateway's usage attribution.

`omp auth-gateway stdio` is not used: it returns a streamed response only after
the stream ends, which would defeat incremental output.

## Custom Providers and Models

A `[providers.<id>]` table whose id is not a built-in provider defines a custom
endpoint (the equivalent of omp's `models.yml` providers). Its models are
selected as `<id>:<model>` or `<id>/<model>` in `default_model`, `/model`,
`model_roles`, task/compaction selectors and `provider_routing.fallback_providers`,
and they appear in the TUI `/model` picker once the provider has a credential.

Qualified `[defaults] model` selectors resolve their provider before default
provider routing when the provider was inherited from a lower-priority config
file, an environment model-only override, or the built-in fallback. For example,
a project model of `anthropic:claude-sonnet-5` overrides an inherited Ollama
provider. A provider explicitly set in the same or a higher-priority source
instead keeps the model ID native: `provider = "ollama"` with `model = "qwen:7b"`
or even `model = "anthropic:claude-sonnet-5"` selects that exact Ollama model ID,
regardless of discovery cache contents. Unknown prefixes remain native IDs.

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

The focused `lemon model` command onboards one provider. Sign-ins that store
credentials require a usable encrypted secrets store; use `lemon setup` when a
fresh machine still needs config/secrets bootstrap and readiness verification.

Provider onboarding flows:
- Let you choose a provider when none is passed
- Use an interactive arrow-key TUI for provider/auth/model selection when a TTY is available
- Run provider OAuth flow by default when supported, or prompt for an API key/token otherwise
- Capture localhost OAuth callbacks automatically when the provider redirect URI is local
- Store credentials in encrypted secrets with provider metadata, except externally managed `--auth omp`
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

When an untried healthy credential or fallback candidate is available, a rate
limit returns immediately to routing without sleeping or retrying the same
credential. With no healthy alternate, the provider's bounded retry policy is
unchanged. Credentials with exhausted account quota or credits retain the
rate-limit failover category but cool down for 15 minutes, doubling on repeated
failures up to one hour; longer provider retry-after hints are still honored.

Missing local API keys are credential failures, not provider outages. They remain
non-retryable against the same credential and do not open the provider-wide
circuit breaker or block another session with valid credentials.

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

`scripts/test path apps/coding_agent/test/coding_agent/session/live_provider_ownership_test.exs`
exercises public native Session and Agent model switches, missing-selected-login
refusal (including plan-role selection), successful keyless transitions,
switch-then-fallback header isolation and same-provider rebinding with no caller
headers and with genuine caller overrides, using fixture credentials and loopback
HTTP only. Its refusal and credential-leak checks scan complete captured events
and logs, including large tool-schema snapshots. The intentional fallback failure
uses fixture-owned provider health processes, so repeated runs neither inherit
nor contaminate the real provider's circuit breaker or request-rate bucket.

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
| `kimi_coding` (`kimi-code`) | Kimi Code device code (default), API key, or existing omp login (`--auth omp`) | Refreshable login in `providers.kimi_coding.api_key_secret`, `auth_source = "oauth"`; omp mode stores only `auth_source = "omp"` and an optional executable path, never credentials |
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

### Kimi Code requests and quota

Every `kimi_coding` (and `kimi`) model request carries the Kimi CLI
fingerprint (`user-agent`, `x-msh-platform`, `x-msh-version`, device name,
model, OS version and device id), whichever credential is used: a subscription
login (a JWT) is sent as `Authorization: Bearer`, an API key as `x-api-key`.
The device id is persisted in `~/.lemon/kimi-device-id` (mode 0600). A missing
file is seeded with the id earlier Lemon versions derived from the host name
and home directory, so existing logins keep their identity and a later host
rename no longer changes it; if the file cannot be written, the derived id is
used for that process.

Kimi Code reasoning models (`k3`, `k3-256k`, `k3.1-pro`, `k3.1-pro-highspeed`,
`kimi-for-coding`) are requested with `thinking: {type: "adaptive"}` plus
`output_config.effort` (`low`, `high` or `max`; other levels clamp) and the
`effort-2025-11-24` beta; a forced tool choice sends effort `low` without
thinking. `max_tokens` defaults to the model's maximum output (an explicit
`max_tokens` still wins). Requests that carry a session id send
`metadata.user_id`, a digest of that id (never the id itself), so Kimi can
route the session's prompt cache; `cache_retention = "none"` omits it. Thinking
and session identity are catalog flags (`adaptive_thinking`,
`compat.anthropic_session_user_id`); the full output budget is the default for
the Anthropic transport, not a Kimi-specific flag.

For a subscription login, `lemon model kimi_coding --status` also shows the
current quota from `GET https://api.kimi.com/coding/v1/usages` (or the
provider's `base_url`), for example
`Usage: 5h window: 76% used, resets 04:34Z; month: 57% used; month (coding): 59% used`.
An access token that has already expired is not sent. `lemon doctor --live`
checks `kimi_coding` against `/coding/v1/models` with the same authentication
and fingerprint as model requests.

If another Lemon process refreshes the same stored login at the same time, the
refresh that loses the conditional write adopts the winner's stored token when
it is different and unexpired, instead of failing. This applies to every
refreshable OAuth login.

### Kimi Code authentication through omp

To reuse a Kimi Code login managed by omp, sign in to Kimi Code with omp first,
then select the external source explicitly:

```bash
lemon model --provider kimi-code --auth omp
# Source checkout:
./bin/lemon model --provider kimi-code --auth omp
# Contributor alternative:
mix lemon.onboard kimi-code --auth omp
```

The canonical configuration is:

```toml
[providers.kimi_coding]
auth_source = "omp"
# Optional absolute executable path (not a shell command or a ~-relative path):
# omp_path = "/opt/bin/omp"
```

Without `omp_path`, Lemon searches for `omp` on `PATH`, then tries
`~/.bun/bin/omp`. An explicit path is authoritative: Lemon does not silently
switch executables if it is unusable. Config validation checks only path syntax;
the executable need not exist on the machine validating the config. Runtime
resolution checks that the selected path is executable.

Both credential resolution and readiness obtain an access token by running
`omp token kimi-code`, without a shell. Readiness does not launch a login flow
or inspect omp's credential files. The selected source is authoritative:
`KIMI_API_KEY`, `MOONSHOT_API_KEY`, inline `api_key`, `api_key_env`, and stored
`api_key_secret` / `oauth_secret` credentials do not override it, including when
omp fails. Fix the omp login or executable rather than adding a fallback key.

This is an **access-token-only** integration. Lemon uses the returned JWT for
the request and caches it only in the BEAM node's memory, shared across request
processes until two minutes before JWT expiry. It does not persist access tokens
or copy omp's refresh tokens or OAuth payloads into Lemon secrets. omp retains
ownership of login and refresh; Lemon does not refresh the access token itself.
The last JWT line in bounded command output is used, allowing harmless stderr
notices without accepting non-JWT credentials. Missing/unusable executables, command
failures, timeouts, or invalid token output produce safe, actionable errors,
never raw subprocess stdout/stderr or token contents.

`auth_source = "omp"` is supported only by `kimi_coding` and its runtime aliases
`kimi-coding` and `kimi-for-coding`. `kimi-code` is an onboarding alias, not a
provider-table name. Existing `auth_source = "oauth"` and `"api_key"` modes
remain available; OAuth remains the default onboarding mode.
`auth_source` values are case-insensitive and whitespace-trimmed; secret names
remain case-sensitive. Concurrent cache fills and forced refreshes are serialized
per executable and login scope, preventing an older fetch from restoring a
rejected access token.


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
server reloads are `exec`. A `write`, `edit` or `patch` call whose effective
`diagnostics` or `format` option is on (the argument, or the host default when
the argument is omitted; an explicit `false` wins) runs project toolchains and
is `exec`. `lsp_diagnostics` is `exec` and records a durable tool intent first.

Config supplies only the default. A canonical tool policy can set
`approval_mode = "ask"`, `"write"` or `"yolo"` in
`[profiles.<id>.tool_policy]` or through the existing PolicyStore session/runtime
policy. Explicit policy modes win over the config default. Policy intersections
retain the stricter mode, so delegated work cannot weaken parent approval gates.
The existing `approvals` map (`always`/`never`) overrides tier defaults in every
mode; `require_approval`, parent floors, and explicitly configured MCP approval
requirements remain mandatory. An `on_tool_call` hook's revised arguments are
used for approval resolution and the approval preview, not the original input.

## Bash Destructive Git Guard

```toml
[runtime.tools.bash]
git_guard = true # default; false disables destructive Git checks
```

The boolean guard refuses Git commands that discard uncommitted work, delete
stashes/unmerged branches, or force shared history without a lease. Checks run on
expanded commands before every bash launch mode; refusals identify the operation,
risk and disable setting. `reset --soft`/`--merge`/`--keep`, staged-only restore,
`push --force-with-lease` and ordinary branch checkout remain allowed.
See [shell tools](tools/shell.md#destructive-git-guard) for blocked forms.

Effective cwd inside a `task` isolation worktree is exempt only with a matching
task-store workspace record and Git worktree backlinks. Directory names alone do
not qualify. Git `-C` and the bash `cwd` option are respected; uncertain cwd,
repository/environment redirection or unavailable ownership records disable the
exemption. This guard is not a security sandbox for dynamic shell evaluation.

## Bash Dedicated-Tool Routing

Opt in to shell interception in user or project `.lemon/config.toml`:

```toml
[runtime.tools.bash.interceptor]
enabled = true # default false
# Optional replacement for the complete default rule list:
# rules = [{pattern = '^cat\s+', tool = 'read', message = 'Read files with read.'}]
```

Rules are `{pattern, tool, message}` tables with valid regular expressions and
non-empty tool/message strings. Defaults route cat/head/tail/less/more to `read`,
grep/rg (also ripgrep/ag/ack) to `grep`, find/fd/locate to `find`, ls to `ls`, and
sed/perl in-place edits to `edit`. A rule only blocks when its target is in the
session's filtered tool set. Pipeline consumers such as `git log | head` remain
allowed. Checks scan simple commands, stripping assignments and common execution
prefixes, including commands inside subshells and substitutions; quoted data does
not become a command. They are advisory routing checks, not a shell sandbox.
Checks run after internal URL expansion and before foreground, background or
named-service launch. Refusals return an error tool result and configuration
disable guidance. See [shell tools](tools/shell.md).

## Anchored Edit Visibility

Seen-line enforcement is on by default for stale-snapshot recovery. Disable it in user or project `.lemon/config.toml`:

```toml
[runtime.tools.edit]
enforce_seen_lines = false # default true
```

A tag matching the current complete file permits any in-range line, including
omitted summary bodies and window gaps. When recovering a historical tag, every
original replaced/deleted line and insertion anchor must have been displayed by a
numbered read in the current session before translating uniquely unchanged
anchors. Stale refusals include fresh tags and bounded current context without
writing. Plain `old_text`/`new_text` replacements are unaffected. The setting must
be boolean; tool hosts can explicitly override it with `:enforce_seen_lines`.
See [file tools](tools/files-and-search.md#anchored-edit-recovery-and-formatting)
for visibility and snapshot-retention details.

## Post-Edit Checkers and Formatters

`write`, `edit` and `patch` calls with `diagnostics` or `format` (and
`lsp_diagnostics`) run checkers and formatters resolved from the operator's
`PATH`. Each runs as one owner-bound `ProcessManager` launch whose root shell
stays alive as the process-group anchor until cleanup. On completion, abort or
timeout the group is killed through the birth-bound ownership check against
that anchor (children that outlived the checker included), and the launch's
capacity is released when termination is confirmed. A checker that removes
its own anchor, or a group whose stop cannot be confirmed, is reported with its
`proc://` id instead of being signalled by a possibly reused id. An executable
whose path, canonical path or canonical parent directory lies inside the
workspace or project root (compared lexically and canonically), or that cannot
be canonicalized, is refused unless the global config opts in:

```toml
[runtime.tools.edit]
repo_local_tools = true # default false; global config only
```

Project config cannot set it. Execution nodes read it from their own global
config. The calls stay `exec` tier either way.

## Language Servers

Configure `[runtime.tools.lsp.servers.<id>]` in the global config. The
effective catalog merges built-ins, then global values; a project file may only
set `disabled = true` (see [Project config trust](#project-config-trust)). Known ids
override fields; custom ids require `command` and a non-empty `extensions` list
(`file_types` is an alias).

```toml
[runtime.tools.lsp]
idle_timeout_ms = 30000 # grace after the last owner releases; 0 stops immediately

[runtime.tools.lsp.servers.clangd]
command = "/opt/llvm/bin/clangd"
args = ["--background-index"]
root_markers = ["compile_commands.json", ".git"]
extensions = [".c", ".h"]
language_id = "c"
initialization_options = { clangdFileStatus = true }
env = { CLANGD_FLAGS = "" }
disabled = false
```

`command` and `language_id` are non-empty strings; `args`, `root_markers`,
`extensions`/`file_types` are string arrays; `env` is a string-to-string table;
`initialization_options` is a table; `disabled` is boolean. Lists replace
inherited values; nested tables merge. Command environment variables take
priority over TOML. Disabled servers are excluded from all catalog lookups.
See [LSP tools](tools/lsp.md#server-configuration) for custom servers and scope.

## Web Tools (`websearch` / `webfetch`)

Lemon includes web tools under `runtime.tools.web`. For full setup and troubleshooting, see:
- [`docs/tools/web.md`](tools/web.md)
- [`docs/tools/firecrawl.md`](tools/firecrawl.md)

```toml
[runtime.tools.web.search]
enabled = true
provider = "brave"   # brave | exa | perplexity | tavily | kagi | jina | keenable | duckduckgo | searxng | extension id
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

# tavily, kagi, jina and keenable take the same shape (api_key or api_key_secret);
# TAVILY_API_KEY / KAGI_API_KEY / JINA_API_KEY / KEENABLE_API_KEY are used when unset.
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

Browser provider selection is shared by tool availability, doctor, and
control-plane status. See [Choosing a browser provider](tools/browser.md#choosing-a-browser-provider)
for the auto order, fail-closed behavior, LCU prerequisites and connector rollback.

```toml
[runtime.tools.browser]
provider = "auto" # tern, lcu, relay, local, cdp, browserbase, browser_use,
                  # firecrawl, camofox
tern = true # false disables native Tern browser integration
```

`LEMON_BROWSER_PROVIDER` takes precedence over TOML. For a direct-loopback TUI
invocation bound to a Tern pane, `auto` first checks Tern's native browser;
otherwise it checks LCU, the authenticated relay, then managed local Chrome.
`LEMON_BROWSER_TERN=0` disables native Tern browser integration. A definite
unavailable-window/unsupported/connect error during auto-selected PiP opening
falls back to the next browser backend and reports a note. Explicit `tern`, like
other explicit providers, never falls back to another browser identity.
Provider credentials remain in the secret store/environment, not this selector.
The following environment variables configure individual backends:

| Variable | Default | Purpose |
|---|---|---|
| `LEMON_BROWSER_PROVIDER` | `auto` | Unified provider id (see above) |
| `LEMON_BROWSER_TERN` | `true` | Enable native Tern PiP for a locally bound pane (`0` opts out) |
| `LEMON_BROWSER_DRIVER_PATH` | auto | Browser Node driver path |
| `LEMON_BROWSER_CDP_ENDPOINT` | none | HTTP discovery or direct `ws`/`wss` CDP endpoint |
| `LEMON_BROWSER_ATTACH_ONLY` | `false` | Never launch a replacement browser |
| `LEMON_BROWSER_ALLOW_UNENFORCED_EGRESS` | `false` | Required to attach to any browser Lemon did not launch (CDP endpoint, attach-only, relay); such a browser bypasses the egress proxy |
| `LEMON_BROWSER_CDP_PORT` | `18800` | Local CDP port for attach-only mode; managed Chrome uses a free port |
| `LEMON_BROWSER_RELAY_PORT` | `9224` | Loopback MV3 relay port |
| `LEMON_BROWSER_RELAY_TOKEN` | none | Required relay shared secret |
| `LEMON_BROWSER_BACKEND` | `local` | `local`, `tern`, `browserbase`, `browser_use`, `firecrawl`, or `camofox` |
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

The explicit computer-use switch (`enabled`) defaults to off and is the only
thing that enables computer use; it is read once at boot. Browser provider `lcu`
never enables it: with the switch off, `auto` skips `lcu` and an explicit `lcu`
fails closed. With it on, LCU's native app APIs are protected
by the existing approval policy. See
[`docs/tools/computer-use.md`](tools/computer-use.md) for requirements and
approvals. `LEMON_COMPUTER_USE_*` environment variables override these keys.

```toml
[runtime.tools.computer_use]
enabled = false
# lcu_root = "~/.local/share/lcu/current"
# node = "<lcu_root>/agent-tools/node/bin/node"
declined_origins = []      # also list foreground/remote Lemon Bot public URLs here
lasting_grant_apps = []    # bundle ids allowed lasting grants; default: every app once-only
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

## Semantic find

`semantic_find` maps a plain-language behavior description ("where a failed upload
is retried") to ranked `path:line` locations. It is **off by default** and is
separate from `find` (file-name globs) and `grep` (regex). The tool is not
registered, and not shown to the model, unless it is enabled **and** a small model
is explicitly configured.

```toml
[runtime.tools.semantic_find]
enabled = false      # opt in with true
# model = "@smol"    # optional; defaults to model_roles.tiny, then model_roles.smol
max_tokens = 8000    # per-call cap on prompt + completion tokens (512-200000)

[model_roles]
smol = "openai:gpt-4o-mini"
```

- **Model.** `semantic_find.model` (a concrete `provider:model` or a configured
  `@role`) wins; otherwise the explicitly configured `model_roles.tiny`, then
  `model_roles.smol`. The active session model is never used as a fallback: with
  no small model configured the tool stays unavailable.
  Role chains must resolve completely; missing roles never fall back to the main
  model. Only OpenAI (`openai_completions` / `openai_responses`) and Anthropic
  (`anthropic_messages`) APIs are currently audited for a provider-side output
  ceiling and byte-level prompt bound. Other provider/API pairs, including
  `openai-codex`, fail closed and leave the tool unavailable.
- **Cost.** Every call that finds candidates makes one small-model request with no
  tools and at most `max_tokens` tokens: the completion ceiling (a quarter of the
  cap, between 128 and 1024 tokens) is sent as the request's output limit, and the
  candidate list is trimmed using one token per UTF-8 byte plus 256 tokens for
  message framing (an upper bound, not an average token estimate), reserving the
  completion allowance before dispatch. A
  description with no keyword hits makes no model call. The cap bounds one call;
  there is no separate per-session limit, and these calls are not counted against
  the [cumulative usage budgets](#cumulative-usage-budgets).
- **Usage.** The provider-reported tokens for each call are recorded in the usage
  ledger under the session's run and session key (provider/model of the small
  model), so they appear in `usage.cost`, usage records and the usage page like
  any other model request. A price Lemon cannot attest stays unknown rather than
  becoming an estimate. The tool result's `details.usage` repeats the numbers.
- **How it searches.** There is no embedding index or other persistent store. Each
  call scans the requested roots (skipping hidden, ignored, dependency/build,
  binary and oversized files, with file-count and byte caps), scores lines against
  the description's keywords, and lets the model only choose among the numbered
  lines it was sent, so it cannot invent a location. Repository text sent to the
  small model is untrusted data, and results are marked untrusted.

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

## Vendor Tool Dialect Experiment

Native tool names and schemas remain the default. To opt a native session into
the #603 arena experiment, set this in user or project configuration:

```toml
[runtime.tools]
vendor_dialects = true # default false
```

`CodingAgent.Session` callers can override it with `:vendor_tool_dialects`.
Claude model IDs expose `Read(file_path, offset?, limit?, pages?, allow_large?)`,
`Edit(file_path, old_string, new_string, replace_all?)`, and
`Bash(command, timeout?, description?, run_in_background?, dangerouslyDisableSandbox?)`
instead of the native read/edit/bash inputs. Codex model IDs or the Codex
Responses API expose `apply_patch` instead of `patch`, using the upstream Lark
grammar as a real Responses custom/freeform tool (not JSON-wrapped patch text).
Other tools and models are unchanged. Explicit model switches re-project tools.

These are input adapters, not vendor executors. Translation enters the existing
native policy-filtered, approval-wrapped, hook-intercepted and plan-gated closure.
Policies, allow/deny lists and approval rules continue to use native names
(`read`, `edit`, `bash`, `patch`), including in plan mode. No alias can reintroduce
a denied tool. Native output, cancellation, read caps, stale-read checks,
checkpoints, mutation locks and background-process semantics remain unchanged.
`allow_large` does not raise Lemon's output cap; `pages` translates to native
`page`/`page_limit`; `dangerouslyDisableSandbox: true` fails closed.
`replace_all: true` uses the native edit transaction and replaces exact matches;
omitting it retains the native unique-match behaviour.

Sources: Claude Code
`sdk-tools.d.ts` in `@anthropic-ai/claude-code` version 2.1.325
(`FileReadInput`, `FileEditInput`, `BashInput`); Codex
[`apply_patch.lark`](https://github.com/openai/codex/blob/b016cd18472588606c04af565528c4cd6746a41f/codex-rs/core/assets/tools/apply_patch.lark)
and its
[`FreeformTool` specification](https://github.com/openai/codex/blob/b016cd18472588606c04af565528c4cd6746a41f/codex-rs/core/src/tools/handlers/apply_patch_spec.rs).
The upstream identity manifest records their source hashes.

Decision: **keep opt-in; no default promotion**. No paired paid arena result is
claimed here. Run the same tasks/model/seeds with this flag off/on and record
the paired report and decision before changing the default (#543/#603).

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
profile = "auto"         # coding for cwd-scoped sessions; legacy for assistant chat
pinned = []              # tool names that always stay directly exposed
```

- **`auto`** (default): selects `coding` for cwd-scoped coding sessions (including
  local TUI, ACP, and `lemon -p`/`run`) and `legacy` for main assistant and messaging
  sessions. Explicit profile settings retain precedence over this inference.
- **`legacy`**: built-in tools stay exposed. The MCP, extension and WASM tools
  are deferred only when the estimated schema cost of the whole catalog exceeds
  `budget_tokens`; below it the tool list is unchanged.
- **`coding`**: only the coding core stays
  directly exposed — `read`, `write`, `edit`, `patch`, `ls`, `find`, `grep`,
  `ast_grep`, `lsp_diagnostics`, `fs_checkpoint`, `bash`, `bash_output`,
  `kill_process`, `websearch`, `webfetch`, `read_skill`, `recall`, `todo`,
  `ask`, enabled `checkpoint` / `rewind`, `task`, `wait`, `agent_message` and `parent_question` — plus `pinned`
  names. Every other resolved tool, including browser, media, automation and
  other optional built-ins, is deferred whenever there is one to defer;
  `budget_tokens` is not consulted. The November 2026 coding arena motivated this
  default: lower input-token use without a measured pass-rate loss. See the
  [rollout evidence](benchmarks/paired-disclosure.md#decision-and-evidence-status).

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

The experimental `profile = "code_mode"` (or
`LEMON_TOOL_DISCLOSURE_PROFILE=code_mode`) replaces that profile's `eval` with
permissionless Deno cells and `eval_wait`, with deterministic TypeScript tool
declarations. It requires Deno 2, remains opt-in, and does not change `auto`.
See [eval](tools/eval.md#experimental-code-mode-profile) for isolation,
bridged-call authority, re-attachment and the paired-evaluation command.

To opt out of the coding default, set `profile = "legacy"` in the existing
global/project section or `LEMON_TOOL_DISCLOSURE_PROFILE=legacy` on the runtime.
`enabled = false` / `LEMON_TOOL_DISCLOSURE_ENABLED=false` disables disclosure
entirely. Since the CLI reuses a daemon, environment overrides must be applied to
that runtime, not only to an already-attached client.

Coding sessions omit assistant-home persona/bootstrap files and assistant-only
memory/learning workflow reminders, retain repository instructions and skills,
and shorten skill discovery descriptions to 96 characters (full metadata and
instructions remain behind `read_skill`). Main/chat sessions keep their current
bootstrap and full descriptions. Native callers can set `session_mode: :chat`
or explicitly set `persona: true|false`; `lemon -p --no-persona` explicitly
suppresses bootstrap even when resuming an assistant session.

## Sections

- `providers.<name>`: API keys and base URLs per provider.
- `defaults`: global default provider, model, and thinking level for native execution.
- `runtime`: runtime behavior and tool settings.
- `runtime.tools.web`: `websearch` / `webfetch` providers, guardrails, cache, and Firecrawl fallback.
- `runtime.tools.wasm`: WASM sidecar runtime controls and discovery paths.
- `runtime.tools.disclosure`: deferring tool schemas behind `tool_search` / `tool_invoke` (see [Tool Disclosure](#tool-disclosure)).
- `profiles.<agent_id>`: assistant profiles (identity + defaults) used by gateway/control-plane.
- `runtime.compaction`: context compaction settings. Automatic compaction runs when the request
  exceeds the context window minus `max(ceil(15% of window), reserve_tokens)`.
  The configured reserve defaults to 16,384; larger overrides are respected.
  Optional `threshold_percent` (integer 1–100,
  percent of the window) or `threshold_tokens` (positive integer; wins over the percent) lower that
  threshold; they never raise it above the reserve limit. Invalid values fail config validation.
  `/context` and `sessions.context` report the effective threshold. Models with an
  unknown or non-positive context window skip token-based automatic compaction
  and report unknown capacity as null; explicit compaction and provider overflow
  recovery remain available.
  Automatic compaction must land at or below 80% of the effective trigger
  (the omp #2275 dead-loop recovery band). `keep_recent_tokens` is an upper
  target, reduced to fit that band including request overhead. A pass that
  misses the band escalates once through overflow compaction with a minimal
  valid tail. If that still cannot fit, `compaction_recovery_band` ends the
  prompt and unchanged history is not compacted again each turn; the session
  stays free for `/compact` and new turns. Reduce request overhead, manually
  compact, or start a new session.
  Before calling the summary model, Lemon spills old tool-result bodies to
  session-scoped `artifact://` handles. It protects the newest 40,000 estimated
  tokens and skips results below 50 tokens (omp's `docs/compaction.md` policy).
  References recover the original JSON content blocks through `read`; tool
  call IDs, result IDs, ordering and error status remain unchanged for every
  provider. A branch-local journal marker retains these projections across
  resume without rewriting original output. Failed spills leave output intact.
  When pruning alone reaches the recovery band, no summary call is made;
  message-count pressure still requires summarization.
- `runtime.retry`: session retry of transient provider failures (backoff + retry-after).
- `runtime.max_tool_turns`: optional per-prompt cap on tool-using turns (default unlimited).
- `runtime.secret_obfuscation`: opt-in placeholder obfuscation of secrets in provider-visible text ([details](security/secret-obfuscation.md)).
- `tui`: terminal UI settings.
- `gateway`: Lemon gateway settings, including `telegram`, `discord`, `sms`, `voice`, `xmtp`, `projects`, and `bindings`.
- `logging`: optional file logging configuration.
- `automation`: cron catch-up and run-history retention.
- `cron`: cron failure-alert cooldown settings.
- `memory`: per-turn automatic recall and `remember` write approval; `skills`: `write_approval` for `skill_manage` ([Memory](#memory)).
- `budgets`: cumulative usage budgets ([Cumulative usage budgets](#cumulative-usage-budgets)).
- `features`: feature flags ([Feature Flags](#feature-flags)).
- `secrets.sources.<source_id>`: external secret sources ([External secret sources](#external-secret-sources)).
- `gateway.a2a`: A2A peer transport ([A2A peers](#a2a-peers)).

## Automation

`[automation]` holds cron scheduler settings:

```toml
[automation]
catch_up_missed = true
run_retention_per_job = 100
```

- `catch_up_missed` (default: `true`) — restart runs one missed slot when it is
  within half the schedule's next-occurrence gap, clamped to 2 minutes–2 hours.
  Older slots are audited as skipped; expired one-shots are retired. Set `false`
  to skip all missed slots. Paused jobs remain paused.
- `run_retention_per_job` (default: `100`) — non-negative number of terminal
  runs retained per job by hourly cleanup. Active attempts and undispatched
  retries are exempt. This also applies to history of removed jobs.

See [Reminders and heartbeats](user-guide/reminders-and-heartbeats.md).

### Cron failure alerts

```toml
[cron]
failure_alert_cooldown_ms = 21600000 # 6 hours
```

`failure_alert_cooldown_ms` is a non-negative integer, resolved and validated by
the core automation configuration. It limits repeated failure alerts per job
and normalized error class; the first failure and a changed error class alert
immediately. `0` disables the cooldown. Incident state survives restarts.
Recovery notices are separate from cooldown reminders. See the
[failure-alert workflow](user-guide/reminders-and-heartbeats.md#failure-alerts-and-recovery)
for routing, silent successes, and local doctor warnings.

## Gateway core settings

Top-level `[gateway]` keys (defaults from `LemonCore.Config.Gateway`):

| Key | Default | Meaning |
| --- | --- | --- |
| `max_concurrent_runs` | `2` | Positive gateway-wide execution permit limit (`LEMON_GATEWAY_MAX_CONCURRENT_RUNS`), owned by `LemonGateway.Slots`. |
| `default_cwd` | unset | Fallback working directory for unbound chats (`LEMON_GATEWAY_DEFAULT_CWD`). |
| `auto_resume` | `false` | Resume interrupted sessions on start. |
| `enable_telegram`, `enable_discord`, `enable_xmtp`, `enable_webhook`, `enable_a2a` | `false` | Enable the named channel; `enable_<id>` is read per registered channel (and `LEMON_GATEWAY_ENABLE_<ID>` overrides it). |

`enable_webhook` is validated as a boolean. Invalid execution capacity fails
startup; there is no fallback to 10. Engine-session ownership is always a
fail-fast claim, not a configurable lock or timeout.

The gateway reads `[gateway]` live from the canonical config; there is no
second, boot-time copy. A config reload applies `max_concurrent_runs` to the
running gateway (a lower limit stops new grants until running work drains) and
is visible to every gateway and channel reader without a restart. A config that
cannot be loaded at startup fails startup instead of starting with every
channel disabled. `[gateway.queue]` was never read and has been removed: it is
ignored with a warning (`lemon config validate`, `lemon doctor`).

This execution cap does not bound queued Runs or coordinator population.
Router's `config :lemon_router, run_process_limit: 500` bounds live router
RunProcesses, including those waiting for gateway permits. It is independent of
`max_concurrent_runs`. See the canonical
[admission inventory](architecture/admission-gates.md) for every gate and
saturation behavior.

## A2A peers

`[gateway.a2a]` configures the A2A v1.0 peer transport; enable it with
`gateway.enable_a2a = true`. See the [A2A peers guide](user-guide/a2a-peers.md)
for setup. The listener binds loopback `127.0.0.1:9901` by default; remote binds
require token secret names (validated at load).

| Key | Default | Meaning |
| --- | --- | --- |
| `host`, `port` | `127.0.0.1`, `9901` | Listener bind (`LEMON_A2A_HOST`, `LEMON_A2A_PORT`). |
| `public_url` | unset | Advertised URL (`LEMON_A2A_PUBLIC_URL`). |
| `name`, `description` | `Lemon`, a short description | Agent card identity. |
| `agent_id` | `default` | Lemon agent profile that answers peers. |
| `skills` | `["coordination", "coding"]` | Advertised skills. |
| `reply_timeout_ms` | `300000` | Positive integer (`LEMON_A2A_REPLY_TIMEOUT_MS`). |
| `rate_limit_per_minute` | `60` | Positive integer (`LEMON_A2A_RATE_LIMIT_PER_MINUTE`). |
| `max_context_turns` | `100` | Positive integer (`LEMON_A2A_MAX_CONTEXT_TURNS`). |
| `default_allow_tools` | `read read_skill recall grep find ls webfetch websearch peer` | Tools inbound peer runs may use unless a peer overrides it. `kanban` and other work-starting tools need an explicit entry. |

Each `[gateway.a2a.peers.<name>]` sets `url`, `token_secret` (or separate
`inbound_token_secret` / `outbound_token_secret`), `agent_id`, `capabilities`,
`timeout_ms`, `allow_tools` (empty means `default_allow_tools`) and
`trusted_automation`. Tokens are secret names, never literal values.

A peer token authenticates the peer, not the content it relays, so every
inbound peer run requires approval for each `bash`, `write`, `edit`, `patch`
and `hashline_edit` call it is allowed (the group approval floor). Set
`trusted_automation = true` (a literal boolean) on a peer only to exempt that
peer from the floor. Webhook integrations take the same per-integration key,
`[gateway.webhook.integrations.<id>] trusted_automation = true`. Gateway
sections are operator-only: a project `.lemon/config.toml` cannot set either.

## Gateway Projects and Bindings

When LemonGateway handles a Telegram message, it can optionally map that chat (or topic/thread) to a named
**project**. A project is a **working directory root** plus optional agent and
queue defaults.

Why it matters:
- The native executor runs with `cwd` set to the project root (so file edits/commands happen in the right repo).
- The gateway loads per-project config from `<project_root>/.lemon/config.toml`, limited to the
  [project allowlist](#project-config-trust) (model preferences and narrowed profile tool policy).
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
- In Telegram and Discord, you can set or inspect the current chat/topic working directory at runtime with
  `/cwd [project_id|clear]`. Only ids configured under `[gateway.projects]` are accepted; host paths are
  refused, and chat never creates or retargets a project.
- `/new <project_id>` selects a configured project the same way, and setting `/cwd` makes future `/new`
  sessions in that chat/topic use the same directory.
- `/new` confirmation replies include model, provider, cwd, and session context details.

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
allowed_inboxes = ["<sender inbox id>"]  # required: who may start runs (fail-closed when empty)
# allow_all = true                 # explicit opt-out: accept every sender when allowed_inboxes is empty
# Optional:
# api_url = "https://api.xmtp.network"
# inbox_id = "..."
# sdk_module = "@xmtp/node-sdk"
```

Notes:
- When `enable_xmtp = true`, Lemon auto-registers and starts the XMTP channel adapter.
- `require_live = true` keeps health/readiness red unless the bridge is truly live (not mock mode).
- `wallet_key_secret` is the canonical credential field. It can point to a Lemon secret name or to an env var name when using secret resolution with env fallback.
- Non-text XMTP messages from authorized senders receive a text-only fallback response.

### Sender authorization

The XMTP adapter fails closed. It accepts messages only from the XMTP inbox ids
listed in `gateway.xmtp.allowed_inboxes` (matched case-insensitively against the
message's authenticated sender inbox id, never a resolved wallet address). With an
empty or missing allowlist the adapter is unpaired: it logs a startup warning and
drops every inbound message. `allow_all = true` explicitly accepts every sender when
no allowlist is set; anyone who can message the wallet can then run the agent. A
non-empty allowlist always wins over `allow_all`.

- The policy (`allowed_inboxes`, `allow_all`) is re-read from the current config for every
  inbound message, so a config reload that removes an inbox or turns `allow_all` off
  applies to the next message without restarting the adapter.
- Dropped messages are never deduped, replied to or submitted. The warning log names
  the reason (`unpaired` or `sender_not_allowed`), the sender inbox id and the
  conversation id, never the message content; use it to find an inbox id to allow.
- Group conversations also require a mention of the bot: `@<bot inbox id>` or
  `@<bot wallet address>` (case-insensitive). Group messages without one do not trigger
  a run, even from an allowed sender.
- The bridge never syncs, lists or streams conversations whose XMTP consent state is
  `DENIED`. Conversations in the `ALLOWED` and `UNKNOWN` states (every new inbound DM
  starts as `UNKNOWN`) are polled, and their senders are then checked against the
  allowlist.
- The bridge also re-reads a conversation's consent immediately before every send
  (agent replies, placeholder and failure replies) and refuses `DENIED` or unreadable
  consent with a `conversation_not_allowed` bridge error, so denying a conversation
  also stops outbound delivery to it.

### Upgrading an existing XMTP deployment

Earlier releases accepted every XMTP sender. After upgrading, an XMTP adapter with no
`allowed_inboxes` ignores all inbound messages until you act:

1. Add each permitted sender's inbox id to `gateway.xmtp.allowed_inboxes`. Inbox ids
   of senders who message the bot appear in the `xmtp inbound dropped:
   reason=unpaired` warning log.
2. Tell group members to mention the bot (`@<bot inbox id>` or `@<bot wallet address>`);
   unmentioned group messages no longer start runs.
3. Only if you deliberately want any XMTP identity to run the agent, set
   `allow_all = true` and leave `allowed_inboxes` empty. This is an explicit opt-out
   of sender authorization and is logged as a warning at startup.
4. Messages dropped before you authorize a sender are acknowledged to the bridge and
   are not replayed when the allowlist changes; those senders must send them again.

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

Every voice webhook and the media-stream WebSocket handshake must carry a valid
`X-Twilio-Signature` made with the configured Twilio auth token over the URL derived
from `public_url` (request and `X-Forwarded-*` headers are never used). An `https://`
`public_url` and the auth token are both required: without either, or with an `http://`
`public_url`, every voice request gets 403. Set `public_url` to the exact origin
configured in Twilio. The WebSocket handshake signature is accepted over the `wss://` or
`https://` form of that URL, with or without a trailing `/`. The TwiML `<Stream>` URL is the
query-free `wss://` form of `public_url`; call metadata and an expiring per-call token
bound to the authenticated CallSid travel as `<Parameter>` elements and are verified from
the stream's `start` message before any call session, Deepgram socket or recording is
created. Deepgram sockets are owned by the call and closed whenever it ends.
Recording downloads only contact `https://api.twilio.com` (Basic auth is never sent
elsewhere or on redirects) through the pinned `LemonCore.Net.HTTP` fetcher: each hop has
a 120 s deadline, the WAV streams to a temporary file cut off above 512 MiB and is renamed
into place only when complete, and recording filenames are sanitized.

## Channel Voice Replies

Voice replies are opt-in separately for each channel, under
`[gateway.<channel>.voice_replies]`; they are unrelated to the phone-call
transport at `[gateway.voice]`.

```toml
[gateway.telegram.voice_replies]
enabled = true
provider = "openai"
model = "gpt-4o-mini-tts"
voice = "alloy"
base_url = "https://api.openai.com/v1"
api_key_secret = "openai_api_key"
# api_key = "..." # optional direct credential; prefer encrypted secrets
```

The same table can be configured for other channel IDs. `enabled` defaults to
`false`; provider, model, endpoint and credentials are independent of chat-model
settings. Only replies to inbound voice messages are eligible. The text answer
is always delivered as the transcript, including when speech synthesis fails.
Speech synthesis is asynchronous and starts only after all final transcript
chunks are confirmed delivered. If transcript delivery fails, audio is withheld.
Provider responses are limited to 20 MiB; oversized audio leaves text-only delivery.
Credentials may be supplied with `api_key` or an encrypted-store reference
`api_key_secret`; secret-resolution failures must not fall back to a different key.

`price_per_million_characters` optionally sets the configured speech model's
USD price per million input characters (a non-negative number). Set it only
from your provider's applicable model tariff; there is no built-in assumed
price. Update it when changing models, and leave it absent for models billed
only by tokens or audio duration. When speech returns no reported cost (as
OpenAI's binary speech response does), Lemon computes
`input_characters * price_per_million_characters / 1_000_000`. An explicitly
reported provider cost takes precedence, including zero. The canonical usage
ledger retains `input_characters` (Elixir `String.length/1`, Unicode graphemes)
alongside token counts, without retaining speech text. With no applicable price,
it retains the character count and records `cost_usd: nil`, `price_known: false`;
it never treats missing pricing as free speech or invents token usage.


## Telegram Voice Transcription

If enabled, Telegram voice notes are transcribed and the transcript is routed as a normal text message.

```toml
[gateway.telegram]
voice_transcription = true
voice_transcription_provider = "openai_transcribe"
voice_transcription_model = "gpt-4o-mini-transcribe"  # optional
voice_max_bytes = 10485760                            # optional (default: 10MB)

# Optional OpenAI-compatible endpoint override. Credentials default to [providers.openai].
voice_transcription_base_url = "https://api.openai.com/v1"
```

Use `openai_transcribe` with provider credentials for real speech-to-text.
`local_transcript` has no local STT implementation: it returns `:no_local_stt`,
shows the existing voice-transcription failure message, and never submits a run.
It does not generate preview text or transcribe audio.

`mix lemon.doctor` skips the check when transcription is disabled and warns
when credentials are missing or `local_transcript` is selected.

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
allowed_user_ids = [123456789]  # authoritative for DMs and groups when set; if empty, groups need a
                                # Telegram group admin and DMs need the owner (Discord: Manage Server;
                                # Discord auto-put needs a non-empty list)
deny_globs = ["**/*.pem"]       # added to the built-in denies of .git, .ssh, .lemon, .netrc, .env, .envrc, .env.*
max_upload_bytes = 20971520     # optional (default: 20MB)
max_download_bytes = 52428800   # optional (default: 50MB)
```

Commands:
- `/file put [--force] <path>`: upload a Telegram document into the active working root.
- `/file get <path>`: fetch a file (or zip a directory) from the active working root back into Telegram.

Paths are relative to the root; `..` and absolute paths are refused, and any symlink below the root
(file or directory) is refused rather than followed. Deny rules are checked per entry at use time, so they also
cover files created later; directory archives contain only allowed regular files and skip symlinks. Uploaded file
names are reduced to their basename, and an existing symlink at the destination is never written through.

Deny rules compare names case-insensitively against the actual directory entries, so `.ENV` or `.GiT/config`
on a case-insensitive filesystem is denied like `.env` and `.git/config`. `deny_globs` use the `Path.wildcard`
grammar: `**/` (zero or more directories), `**`, `*`, `?`, `{a,b}` alternatives (not nested, no `/` inside),
`[abc]` and `[a-z]` classes, and `\` escapes. A malformed pattern (unbalanced or nested braces, an unterminated
or empty class, a non-string entry) denies every path rather than being ignored. The same rules, with this
channel's `deny_globs`, apply to the channel-keyed `send_file` tool, which re-reads the resolved file beneath its
physical root and queues a private copy of the validated bytes rather than its source path.

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

Uploaded attachments (`/file put`, `auto_put`) are fetched only from
`https://cdn.discordapp.com` or `https://media.discordapp.net` through the pinned
`LemonCore.Net.HTTP` fetcher: no redirects, a 60 s deadline, and the download is cut
off as soon as it exceeds `max_upload_bytes`. Telegram file downloads likewise use the
pinned fetcher (no redirects, 60 s, at most 20 MiB, the Bot API `getFile` limit).

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
because any member can prompt the agent. Cron runs in a chat's session (`/remind`
reminders and jobs the agent schedules there) keep this floor and the chat's channel
and session policy.

## Telegram and Discord DM pairing codes

Set `unauthorized_dm_behavior = "pair"` in `[gateway.telegram]` or
`[gateway.discord]`, then restart Lemon. An unknown human DM receives an
eight-character code and asks the owner to run:

```bash
lemon pairing list
lemon pairing approve telegram <CODE>
# Or: lemon pairing approve discord <CODE>
lemon pairing deny telegram <CODE>
lemon pairing revoke telegram <CHAT_ID>
```

Approval and `revoke` take effect on the running gateway immediately; no restart
is needed, including after a supervised adapter restart. The allowlist change is
also written to the user config for later boots. A configured but empty Discord
`allowed_channel_ids = []` denies every channel (an absent key leaves channels
unrestricted), so revoking the last channel stays closed across restarts.

The default, `"ignore"`, preserves existing behavior: Telegram's empty-allowlist
setup hint remains rate-limited, non-allowlisted chats are dropped, and Discord
retains its configured guild/channel restrictions. In `"pair"` mode, Discord DMs
require an explicit channel allowlist entry even if the allowlist was absent.
Groups, guild channels, bots, callbacks and slash-command interactions do not mint
codes. Telegram `/whoami` continues to answer without authorization.

Codes expire in one hour, are single-use and platform-bound, and only their
SHA-256 digests are stored. Each platform admits at most three pending requests.
Repeated DMs reuse the pending request and receive at most one code reply every
ten minutes. After a runtime restart a pending code is still approvable, but cannot
be displayed again because plaintext is never persisted; wait for expiry if lost.
`list` shows platform, masked chat ID, display name and age, never codes. Names are
untrusted: confirm the sender out of band before approving.

Only the local operator CLI approves; the runtime list/consume method requires
operator pairing scope and a direct loopback connection. Chats cannot approve
themselves. Approval consumes the code and appends the chat ID to the user config's
Telegram `allowed_chat_ids` or Discord `allowed_channel_ids` through the same
TOML patcher as gateway setup. It does not loosen guild restrictions for guild
traffic; an explicitly allowed DM can operate independently of guild membership.
Project config overrides still take precedence. **Restart Lemon after approval**:
the config watcher reloads canonical config but existing adapters retain their
startup authorization state. No automatic confirmation is sent. If config writing
fails after consumption, fix the config and ask for a fresh request.


## Trigger Mode (Mentions-Only)

Telegram group chats (like Discord) default to mentions-only: Lemon runs only on `@botname`, a reply to the bot, or a
slash command. Direct messages always run.
- `/trigger` is owner-only (a human user id listed in `allowed_chat_ids`); in
  groups the owner must also be a group admin. On Discord it requires the
  Administrator or Manage Server permission.
- `/trigger`: show current trigger mode.
- `/trigger mentions`: only run on `@botname`, reply-to-bot, or slash commands (default).
- `/trigger all`: run on all messages in this chat or topic.
- `/trigger clear`: clear a topic override (forum topics only).
- `/cwd [project_id|clear]`: show, set, or clear the chat/topic working directory override used by future `/new` sessions (configured project ids only).

Forum topic management:
- `/topic <name>`: create a new topic in the current Telegram forum supergroup.

## Learning Reminders (skills.json)

Learning reminder settings use the existing skills configuration, **not**
`config.toml`: global `~/.lemon/agent/skills.json` (or `LEMON_AGENT_DIR/skills.json`)
and project `<cwd>/.lemon/skills.json`. A project file can only narrow the
global one: `enabled = false`, or a larger `memory_turn_interval` /
`skill_tool_threshold`; every other project `learning_nudge` key (including
`background_review`) is ignored.

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
