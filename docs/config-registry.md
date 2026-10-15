# Environment Variable Config Registry

This is a best-effort reference for declared environment variables, grouped by area. `LemonCore.Env.all_declared/0` aggregates the app registries configured under `:env_registries`; undeclared direct environment reads may not appear here. The owning app and declaration describe each variable; a declaration does not prove that every build reads it.

As of this writing, `LemonCore.Env` is a **registry and typed accessor**, not yet the only way these variables are read. Call sites still read most of these directly via `System.get_env/1` or `LemonCore.Config.Helpers`; migrating them to `LemonCore.Env.get/2` is tracked as follow-up work (see "Migration order" below). New code should prefer `LemonCore.Env.get/2` for anything declared here, and add a declaration for anything new.

Regenerate the tables from the umbrella root with
`mix run --no-start scripts/generate_config_registry.exs`; add `--check` to
detect drift without writing. The generator starts no applications and reads
declaration metadata only, never environment values or secret stores.

## Naming convention

- **New variables MUST be named `LEMON_<AREA>_<NAME>`** (e.g. `LEMON_GATEWAY_MAX_CONCURRENT_RUNS`, `LEMON_ARENA_<DOMAIN>_MODELS`). This keeps `LEMON_`-prefixed variables greppable and namespaced away from third-party tooling.
- **Provider/vendor credentials keep their ecosystem-standard names** and are not renamed to the `LEMON_` scheme -- e.g. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `AWS_ACCESS_KEY_ID`, `GOOGLE_APPLICATION_CREDENTIALS`, `TWILIO_ACCOUNT_SID`. Renaming these would break compatibility with the SDKs/CLIs/docs the ecosystem already documents them against.
- **Standard platform/BEAM release variables are never renamed** -- `HOME`, `SHELL`, `TERM`, `MIX_ENV`, `RELEASE_NAME`, `RELEASE_NODE`, `RELEASE_VSN`, `PHX_SERVER`.
- Every other pre-existing non-conforming name below is **grandfathered** and listed with its conforming replacement (if one exists) as an `aliases:` entry in its `LemonCore.Env` declaration -- the conforming name is checked first, then the legacy name, so existing deployments keep working. Grandfathered names in this registry: `VOICE_PUBLIC_URL`, `VOICE_RECORDINGS_DIR`, `WEREWOLF_ARENA_MODELS` / `WEREWOLF_ARENA_ENABLED` / `WEREWOLF_ARENA_PLAYER_COUNT` / `WEREWOLF_ARENA_GAME_DELAY_MS` / `WEREWOLF_LEAGUE_DIR` (superseded by the generalized `LEMON_ARENA_WEREWOLF_*` names), `LEMON_OPENAI_COMPAT_TOKEN` (superseded by `LEMON_OPENAI_COMPAT_API_TOKEN`), `LEMON_OPENAI_COMPAT_IMAGE_HOST_ALLOWLIST` (superseded by `LEMON_OPENAI_COMPAT_IMAGE_URL_ALLOWED_HOSTS`), `LEMON_GATEWAY_COOKIE` (superseded by `LEMON_GATEWAY_NODE_COOKIE`), and the `INTEGRATION_*` / legacy `ANTHROPIC_API_KEY` fallbacks for the `LEMON_EVAL_*` family.

## Secrets

Variables flagged `secret` below hold credentials or tokens. `LemonCore.Env.snapshot/0` resolves every declared variable's current value for reporting/diagnostics tooling, and its `Inspect` output (`LemonCore.Env.Resolved`) redacts any `secret` value automatically -- so it's safe to `IO.inspect/1` or log a snapshot without leaking a credential.

## Migration order (proposed)

Call-site migration to `LemonCore.Env.get/2` is out of scope for this pass and is tracked as follow-up work. Suggested order, roughly least-to-most risky:

1. `LemonCore.Config.*` modules (`Agent`, `Tools`, `Gateway`, `Logging`, `TUI`) -- already funnel through `LemonCore.Config.Helpers`, so swapping the call site is mechanical and low-risk.
2. Single-app leaf config (`lemon_browser`, `lemon_skills`, `lemon_evals`, terminal backends) -- self-contained modules with few callers.
3. `config/runtime.exs` -- the always-on arena block and prod endpoint block are dynamic (`LEMON_ARENA_<DOMAIN>_<SUFFIX>`, `<PREFIX>_{HOST,PORT,SECRET_KEY_BASE}`); migrate once `LemonCore.Env` gets a documented pattern for iterating a family of declared names.
4. Provider credential resolution (`LemonAgent.ProviderConfigResolver`, `LemonAgent.ModelRuntime.Credentials`) -- highest blast radius (every provider call), migrate last and behind the existing `architecture_rules_check.ex` boundary tests.

## Variables by area

### Agent

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_BASE_DELAY_MS` | integer | `1000` |  | `lemon_core` | Base backoff delay (ms) between retry attempts. |
| `LEMON_BUDGET_MAX_CHILDREN` | integer | `5` |  | `lemon_core` | Default max concurrent delegated sub-agent children per run. |
| `LEMON_COMPACTION_ENABLED` | boolean | `true` |  | `lemon_core` | Whether context compaction runs automatically as the transcript grows. |
| `LEMON_COMPACTION_KEEP_RECENT_TOKENS` | integer | `20000` |  | `lemon_core` | Recent-token window kept verbatim (uncompacted) at the tail of the transcript. |
| `LEMON_COMPACTION_RESERVE_TOKENS` | integer | `16384` |  | `lemon_core` | Token budget reserved (not compacted away) during compaction. |
| `LEMON_DEFAULT_MODEL` | string | `claude-sonnet-4-20250514` |  | `lemon_core` | Default model id used when no per-run model is specified. |
| `LEMON_DEFAULT_PROVIDER` | string | `anthropic` |  | `lemon_core` | Default LLM provider id used when no per-run provider is specified. |
| `LEMON_DEFAULT_THINKING_LEVEL` | string | `medium` |  | `lemon_core` | Default reasoning/thinking effort level for the agent loop. |
| `LEMON_EXTENSIONS_AUTO_LOAD_DEFAULT_PATHS` | boolean | `false` |  | `lemon_core` | Whether default extension search paths are auto-loaded. |
| `LEMON_EXTENSIONS_ENABLED` | boolean | `true` |  | `lemon_core` | Whether the extensions subsystem is enabled. |
| `LEMON_EXTENSION_PATHS` | list (comma-separated) | `[]` |  | `lemon_core` | Comma-separated list of extra extension directories to load. |
| `LEMON_MAX_RETRIES` | integer | `3` |  | `lemon_core` | Maximum retry attempts for a failing LLM call. |
| `LEMON_PROVIDER_FALLBACK_PROVIDERS` | list (comma-separated) | `[]` |  | `lemon_core` | Comma-separated fallback provider ids tried after the primary provider fails. |
| `LEMON_PROVIDER_ROUTING_DEFAULT_POOL` | string | _(none)_ |  | `lemon_core` | Default credential pool name used for provider routing. |
| `LEMON_PROVIDER_ROUTING_DEFAULT_PROFILE` | string | _(none)_ |  | `lemon_core` | Default provider routing profile name. |
| `LEMON_PROVIDER_ROUTING_ENABLED` | boolean | `true` |  | `lemon_core` | Whether multi-provider routing/fallback is enabled. |
| `LEMON_PROVIDER_ROUTING_REQUIRE_CREDENTIALS` | boolean | `true` |  | `lemon_core` | Whether provider routing requires resolvable credentials before selecting a provider. |
| `LEMON_RETRY_ENABLED` | boolean | `true` |  | `lemon_core` | Whether transient LLM call failures are retried. |
| `LEMON_SECRET_OBFUSCATION_ENABLED` | boolean | `false` |  | `lemon_core` | Whether secrets are replaced with placeholders in provider-visible session text. |
| `LEMON_SHELL_COMMAND_PREFIX` | string | _(none)_ |  | `lemon_core` | Command prefix prepended to every shell tool invocation. |
| `LEMON_SHELL_PATH` | string | _(none)_ |  | `lemon_core` | Shell executable path used by the bash/shell tool. |

### Ai diagnostics

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_AI_DEBUG` | boolean | `false` |  | `lemon_ai` | Whether raw Anthropic SSE traffic is logged to a debug file. |
| `LEMON_AI_DEBUG_FILE` | string | `/tmp/lemon_anthropic_sse.log` |  | `lemon_ai` | File path used for Anthropic SSE debug logging. |
| `LEMON_AI_HTTP_TRACE` | boolean | `false` |  | `lemon_ai` | Whether low-level HTTP request/response tracing is enabled for provider calls. |
| `LEMON_AI_PROMPT_DIAGNOSTICS` | boolean | `false` |  | `lemon_ai` | Whether prompt diagnostics logging is enabled. |
| `LEMON_AI_PROMPT_DIAGNOSTICS_LOG_LEVEL` | string | _(none)_ |  | `lemon_ai` | Log level used for prompt diagnostics output. |
| `LEMON_AI_PROMPT_DIAGNOSTICS_TOP_N` | integer | _(none)_ |  | `lemon_ai` | Number of top prompt-diagnostics entries to report. |
| `LEMON_KIMI_MAX_REQUEST_MESSAGES` | integer | _(none)_ |  | `lemon_ai` | Kimi message-count preflight compaction hint; provider requests preserve full history. |
| `PI_CACHE_RETENTION` | string | _(none)_ |  | `lemon_ai` | When set to "long", requests 24h prompt-cache retention from OpenAI-compatible providers. |

### Arena

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_ARENA_LEAGUE_ROOT` | string | _(none)_ |  | `lemon_sim_ui` | Root directory under which each arena domain's league dir defaults to `<domain>_league`; must be absolute for the production sim UI. |
| `LEMON_ARENA_POKER_ENABLED` | boolean | `true` |  | `lemon_sim_ui` | Whether the poker arena is enabled (only checked once MODELS is set). |
| `LEMON_ARENA_POKER_GAME_DELAY_MS` | integer | _(none)_ |  | `lemon_sim_ui` | Delay between games (ms) for the poker arena. |
| `LEMON_ARENA_POKER_LEAGUE_DIR` | string | _(none)_ |  | `lemon_sim_ui` | League standings directory for the poker arena. |
| `LEMON_ARENA_POKER_MODELS` | list (comma-separated) | `[]` |  | `lemon_sim_ui` | Comma-separated provider:model specs enabling the poker arena. |
| `LEMON_ARENA_POKER_PLAYER_COUNT` | integer | _(none)_ |  | `lemon_sim_ui` | Player count for the poker arena. |
| `LEMON_ARENA_WEREWOLF_ENABLED`<br>_(alias: `WEREWOLF_ARENA_ENABLED`)_ | boolean | `true` |  | `lemon_sim_ui` | Whether the werewolf arena is enabled (only checked once MODELS is set). |
| `LEMON_ARENA_WEREWOLF_GAME_DELAY_MS`<br>_(alias: `WEREWOLF_ARENA_GAME_DELAY_MS`)_ | integer | _(none)_ |  | `lemon_sim_ui` | Delay between games (ms) for the werewolf arena. |
| `LEMON_ARENA_WEREWOLF_LEAGUE_DIR`<br>_(alias: `WEREWOLF_LEAGUE_DIR`)_ | string | _(none)_ |  | `lemon_sim_ui` | League standings directory for the werewolf arena. |
| `LEMON_ARENA_WEREWOLF_MODELS`<br>_(alias: `WEREWOLF_ARENA_MODELS`)_ | list (comma-separated) | `[]` |  | `lemon_sim_ui` | Comma-separated provider:model specs enabling the werewolf arena. |
| `LEMON_ARENA_WEREWOLF_PLAYER_COUNT`<br>_(alias: `WEREWOLF_ARENA_PLAYER_COUNT`)_ | integer | _(none)_ |  | `lemon_sim_ui` | Player count for the werewolf arena. |
| `LEMON_GOAL_JUDGE_MODEL` | string | _(none)_ |  | `lemon_automation` | Model id used to judge automation goal completion. |
| `LEMON_SIM_AUTO_LOOP` | boolean | `false` |  | `lemon_sim_ui` | Whether the werewolf auto-loop starts automatically on boot. |
| `LEMON_SIM_WEREWOLF_PLAYERS` | integer | `6` |  | `lemon_sim_ui` | Player count for the werewolf auto-loop. |

### Automation

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_CRON_ADMISSION_ALLOWED_ORIGINS` | string | _(none)_ |  | `lemon_automation` | Comma-separated exact origins allowed for private cron admission callbacks; HTTPS or literal-loopback HTTP only. |
| `LEMON_CRON_DRIFT_GUARD_ENABLED` | boolean | _(none)_ |  | `lemon_automation` | Override the cron model drift guard (fail closed when the global default model changed under an unpinned job). |
| `LEMON_CRON_PREFLIGHT_ENABLED` | boolean | _(none)_ |  | `lemon_automation` | Override the cron pre-dispatch preflight (provider/target readiness) toggle. |

### Browser

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `BROWSERBASE_API_KEY` | string | _(none)_ | yes | `lemon_browser` | Browserbase API key for hosted browser sessions. |
| `BROWSERBASE_PROJECT_ID` | string | _(none)_ |  | `lemon_browser` | Browserbase project id for hosted browser sessions. |
| `BROWSER_USE_API_KEY` | string | _(none)_ | yes | `lemon_browser` | Browser Use Cloud API key for hosted browser sessions. |
| `CAMOFOX_API_KEY` | string | _(none)_ | yes | `lemon_browser` | Optional bearer key for the configured Camofox server. |
| `CAMOFOX_URL` | string | _(none)_ |  | `lemon_browser` | Base URL for a Camofox REST/Firefox browser server. |
| `LEMON_BROWSER_ATTACH_ONLY` | boolean | `false` |  | `lemon_browser` | Whether the browser tool only attaches to an existing browser instead of launching one. |
| `LEMON_BROWSER_BACKEND` | string | `local` |  | `lemon_browser` | Browser backend id: local, controller, hybrid, browserbase, browser_use, firecrawl, or camofox. |
| `LEMON_BROWSER_CDP_ENDPOINT` | string | _(none)_ |  | `lemon_browser` | Chrome DevTools Protocol websocket endpoint to attach to instead of launching a browser. |
| `LEMON_BROWSER_CDP_PORT` | integer | `18800` |  | `lemon_browser` | Local CDP port used when launching a managed browser instance. Only positive integers are accepted (0/negative/unparseable fall back to the default); resolved with a bespoke parser in LemonBrowser.LocalServer, not the standard :integer cast. |
| `LEMON_BROWSER_DRIVER_PATH` | string | _(none)_ |  | `lemon_browser` | Path to the browser automation driver binary. |
| `LEMON_BROWSER_HYBRID_LOCAL_BACKEND` | string | `local` |  | `lemon_browser` | Local/private backend selected by the hybrid browser router. |
| `LEMON_BROWSER_HYBRID_PUBLIC_BACKEND` | string | _(none)_ |  | `lemon_browser` | Explicit hosted backend selected by the hybrid router for public URLs. |
| `LEMON_BROWSER_RELAY_PORT` | integer | `9224` |  | `lemon_browser` | Loopback port for the Manifest V3 existing-Chrome relay. |
| `LEMON_BROWSER_RELAY_TOKEN` | string | _(none)_ | yes | `lemon_browser` | Required shared secret for the loopback extension and CDP relay. |

### Computer use

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_BOT_PUBLIC_URL` | string | _(none)_ |  | `lemon_computer_use` | The Lemon Bot backend's public origin (owned by the Lemon Bot backend); computer use declines it because its web client shows approvals. |
| `LEMON_COMPUTER_USE_CHROME` | boolean | `false` |  | `lemon_computer_use` | Also control Chrome tabs (lcu --chrome) through the official ChatGPT extension; requires `lcu browser install`. |
| `LEMON_COMPUTER_USE_DECLINED_ORIGINS` | string | _(none)_ |  | `lemon_computer_use` | Comma-separated website origins computer use always declines (for example a custom Lemon Bot web origin). |
| `LEMON_COMPUTER_USE_ENABLED` | boolean | `false` |  | `lemon_computer_use` | Opt in to native app control (`cua_js`/`cua_js_reset`) through the locally installed LCU runtime. |
| `LEMON_COMPUTER_USE_LCU_ROOT` | string | _(none)_ |  | `lemon_computer_use` | Installed LCU release directory. Defaults to ~/.local/share/lcu/current (or /opt/lcu/current). |
| `LEMON_COMPUTER_USE_NODE` | string | _(none)_ |  | `lemon_computer_use` | Node runtime for the LCU bridge. Defaults to LCU's own <root>/agent-tools/node/bin/node. |

### Endpoints

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_A2A_HOST` | string | _(none)_ |  | `lemon_control_plane` | Host address for the A2A peer listener. |
| `LEMON_A2A_MAX_CONTEXT_TURNS` | integer | _(none)_ |  | `lemon_control_plane` | Maximum accepted inbound turns per A2A context. |
| `LEMON_A2A_PORT` | integer | _(none)_ |  | `lemon_control_plane` | Port for the A2A peer listener. |
| `LEMON_A2A_PUBLIC_URL` | string | _(none)_ |  | `lemon_control_plane` | Public A2A JSON-RPC URL advertised in Lemon's Agent Card. |
| `LEMON_A2A_RATE_LIMIT_PER_MINUTE` | integer | _(none)_ |  | `lemon_control_plane` | Per-peer A2A JSON-RPC request limit per minute. |
| `LEMON_A2A_REPLY_TIMEOUT_MS` | integer | _(none)_ |  | `lemon_control_plane` | Maximum synchronous wait for an A2A peer run. |
| `LEMON_ACP_API_TOKEN` | string | _(none)_ | yes | `lemon_control_plane` | Bearer token required for the ACP (agent control protocol) HTTP API. |
| `LEMON_AGENT_PROFILES_CWD` | string | _(none)_ |  | `lemon_router` | Working directory override used to resolve router agent profiles. |
| `LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK` | boolean | `false` |  | `lemon_control_plane` | Explicitly allow legacy tokenless WebSocket operator access from direct loopback peers. |
| `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` | string | _(none)_ | yes | `lemon_control_plane` | Shared operator credential required by control-plane WebSocket operator connections. |
| `LEMON_CONTROL_PLANE_PORT` | integer | _(none)_ |  | `lemon_control_plane` | Port the control-plane HTTP server listens on. |
| `LEMON_GATEWAY_ENABLE_A2A` | boolean | `false` |  | `lemon_control_plane` | Enable the A2A peer listener. |
| `LEMON_GATEWAY_HEALTH_PORT` | integer | _(none)_ |  | `lemon_gateway` | Port the gateway health-check endpoint listens on. |
| `LEMON_OPENAI_COMPAT_API_TOKEN`<br>_(alias: `LEMON_OPENAI_COMPAT_TOKEN`)_ | string | _(none)_ | yes | `lemon_control_plane` | Bearer token required for the OpenAI-compatible HTTP API. |
| `LEMON_OPENAI_COMPAT_IMAGE_URL_ALLOWED_HOSTS`<br>_(alias: `LEMON_OPENAI_COMPAT_IMAGE_HOST_ALLOWLIST`)_ | list (comma-separated) | `[]` |  | `lemon_control_plane` | Comma-separated hostname allowlist for OpenAI-compat image URL fetch. |
| `LEMON_OPENAI_COMPAT_IMAGE_URL_FETCH` | boolean | `false` |  | `lemon_control_plane` | Whether the OpenAI-compat endpoint is allowed to fetch image URLs from messages. |
| `LEMON_ROUTER_HEALTH_PORT` | integer | _(none)_ |  | `lemon_router` | Port the router health-check endpoint listens on. |
| `LEMON_SIM_UI_ACCESS_TOKEN` | string | _(none)_ | yes | `lemon_sim_ui` | Admin token; required with at least 32 bytes for a production Sim UI endpoint. |
| `LEMON_SIM_UI_BIND_IP` | string | `127.0.0.1` |  | `lemon_sim_ui` | Bind IP address for the LemonSimUi dev endpoint. |
| `LEMON_SIM_UI_HOST` | string | `localhost` |  | `lemon_sim_ui` | Public hostname for the LemonSimUi prod endpoint; explicit in production. |
| `LEMON_SIM_UI_PORT` | integer | `4090` |  | `lemon_sim_ui` | Port LemonSimUi listens on. |
| `LEMON_SIM_UI_PUBLIC_VENDING_LAUNCHER` | boolean | `false` |  | `lemon_sim_ui` | Whether the public VendingBench launcher page is exposed. |
| `LEMON_SIM_UI_SECRET_KEY_BASE` | string | _(none)_ | yes | `lemon_sim_ui` | Phoenix secret_key_base; required with at least 64 bytes for a production Sim UI endpoint. |
| `LEMON_SIM_UI_SUITE_ROOTS` | list (comma-separated) | `[]` |  | `lemon_sim_ui` | Colon-separated extra suite root directories for LemonSimUi. |
| `LEMON_SIM_UI_URL_PORT` | integer | `443` |  | `lemon_sim_ui` | Public URL port for generated LemonSimUi links. |
| `LEMON_SIM_UI_URL_SCHEME` | string | `https` |  | `lemon_sim_ui` | Public URL scheme for generated LemonSimUi links (http or https). |
| `LEMON_WEB_HOST` | string | `localhost` |  | `lemon_web` | Public hostname for the LemonWeb prod endpoint. |
| `LEMON_WEB_PORT` | integer | `4080` |  | `lemon_web` | Port LemonWeb listens on. |
| `LEMON_WEB_SECRET_KEY_BASE` | string | _(none)_ | yes | `lemon_web` | Phoenix secret_key_base for the LemonWeb prod endpoint. |
| `LEMON_WEB_UPLOADS_DIR` | string | _(none)_ |  | `lemon_web` | Directory used for LemonWeb file uploads. |
| `LEMON_WEB_URL_PORT` | integer | `443` |  | `lemon_web` | Public URL port for generated LemonWeb links. |
| `LEMON_WEB_URL_SCHEME` | string | `https` |  | `lemon_web` | Public URL scheme for generated LemonWeb links (http or https). |
| `PHX_SERVER` | boolean | `false` |  | `lemon_web`, `lemon_sim_ui` | Standard Phoenix flag to start the HTTP server in a release (ecosystem-standard name). |

### Error reporting

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `SENTRY_DSN` | string | _(none)_ | yes | `lemon_core` | Sentry DSN; error reporting is dormant unless this is set. |
| `SENTRY_ENVIRONMENT` | string | _(none)_ |  | `lemon_core` | Sentry environment name override (falls back to LEMON_ENV, then Mix env). |

### Evals live

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_EVAL_API_KEY`<br>_(alias: `INTEGRATION_API_KEY`, `ANTHROPIC_API_KEY`)_ | string | _(none)_ | yes | `lemon_evals` | Live-eval provider API key. |
| `LEMON_EVAL_API_KEY_SECRET`<br>_(alias: `INTEGRATION_API_KEY_SECRET`)_ | string | _(none)_ | yes | `lemon_evals` | Secrets-store key name resolving to the live-eval API key. |
| `LEMON_EVAL_API_TYPE`<br>_(alias: `INTEGRATION_API_TYPE`)_ | string | _(none)_ |  | `lemon_evals` | Live-eval `LemonAi.Types.Model.api` atom override (default: anthropic_messages). |
| `LEMON_EVAL_BASE_URL`<br>_(alias: `INTEGRATION_BASE_URL`)_ | string | _(none)_ |  | `lemon_evals` | Live-eval API base URL override. |
| `LEMON_EVAL_MODEL`<br>_(alias: `INTEGRATION_MODEL`)_ | string | _(none)_ |  | `lemon_evals` | Live-eval model id (default: kimi-for-coding). |
| `LEMON_EVAL_PROVIDER`<br>_(alias: `INTEGRATION_PROVIDER`)_ | string | _(none)_ |  | `lemon_evals` | Live-eval provider atom override (default: kimi). |

### Execution nodes

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_CONTROL_PLANE_PUBLIC_WS_URL` | string | _(none)_ |  | `lemon_control_plane` | Reachable secure control-plane WebSocket URL embedded in node invitations; ws is allowed only for loopback. |
| `LEMON_NODE_INSTALL_BASE_URL` | string | _(none)_ |  | `lemon_control_plane` | HTTPS operator-supported pinned node artifact base URL passed to the existing installer; never defaults to published artifacts. |
| `LEMON_NODE_INSTALL_VERSION` | string | _(none)_ |  | `lemon_control_plane` | Exact operator-supported node artifact CalVer; requires an HTTPS node install base URL and actual feature checks. |
| `LEMON_NODE_SOURCE_CHECKOUT` | string | _(none)_ |  | `lemon_control_plane` | Absolute destination-local integrated source checkout used by node invite commands. |

### Gateway

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `DISCORD_BOT_TOKEN` | string | _(none)_ | yes | `lemon_channels` | Discord bot token (ecosystem-standard name). |
| `LEMON_GATEWAY_AUTO_RESUME` | boolean | `false` |  | `lemon_core`, `lemon_gateway` | Whether the gateway auto-resumes interrupted runs on boot. |
| `LEMON_GATEWAY_DEFAULT_CWD` | string | _(none)_ |  | `lemon_core`, `lemon_gateway` | Default working directory for gateway-initiated runs. |
| `LEMON_GATEWAY_ENABLE_DISCORD` | boolean | `false` |  | `lemon_channels` | Whether the Discord transport is enabled. |
| `LEMON_GATEWAY_ENABLE_TELEGRAM` | boolean | `false` |  | `lemon_channels` | Whether the Telegram transport is enabled. |
| `LEMON_GATEWAY_ENABLE_WEBHOOK` | boolean | `false` |  | `lemon_core`, `lemon_gateway` | Whether the generic webhook transport is enabled. |
| `LEMON_GATEWAY_ENABLE_XMTP` | boolean | `false` |  | `lemon_channels` | Whether the XMTP transport is enabled. |
| `LEMON_GATEWAY_ENGINE_LOCK_TIMEOUT_MS` | integer | `60000` |  | `lemon_core`, `lemon_gateway` | Engine lock acquisition timeout, in milliseconds. |
| `LEMON_GATEWAY_MAX_CONCURRENT_RUNS` | integer | `2` |  | `lemon_core`, `lemon_gateway` | Maximum concurrent agent runs the gateway will schedule. |
| `LEMON_GATEWAY_REQUIRE_ENGINE_LOCK` | boolean | `true` |  | `lemon_core`, `lemon_gateway` | Whether an engine lock is required before starting a gateway run. |
| `LEMON_LOCK_DIR` | string | _(none)_ |  | `lemon_channels` | Directory used for gateway/channel file locks. |
| `LEMON_TELEGRAM_COMPACTION_CONTEXT_WINDOW` | integer | `400000` |  | `lemon_channels` | Context window size (tokens) used for Telegram compaction triggers. |
| `LEMON_TELEGRAM_COMPACTION_ENABLED` | boolean | `true` |  | `lemon_channels` | Whether Telegram session transcripts are auto-compacted. |
| `LEMON_TELEGRAM_COMPACTION_RESERVE_TOKENS` | integer | `16384` |  | `lemon_channels` | Token budget reserved during Telegram session compaction. |
| `LEMON_TELEGRAM_COMPACTION_TRIGGER_RATIO` | float | `0.9` |  | `lemon_channels` | Context-window fill ratio that triggers Telegram compaction. |
| `LEMON_TELEGRAM_POLLER_LOCK_STALE_MS` | integer | _(none)_ |  | `lemon_channels` | Age (ms) after which a Telegram poller lock is considered stale and reclaimed. |

### Gateway sms

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_SMS_INBOX_TTL_MS` | integer | _(none)_ |  | `lemon_gateway` | TTL (ms) for deduplicated inbound SMS message tracking. |
| `LEMON_SMS_WEBHOOK_BIND` | string | _(none)_ |  | `lemon_gateway` | Bind address for the SMS webhook server. |
| `LEMON_SMS_WEBHOOK_ENABLED` | boolean | _(none)_ |  | `lemon_gateway` | Whether the inbound SMS webhook server is enabled. |
| `LEMON_SMS_WEBHOOK_PORT` | integer | _(none)_ |  | `lemon_gateway` | Port the SMS webhook server listens on. |
| `TWILIO_ACCOUNT_SID` | string | _(none)_ | yes | `lemon_gateway` | Twilio account SID (ecosystem-standard name, grandfathered). |
| `TWILIO_AUTH_TOKEN` | string | _(none)_ | yes | `lemon_gateway` | Twilio auth token (ecosystem-standard name, grandfathered). |
| `TWILIO_INBOX_NUMBER` | string | _(none)_ |  | `lemon_gateway` | Twilio inbox phone number used for inbound SMS routing. |
| `TWILIO_PHONE_NUMBER` | string | _(none)_ |  | `lemon_gateway` | Twilio sending phone number (ecosystem-standard name, grandfathered). |
| `TWILIO_VALIDATE_WEBHOOK` | boolean | `true` |  | `lemon_gateway` | Whether inbound Twilio webhook signatures are validated. |
| `TWILIO_WEBHOOK_URL` | string | _(none)_ |  | `lemon_gateway` | Public URL Twilio uses to reach the SMS webhook. |

### Gateway voice

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `DEEPGRAM_API_KEY` | string | _(none)_ | yes | `lemon_gateway` | Deepgram API key for voice transcription (ecosystem-standard name). |
| `ELEVENLABS_API_KEY` | string | _(none)_ | yes | `lemon_gateway` | ElevenLabs API key for voice synthesis (ecosystem-standard name). |
| `ELEVENLABS_VOICE_ID` | string | `21m00Tcm4TlvDq8ikWAM` |  | `lemon_gateway` | ElevenLabs voice id used for voice synthesis. |
| `VOICE_PUBLIC_URL` | string | _(none)_ |  | `lemon_gateway` | Public URL for the voice websocket endpoint (grandfathered, no LEMON_ prefix). |
| `VOICE_RECORDINGS_DIR` | string | _(none)_ |  | `lemon_gateway` | Directory where downloaded call recordings are stored. |

### Honcho

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `HONCHO_AI_PEER` | string | `lemon` |  | `lemon_honcho` | Peer id representing the assistant side of the conversation. |
| `HONCHO_API_KEY` | string | _(none)_ | yes | `lemon_honcho` | Honcho API key. Presence of this (or HONCHO_BASE_URL) enables the integration. |
| `HONCHO_BASE_URL` | string | _(none)_ |  | `lemon_honcho` | Base URL of the Honcho API. Set this to point at a self-hosted deployment. |
| `HONCHO_ENVIRONMENT` | string | `production` |  | `lemon_honcho` | Honcho deployment to talk to when no base URL is given (production, demo, local). |
| `HONCHO_PEER` | string | _(none)_ |  | `lemon_honcho` | Peer id representing the human. Defaults to the sanitized $USER, then "user". |
| `HONCHO_TIMEOUT_MS` | integer | `30000` |  | `lemon_honcho` | Timeout for one attempt at a Honcho HTTP call, in milliseconds. A turn-path call may retry a transient failure twice; the diagnostics in `mix lemon.honcho` do not, so there it is the whole bound. |
| `HONCHO_WORKSPACE` | string | `lemon` |  | `lemon_honcho` | Honcho workspace that owns every peer, session and conclusion Lemon writes. |
| `LEMON_HONCHO_CONTEXT_CADENCE` | integer | `1` |  | `lemon_honcho` | Refresh the injected session context every N turns (1 = every turn). |
| `LEMON_HONCHO_CONTEXT_TOKENS` | integer | _(none)_ |  | `lemon_honcho` | Token budget asked of Honcho for session context. Unset lets Honcho decide. |
| `LEMON_HONCHO_DIALECTIC_CADENCE` | integer | `2` |  | `lemon_honcho` | Run the (slower, reasoned) dialectic query every N turns. |
| `LEMON_HONCHO_DIALECTIC_MAX_CHARS` | integer | `600` |  | `lemon_honcho` | Hard cap on the dialectic answer spliced into the prompt, in characters. |
| `LEMON_HONCHO_ENABLED` | boolean | `true` |  | `lemon_honcho` | Master switch, on by default: a key or base URL alone activates the integration. Set false to ignore a key that stays exported. |
| `LEMON_HONCHO_FIRST_TURN_WAIT_MS` | integer | `3000` |  | `lemon_honcho` | How long a session's cold first turn may block waiting for memory. The value plus a 200ms margin is clamped to prompt assembly's 3000ms contributor ceiling, so values above 2800 buy no more time; 0 disables the wait. |
| `LEMON_HONCHO_INJECT_IN_SUBAGENTS` | boolean | `false` |  | `lemon_honcho` | Whether subagent runs also get memory injected. Off by default; subagents are cheap. |
| `LEMON_HONCHO_MESSAGE_MAX_CHARS` | integer | `25000` |  | `lemon_honcho` | Per-message truncation applied before a turn is uploaded to Honcho. |
| `LEMON_HONCHO_OBSERVATION_MODE` | string | `directional` |  | `lemon_honcho` | Peer observation preset: directional (both peers observe) or unified (one model). |
| `LEMON_HONCHO_PIN_USER_PEER` | boolean | `false` |  | `lemon_honcho` | Use the configured human peer for every channel sender. |
| `LEMON_HONCHO_REASONING_LEVEL` | string | `low` |  | `lemon_honcho` | Reasoning budget Honcho spends on dialectic queries: minimal, low, medium, high, max. |
| `LEMON_HONCHO_RECALL_MODE` | string | `hybrid` |  | `lemon_honcho` | How memory reaches the model: hybrid (injection + tools), context (injection only; the honcho_* tools are inactive), or tools (tools only; nothing injected). |
| `LEMON_HONCHO_RUNTIME_PEER_PREFIX` | string | `` |  | `lemon_honcho` | Prefix for channel-qualified sender peer ids; empty keeps the configured peer. |
| `LEMON_HONCHO_SAVE_MESSAGES` | boolean | `true` |  | `lemon_honcho` | Whether turns are written back to Honcho. False makes the integration read-only: no uploads, and the profile write and conclusion create/delete are refused. |
| `LEMON_HONCHO_SESSION_STRATEGY` | string | `per-directory` |  | `lemon_honcho` | What a Honcho session maps to: per-session, per-directory, per-repo, or global. |
| `LEMON_HONCHO_USER_PEER_ALIASES` | string | _(none)_ |  | `lemon_honcho` | JSON map of channel-qualified runtime ids to Honcho peer ids. |

### Logging

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_LOG_COMPRESS_ON_ROTATE` | boolean | _(none)_ |  | `lemon_core` | Whether rotated log files are gzip-compressed. |
| `LEMON_LOG_FILE` | string | _(none)_ |  | `lemon_core` | Path to the log file (nil disables file logging). |
| `LEMON_LOG_FILESYNC_REPEAT_INTERVAL` | integer | _(none)_ |  | `lemon_core` | Log file sync interval, in milliseconds. |
| `LEMON_LOG_LEVEL` | string | _(none)_ |  | `lemon_core` | Global log level override (debug/info/notice/warning/error/critical/alert/emergency). |
| `LEMON_LOG_MAX_NO_BYTES` | integer | _(none)_ |  | `lemon_core` | Log file rotation size threshold, in bytes. Plain integer only -- unlike LEMON_WASM_DEFAULT_MEMORY_LIMIT, this one does not accept "10MB"-style suffixes. |
| `LEMON_LOG_MAX_NO_FILES` | integer | _(none)_ |  | `lemon_core` | Number of rotated log files retained. |

### Omp

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_OMP_APPROVALS` | string | `bridge` |  | `lemon_omp` | Tool approval prompts: bridge to Lemon approvals (default), or decline. |
| `LEMON_OMP_APPROVAL_TIMEOUT_MS` | integer | `600000` |  | `lemon_omp` | Maximum wait for an omp tool approval, capped by the omp dialog timeout. |
| `LEMON_OMP_BIN` | string | _(none)_ |  | `lemon_omp` | Path or name of the omp executable. Defaults to the first `omp` on PATH. |
| `LEMON_OMP_IDLE_TIMEOUT_MS` | integer | `1800000` |  | `lemon_omp` | Close an idle omp process after this many milliseconds (0 disables). Sessions stay resumable. |
| `LEMON_OMP_MAX_SESSIONS` | integer | `4` |  | `lemon_omp` | Maximum number of live omp processes Lemon supervises at once. |
| `LEMON_OMP_SESSION_DIR` | string | _(none)_ |  | `lemon_omp` | Lemon's omp history directory (default: Lemon state dir/omp/sessions). Set to omp to use omp's own default. |
| `PI_CODING_AGENT_DIR` | string | _(none)_ |  | `lemon_omp` | omp's agent directory; Lemon reads `<dir>/sessions` for read-only session discovery. |
| `PI_CONFIG_DIR` | string | `.omp` |  | `lemon_omp` | omp's config directory name under HOME, used when PI_CODING_AGENT_DIR is unset. |

### Platform

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `HOME` | string | _(none)_ |  | `lemon_core`, `lemon_ai`, `coding_agent` | Standard POSIX home directory; used for default `.lemon` locations and OAuth token caches. |
| `MIX_ENV` | string | _(none)_ |  | `lemon_core` | Standard Mix environment (dev/test/prod). |
| `RELEASE_NAME` | string | _(none)_ |  | `lemon_core` | Standard Elixir release name; selects which endpoint(s) boot in a multi-app release. |
| `RELEASE_NODE` | string | _(none)_ |  | `lemon_core` | Standard Elixir release node name; presence indicates a running release (vs. `mix`). |
| `RELEASE_VSN` | string | _(none)_ |  | `lemon_core` | Standard Elixir release version. |
| `SHELL` | string | `/bin/sh` |  | `lemon_sim` | Standard POSIX shell path, used as a fallback shell for the external decider. |
| `TERM` | string | _(none)_ |  | `lemon_cli` | Standard terminal type variable; used to detect non-interactive/dumb terminals. |

### Provider

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `OPENAI_BASE_URL` | string | _(none)_ |  | `lemon_ai` | OpenAI API base URL override (ecosystem-standard name). |

### Provider secrets

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `ANTHROPIC_API_KEY` | string | _(none)_ | yes | `lemon_ai` | Anthropic API key. |
| `AWS_ACCESS_KEY_ID` | string | _(none)_ | yes | `lemon_core`, `lemon_agent` | AWS access key id for Bedrock (ecosystem-standard name). |
| `AWS_DEFAULT_REGION` | string | _(none)_ |  | `lemon_core` | AWS region fallback (ecosystem-standard AWS CLI name). |
| `AWS_PROFILE` | string | _(none)_ |  | `lemon_agent` | Named AWS CLI credentials profile to resolve Bedrock credentials from. |
| `AWS_REGION` | string | `us-east-1` |  | `lemon_core` | AWS region for Bedrock (ecosystem-standard name). |
| `AWS_SECRET_ACCESS_KEY` | string | _(none)_ | yes | `lemon_core`, `lemon_agent` | AWS secret access key for Bedrock (ecosystem-standard name). |
| `AWS_SESSION_TOKEN` | string | _(none)_ | yes | `lemon_core` | AWS temporary session token for Bedrock (ecosystem-standard name). |
| `AZURE_OPENAI_API_KEY` | string | _(none)_ | yes | `lemon_ai` | Azure OpenAI API key. |
| `AZURE_OPENAI_API_VERSION` | string | _(none)_ |  | `lemon_core` | Azure OpenAI API version. |
| `AZURE_OPENAI_BASE_URL` | string | _(none)_ |  | `lemon_core` | Azure OpenAI resource base URL. |
| `AZURE_OPENAI_DEPLOYMENT_NAME_MAP` | string | _(none)_ |  | `lemon_core` | JSON map of model id to Azure OpenAI deployment name. |
| `AZURE_OPENAI_RESOURCE_NAME` | string | _(none)_ |  | `lemon_core` | Azure OpenAI resource name. |
| `CHATGPT_TOKEN` | string | _(none)_ | yes | `lemon_ai` | ChatGPT/Codex session token (fallback for OPENAI_CODEX_API_KEY). |
| `GCLOUD_PROJECT` | string | _(none)_ |  | `lemon_ai`, `lemon_cli`, `lemon_core` | Google Cloud project id (gcloud CLI convention name). |
| `GEMINI_API_KEY` | string | _(none)_ | yes | `lemon_ai` | Gemini API key (alt name). |
| `GITHUB_COPILOT_CLIENT_ID` | string | _(none)_ |  | `lemon_ai` | GitHub Copilot OAuth client id override. |
| `GOOGLE_API_KEY` | string | _(none)_ | yes | `lemon_ai` | Google Generative AI API key (alt name). |
| `GOOGLE_APPLICATION_CREDENTIALS` | string | _(none)_ | yes | `lemon_ai`, `lemon_agent` | Path to a Google service-account JSON credentials file (ecosystem-standard name). |
| `GOOGLE_APPLICATION_CREDENTIALS_JSON` | string | _(none)_ | yes | `lemon_core` | Inline Google service-account JSON credentials. |
| `GOOGLE_CLOUD_LOCATION` | string | _(none)_ |  | `lemon_core` | Google Cloud / Vertex AI region. |
| `GOOGLE_CLOUD_PROJECT` | string | _(none)_ |  | `lemon_ai`, `lemon_cli`, `lemon_core` | Google Cloud project id (ecosystem-standard name). |
| `GOOGLE_CLOUD_PROJECT_ID` | string | _(none)_ |  | `lemon_ai`, `lemon_cli`, `lemon_core` | Google Cloud project id (alt ecosystem name). |
| `GOOGLE_GEMINI_CLI_OAUTH_CLIENT_ID` | string | _(none)_ |  | `lemon_ai` | Google Gemini CLI OAuth client id override. |
| `GOOGLE_GEMINI_CLI_OAUTH_CLIENT_SECRET` | string | _(none)_ | yes | `lemon_ai` | Google Gemini CLI OAuth client secret override. |
| `GOOGLE_GENERATIVE_AI_API_KEY` | string | _(none)_ | yes | `lemon_ai` | Google Generative AI API key (primary name). |
| `LEMON_GEMINI_PROJECT_ID` | string | _(none)_ |  | `lemon_ai`, `lemon_cli`, `lemon_core` | Lemon-specific override for the Gemini/Vertex project id, checked before the GOOGLE_CLOUD_* names. |
| `MISTRAL_API_KEY` | string | _(none)_ | yes | `lemon_ai` | Mistral API key. |
| `OPENAI_API_KEY` | string | _(none)_ | yes | `lemon_ai` | OpenAI API key. |
| `OPENAI_CODEX_API_KEY` | string | _(none)_ | yes | `lemon_ai` | OpenAI Codex API key. |
| `OPENAI_CODEX_OAUTH_CLIENT_ID` | string | _(none)_ |  | `lemon_ai` | OpenAI Codex OAuth client id override. |
| `OPENCODE_API_KEY` | string | _(none)_ | yes | `lemon_ai` | OpenCode provider API key. |

### Runtime

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `EXA_API_KEY` | string | _(none)_ | yes | `coding_agent` | Exa API key used by the registered Exa search and contents provider. |
| `LEMON_AGENT_DIR` | string | _(none)_ |  | `coding_agent`, `lemon_skills` | Override for the `.lemon` agent state directory. |
| `LEMON_ALLOW_RESTART_TOOL` | boolean | `false` |  | `coding_agent` | Whether the agent's self-restart tool is permitted to run. |
| `LEMON_DEBUG` | boolean | `false` |  | `lemon_core` | Global debug flag checked at a few call sites in addition to LEMON_LOG_LEVEL. |
| `LEMON_DOTENV_DIR` | string | _(none)_ |  | `lemon_core` | Directory to load a `.env` file from at boot. |
| `LEMON_ENV` | string | _(none)_ |  | `lemon_core` | Deployment environment label (used for Sentry environment tagging). |
| `LEMON_GATEWAY_NODE_COOKIE`<br>_(alias: `LEMON_GATEWAY_COOKIE`)_ | string | _(none)_ | yes | `lemon_core` | Distributed Erlang cookie for the gateway node. |
| `LEMON_GATEWAY_NODE_NAME` | string | `lemon` |  | `lemon_core` | Distributed Erlang node name for the gateway. |
| `LEMON_PATH` | string | _(none)_ |  | `lemon_core` | Override for the `PATH` used when locating CLI subprocess executables. |
| `LEMON_RELEASE_CHANNEL` | string | _(none)_ |  | `lemon_core` | Release channel label (stable/beta/etc), falls back to inferring from RELEASE_VSN. |
| `LEMON_RUNTIME_PROFILE` | string | _(none)_ |  | `lemon_core` | Named runtime profile selecting a bundle of feature defaults. |
| `LEMON_TEST_ALLOW_LIVE_CREDENTIALS` | boolean | `false` |  | `lemon_core` | Test-only opt-in to allow hermetic tests to use real provider credentials. |
| `PI_DEBUG` | string | _(none)_ |  | `coding_agent` | Set to 1 to enable CodingAgent.Config debug mode (DEBUG=1 also enables it). |

### Skills

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_AGENT_ID` | string | `default` |  | `lemon_skills` | Default agent id used by `mix lemon.skill` CLI operations. |
| `LEMON_HARNESS_SKILLS_DIR` | string | _(none)_ |  | `lemon_skills` | Override directory for harness/eval skill fixtures. |
| `LEMON_MCP_DISABLED` | boolean | `false` |  | `lemon_skills` | Kill switch to disable all MCP tool sources. |
| `LEMON_MCP_EXTERNAL_DISCOVERY` | boolean | `true` |  | `lemon_skills` | Set to 0/false/no to stop importing MCP servers from other tools' config files. |
| `LEMON_MCP_EXTERNAL_USER_DISCOVERY` | boolean | `false` |  | `lemon_skills` | Set to 1/true/yes to also import MCP servers from other tools' user-level (~/) configs. |
| `LEMON_MCP_SERVERS` | string | _(none)_ |  | `lemon_skills` | JSON-encoded list of MCP server configs, overriding the TOML/app config. |

### Store

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_STORE_DB_PATH` | string | _(none)_ |  | `lemon_core` | Override path for the SQLite store database file. |
| `LEMON_STORE_PATH` | string | _(none)_ |  | `lemon_core` | Override path for the primary JSONL/SQLite data store; required and absolute for the production sim UI. |

### Terminal docker

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_DOCKER_TERMINAL_CPUS` | string | _(none)_ |  | `lemon_core` | CPU limit for the Docker terminal backend container. |
| `LEMON_DOCKER_TERMINAL_IMAGE` | string | _(none)_ |  | `lemon_core` | Docker image used for the Docker terminal backend. |
| `LEMON_DOCKER_TERMINAL_MEMORY` | string | _(none)_ |  | `lemon_core` | Memory limit for the Docker terminal backend container. |
| `LEMON_DOCKER_TERMINAL_NETWORK` | string | `none` |  | `lemon_core` | Docker network mode for the Docker terminal backend container. |
| `LEMON_DOCKER_TERMINAL_PIDS_LIMIT` | string | _(none)_ |  | `lemon_core` | Process count limit for the Docker terminal backend container. |
| `LEMON_DOCKER_TERMINAL_READ_ONLY_ROOTFS` | boolean | `true` |  | `lemon_core` | Whether the Docker terminal backend mounts a read-only root filesystem. |
| `LEMON_DOCKER_TERMINAL_TMPFS_SIZE` | string | _(none)_ |  | `lemon_core` | tmpfs size for the Docker terminal backend's writable /tmp mount. |

### Terminal ssh

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_SSH_TERMINAL_CONNECT_TIMEOUT` | string | `10` |  | `lemon_core` | SSH connect timeout (seconds) for the SSH terminal backend. |
| `LEMON_SSH_TERMINAL_IDENTITY_FILE` | string | _(none)_ | yes | `lemon_core` | SSH identity (private key) file for the SSH terminal backend. |
| `LEMON_SSH_TERMINAL_PORT` | string | `22` |  | `lemon_core` | SSH port for the SSH terminal backend. |
| `LEMON_SSH_TERMINAL_STRICT_HOST_KEY_CHECKING` | string | `yes` |  | `lemon_core` | SSH StrictHostKeyChecking setting for the SSH terminal backend. |
| `LEMON_SSH_TERMINAL_TARGET` | string | _(none)_ |  | `lemon_core` | SSH target (user@host) for the SSH terminal backend. |
| `LEMON_SSH_TERMINAL_USER_KNOWN_HOSTS_FILE` | string | _(none)_ |  | `lemon_core` | Known-hosts file used by the SSH terminal backend. |
| `LEMON_SSH_TERMINAL_WORKDIR` | string | _(none)_ |  | `lemon_core` | Remote working directory for the SSH terminal backend. |

### Tools disclosure

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_TOOL_DISCLOSURE_BUDGET_TOKENS` | integer | `40000` |  | `lemon_core` | Estimated tool-schema token total above which long-tail tools are hidden behind tool_search/tool_invoke. |
| `LEMON_TOOL_DISCLOSURE_CATALOG_TOKENS` | integer | `2000` |  | `lemon_core` | Token budget for the hidden-tool catalog digest embedded in the tool_search description. |
| `LEMON_TOOL_DISCLOSURE_ENABLED` | boolean | `true` |  | `lemon_core` | Whether tool-schema progressive disclosure may activate under the selected profile. |
| `LEMON_TOOL_DISCLOSURE_PROFILE` | string | `legacy` |  | `lemon_core` | Tool disclosure profile: legacy defers only the MCP/extension/WASM long tail over budget; coding also defers optional built-ins outside the coding core. |

### Tools wasm

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_WASM_AUTO_BUILD` | boolean | `true` |  | `lemon_core` | Whether WASM tools are auto-built from source on load. |
| `LEMON_WASM_CACHE_COMPILED` | boolean | `true` |  | `lemon_core` | Whether compiled WASM modules are cached on disk. |
| `LEMON_WASM_CACHE_DIR` | string | `` |  | `lemon_core` | Directory used for the compiled WASM module cache. |
| `LEMON_WASM_DEFAULT_FUEL_LIMIT` | integer | `10000000` |  | `lemon_core` | Default WASM interpreter fuel (execution-step) limit. |
| `LEMON_WASM_DEFAULT_MEMORY_LIMIT` | bytes (B/KB/MB/GB) | `10485760` |  | `lemon_core` | Default WASM tool memory limit (accepts B/KB/MB/GB suffixes). |
| `LEMON_WASM_DEFAULT_TIMEOUT_MS` | integer | `60000` |  | `lemon_core` | Default WASM tool execution timeout, in milliseconds. |
| `LEMON_WASM_ENABLED` | boolean | `false` |  | `lemon_core` | Whether the WASM tool runtime is enabled. |
| `LEMON_WASM_MAX_TOOL_INVOKE_DEPTH` | integer | `4` |  | `lemon_core` | Maximum nested WASM tool invocation depth. |
| `LEMON_WASM_RUNTIME_PATH` | string | `` |  | `lemon_core` | Path to the WASM runtime executable/library. |
| `LEMON_WASM_TOOL_PATHS` | list (comma-separated) | `[]` |  | `lemon_core` | Comma-separated extra directories to search for WASM tools. |

### Tools web

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_AUTO_RESIZE_IMAGES` | boolean | `true` |  | `lemon_core` | Whether oversized images are auto-resized before being sent to a model. |
| `LEMON_FIRECRAWL_API_KEY` | string | _(none)_ | yes | `lemon_core` | Firecrawl API key. |
| `LEMON_FIRECRAWL_BASE_URL` | string | `https://api.firecrawl.dev` |  | `lemon_core` | Firecrawl API base URL. |
| `LEMON_FIRECRAWL_ENABLED` | boolean | _(none)_ |  | `lemon_core` | Whether Firecrawl is used as the webfetch backend. Tri-state (nil = undecided, falls through to TOML/default); recognizes "true"/"1"/"yes" and "false"/"0"/"no" only -- not the "on"/"off" spellings most other booleans in this registry accept. Resolved with bespoke logic in LemonCore.Config.Tools.resolve_firecrawl/1, not the standard :boolean cast. |
| `LEMON_PERPLEXITY_API_KEY` | string | _(none)_ | yes | `lemon_core` | Perplexity API key used by the web search provider. |
| `LEMON_PERPLEXITY_BASE_URL` | string | _(none)_ |  | `lemon_core` | Perplexity API base URL override. |
| `LEMON_PERPLEXITY_MODEL` | string | `perplexity/sonar-pro` |  | `lemon_core` | Perplexity model id used for web search. |
| `LEMON_WEB_CACHE_MAX_ENTRIES` | integer | `100` |  | `lemon_core`, `coding_agent` | Maximum entries retained in the web cache. |
| `LEMON_WEB_CACHE_PATH` | string | _(none)_ |  | `lemon_core`, `coding_agent` | Path override for the persistent web cache file. |
| `LEMON_WEB_CACHE_PERSISTENT` | boolean | `true` |  | `lemon_core`, `coding_agent` | Whether the webfetch/websearch cache persists to disk. |
| `LEMON_WEB_FETCH_ALLOWED_HOSTNAMES` | list (comma-separated) | `[]` |  | `lemon_core` | Comma-separated hostname allowlist for webfetch. |
| `LEMON_WEB_FETCH_ALLOW_PRIVATE_NETWORK` | boolean | `false` |  | `lemon_core` | Whether webfetch is allowed to reach private/internal network addresses. |
| `LEMON_WEB_FETCH_CACHE_TTL` | integer | `15` |  | `lemon_core` | Webfetch result cache TTL, in minutes. |
| `LEMON_WEB_FETCH_ENABLED` | boolean | `true` |  | `lemon_core` | Whether the webfetch tool is enabled. |
| `LEMON_WEB_FETCH_MAX_CHARS` | integer | `50000` |  | `lemon_core` | Maximum characters of fetched page content returned to the model. |
| `LEMON_WEB_FETCH_MAX_REDIRECTS` | integer | `3` |  | `lemon_core` | Maximum HTTP redirects followed by webfetch. |
| `LEMON_WEB_FETCH_READABILITY` | boolean | `true` |  | `lemon_core` | Whether webfetch runs readability extraction on HTML pages. |
| `LEMON_WEB_FETCH_TIMEOUT` | integer | `30` |  | `lemon_core` | Webfetch request timeout, in seconds. |
| `LEMON_WEB_FETCH_USER_AGENT` | string | `Mozilla/5.0 (Macintosh; Intel Mac OS X 14_7_2) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36` |  | `lemon_core` | User-Agent header sent by webfetch. |
| `LEMON_WEB_SEARCH_API_KEY` | string | _(none)_ | yes | `lemon_core` | API key for the configured web search provider. |
| `LEMON_WEB_SEARCH_CACHE_TTL` | integer | `15` |  | `lemon_core` | Web search result cache TTL, in minutes. |
| `LEMON_WEB_SEARCH_ENABLED` | boolean | `true` |  | `lemon_core` | Whether the web search tool is enabled. |
| `LEMON_WEB_SEARCH_FAILOVER_ENABLED` | boolean | `true` |  | `lemon_core` | Whether web search falls over to a secondary provider on failure. |
| `LEMON_WEB_SEARCH_FAILOVER_PROVIDER` | string | _(none)_ |  | `lemon_core` | Secondary web search provider id used on failover. |
| `LEMON_WEB_SEARCH_MAX_RESULTS` | integer | `5` |  | `lemon_core` | Maximum results returned per web search call. |
| `LEMON_WEB_SEARCH_PROVIDER` | string | `brave` |  | `lemon_core` | Web search provider id (e.g. brave, perplexity). |
| `LEMON_WEB_SEARCH_TIMEOUT` | integer | `30` |  | `lemon_core` | Web search request timeout, in seconds. |

### Tui

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_TUI_DEBUG` | boolean | `false` |  | `lemon_core`, `lemon_cli` | Whether the terminal UI runs in debug mode. |
| `LEMON_TUI_THEME` | string | `lemon` |  | `lemon_core`, `lemon_cli` | Terminal UI theme name. |
