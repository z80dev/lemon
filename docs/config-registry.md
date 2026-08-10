# Environment Variable Config Registry

This is the reference for every environment variable Lemon reads today, grouped by area. The source of truth is `LemonCore.Env.all_declared/0`, which aggregates one registry module per app (plan 1.9): [`LemonCore.Env.Declarations`](../apps/lemon_core/lib/lemon_core/env/declarations.ex) for the platform's own variables, plus `<App>.Env` in each app that reads its own (e.g. [`LemonGateway.Env`](../apps/lemon_gateway/lib/lemon_gateway/env.ex), [`LemonSimUi.Env`](../apps/lemon_sim_ui/lib/lemon_sim_ui/env.ex)). The runtime lists them under `config :lemon_core, :env_registries`; registries whose app is absent from a build are skipped, so the aggregate always describes what the loaded code can actually read. [`LemonCore.Env`](../apps/lemon_core/lib/lemon_core/env.ex) itself is the framework (typing, aliases, defaults, resolution, redaction). This file documents the aggregate for humans.

As of this writing, `LemonCore.Env` is a **registry and typed accessor**, not yet the only way these variables are read. Call sites still read most of these directly via `System.get_env/1` or `LemonCore.Config.Helpers`; migrating them to `LemonCore.Env.get/2` is tracked as follow-up work (see "Migration order" below). New code should prefer `LemonCore.Env.get/2` for anything declared here, and add a declaration for anything new.

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
4. Provider credential resolution (`AgentCore.ProviderConfigResolver`, `AgentCore.ModelRuntime.Credentials`) -- highest blast radius (every provider call), migrate last and behind the existing `architecture_rules_check.ex` boundary tests.

## Variables by area

### Agent behavior

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
| `LEMON_SHELL_COMMAND_PREFIX` | string | _(none)_ |  | `lemon_core` | Command prefix prepended to every shell tool invocation. |
| `LEMON_SHELL_PATH` | string | _(none)_ |  | `lemon_core` | Shell executable path used by the bash/shell tool. |
| `LEMON_THEME` | string | `lemon` |  | `lemon_core` | Agent-level theme name (distinct from the TUI theme). |

### Web tools (search / fetch / cache)

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_AUTO_RESIZE_IMAGES` | boolean | `true` |  | `lemon_core` | Whether oversized images are auto-resized before being sent to a model. |
| `LEMON_FIRECRAWL_API_KEY` | string | _(none)_ | yes | `lemon_core` | Firecrawl API key. |
| `LEMON_FIRECRAWL_BASE_URL` | string | `https://api.firecrawl.dev` |  | `lemon_core` | Firecrawl API base URL. |
| `LEMON_FIRECRAWL_ENABLED` | boolean | _(none)_ |  | `lemon_core` | Whether Firecrawl is used as the webfetch backend. |
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

### WASM tool runtime

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_WASM_AUTO_BUILD` | boolean | `true` |  | `lemon_core` | Whether WASM tools are auto-built from source on load. |
| `LEMON_WASM_CACHE_COMPILED` | boolean | `true` |  | `lemon_core` | Whether compiled WASM modules are cached on disk. |
| `LEMON_WASM_CACHE_DIR` | string | `` |  | `lemon_core` | Directory used for the compiled WASM module cache. |
| `LEMON_WASM_DEFAULT_FUEL_LIMIT` | integer | `10000000` |  | `lemon_core` | Default WASM interpreter fuel (execution-step) limit. |
| `LEMON_WASM_DEFAULT_MEMORY_LIMIT` | bytes (`10MB` etc) | `10485760` |  | `lemon_core` | Default WASM tool memory limit (accepts B/KB/MB/GB suffixes). |
| `LEMON_WASM_DEFAULT_TIMEOUT_MS` | integer | `60000` |  | `lemon_core` | Default WASM tool execution timeout, in milliseconds. |
| `LEMON_WASM_ENABLED` | boolean | `false` |  | `lemon_core` | Whether the WASM tool runtime is enabled. |
| `LEMON_WASM_MAX_TOOL_INVOKE_DEPTH` | integer | `4` |  | `lemon_core` | Maximum nested WASM tool invocation depth. |
| `LEMON_WASM_RUNTIME_PATH` | string | `` |  | `lemon_core` | Path to the WASM runtime executable/library. |
| `LEMON_WASM_TOOL_PATHS` | list (comma-separated) | `[]` |  | `lemon_core` | Comma-separated extra directories to search for WASM tools. |

### Gateway (transports, engine scheduling)

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `DISCORD_BOT_TOKEN` | string | _(none)_ | yes | `lemon_channels` | Discord bot token (ecosystem-standard name). |
| `FARCASTER_ACCOUNT_ID` | string | _(none)_ |  | `lemon_gateway` | Farcaster account id used by the Farcaster transport. |
| `FARCASTER_API_KEY` | string | _(none)_ | yes | `lemon_gateway` | Farcaster (Neynar) API key. |
| `FARCASTER_HUB_VALIDATE_URL` | string | _(none)_ |  | `lemon_gateway` | Farcaster hub URL used to validate cast/frame messages. |
| `FARCASTER_SIGNER_UUID` | string | _(none)_ | yes | `lemon_gateway` | Farcaster signer UUID used to post casts. |
| `FARCASTER_STATE_SECRET` | string | _(none)_ | yes | `lemon_gateway` | Secret used to sign Farcaster frame state tokens. |
| `LEMON_GATEWAY_AUTO_RESUME` | boolean | `false` |  | `lemon_core`, `lemon_gateway` | Whether the gateway auto-resumes interrupted runs on boot. |
| `LEMON_GATEWAY_DEFAULT_CWD` | string | _(none)_ |  | `lemon_core`, `lemon_gateway` | Default working directory for gateway-initiated runs. |
| `LEMON_GATEWAY_DEFAULT_ENGINE` | string | `lemon` |  | `lemon_core`, `lemon_gateway` | Default coding-agent engine used for gateway-initiated runs. |
| `LEMON_GATEWAY_ENABLE_DISCORD` | boolean | `false` |  | `lemon_core`, `lemon_channels` | Whether the Discord transport is enabled. |
| `LEMON_GATEWAY_ENABLE_EMAIL` | boolean | `false` |  | `lemon_core`, `lemon_gateway` | Whether the email transport is enabled. |
| `LEMON_GATEWAY_ENABLE_FARCASTER` | boolean | `false` |  | `lemon_core`, `lemon_gateway` | Whether the Farcaster transport is enabled. |
| `LEMON_GATEWAY_ENABLE_TELEGRAM` | boolean | `false` |  | `lemon_core`, `lemon_channels` | Whether the Telegram transport is enabled. |
| `LEMON_GATEWAY_ENABLE_WEBHOOK` | boolean | `false` |  | `lemon_core`, `lemon_gateway` | Whether the generic webhook transport is enabled. |
| `LEMON_GATEWAY_ENABLE_XMTP` | boolean | `false` |  | `lemon_core`, `lemon_channels` | Whether the XMTP transport is enabled. |
| `LEMON_GATEWAY_ENGINE_LOCK_TIMEOUT_MS` | integer | `60000` |  | `lemon_core`, `lemon_gateway` | Engine lock acquisition timeout, in milliseconds. |
| `LEMON_GATEWAY_MAX_CONCURRENT_RUNS` | integer | `2` |  | `lemon_core`, `lemon_gateway` | Maximum concurrent agent runs the gateway will schedule. |
| `LEMON_GATEWAY_REQUIRE_ENGINE_LOCK` | boolean | `true` |  | `lemon_core`, `lemon_gateway` | Whether an engine lock is required before starting a gateway run. |
| `LEMON_LOCK_DIR` | string | _(none)_ |  | `lemon_channels` | Directory used for gateway/channel file locks. |
| `LEMON_TELEGRAM_COMPACTION_CONTEXT_WINDOW` | integer | `400000` |  | `lemon_core`, `lemon_channels` | Context window size (tokens) used for Telegram compaction triggers. |
| `LEMON_TELEGRAM_COMPACTION_ENABLED` | boolean | `true` |  | `lemon_core`, `lemon_channels` | Whether Telegram session transcripts are auto-compacted. |
| `LEMON_TELEGRAM_COMPACTION_RESERVE_TOKENS` | integer | `16384` |  | `lemon_core`, `lemon_channels` | Token budget reserved during Telegram session compaction. |
| `LEMON_TELEGRAM_COMPACTION_TRIGGER_RATIO` | float | `0.9` |  | `lemon_core`, `lemon_channels` | Context-window fill ratio that triggers Telegram compaction. |
| `LEMON_TELEGRAM_POLLER_LOCK_STALE_MS` | integer | _(none)_ |  | `lemon_channels` | Age (ms) after which a Telegram poller lock is considered stale and reclaimed. |

### Gateway: SMS / Twilio

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

### Gateway: voice

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `DEEPGRAM_API_KEY` | string | _(none)_ | yes | `lemon_gateway` | Deepgram API key for voice transcription (ecosystem-standard name). |
| `ELEVENLABS_API_KEY` | string | _(none)_ | yes | `lemon_gateway` | ElevenLabs API key for voice synthesis (ecosystem-standard name). |
| `ELEVENLABS_VOICE_ID` | string | `21m00Tcm4TlvDq8ikWAM` |  | `lemon_gateway` | ElevenLabs voice id used for voice synthesis. |
| `VOICE_PUBLIC_URL` | string | _(none)_ |  | `lemon_gateway` | Public URL for the voice websocket endpoint (grandfathered, no LEMON_ prefix). |
| `VOICE_RECORDINGS_DIR` | string | _(none)_ |  | `lemon_gateway` | Directory where downloaded call recordings are stored. |

### Logging

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_LOG_COMPRESS_ON_ROTATE` | boolean | _(none)_ |  | `lemon_core` | Whether rotated log files are gzip-compressed. |
| `LEMON_LOG_FILE` | string | _(none)_ |  | `lemon_core` | Path to the log file (nil disables file logging). |
| `LEMON_LOG_FILESYNC_REPEAT_INTERVAL` | integer | _(none)_ |  | `lemon_core` | Log file sync interval, in milliseconds. |
| `LEMON_LOG_LEVEL` | string | _(none)_ |  | `lemon_core` | Global log level override (debug/info/notice/warning/error/critical/alert/emergency). |
| `LEMON_LOG_MAX_NO_BYTES` | bytes (`10MB` etc) | _(none)_ |  | `lemon_core` | Log file rotation size threshold. |
| `LEMON_LOG_MAX_NO_FILES` | integer | _(none)_ |  | `lemon_core` | Number of rotated log files retained. |

### Terminal UI

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_TUI_DEBUG` | boolean | `false` |  | `lemon_core`, `lemon_cli` | Whether the terminal UI runs in debug mode. |
| `LEMON_TUI_THEME` | string | `lemon` |  | `lemon_core`, `lemon_cli` | Terminal UI theme name. |

### Runtime / process

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
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

### Docker terminal backend

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_DOCKER_TERMINAL_CPUS` | string | _(none)_ |  | `lemon_core` | CPU limit for the Docker terminal backend container. |
| `LEMON_DOCKER_TERMINAL_IMAGE` | string | _(none)_ |  | `lemon_core` | Docker image used for the Docker terminal backend. |
| `LEMON_DOCKER_TERMINAL_MEMORY` | string | _(none)_ |  | `lemon_core` | Memory limit for the Docker terminal backend container. |
| `LEMON_DOCKER_TERMINAL_NETWORK` | string | `none` |  | `lemon_core` | Docker network mode for the Docker terminal backend container. |
| `LEMON_DOCKER_TERMINAL_PIDS_LIMIT` | string | _(none)_ |  | `lemon_core` | Process count limit for the Docker terminal backend container. |
| `LEMON_DOCKER_TERMINAL_READ_ONLY_ROOTFS` | boolean | `true` |  | `lemon_core` | Whether the Docker terminal backend mounts a read-only root filesystem. |
| `LEMON_DOCKER_TERMINAL_TMPFS_SIZE` | string | _(none)_ |  | `lemon_core` | tmpfs size for the Docker terminal backend's writable /tmp mount. |

### SSH terminal backend

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_SSH_TERMINAL_CONNECT_TIMEOUT` | string | `10` |  | `lemon_core` | SSH connect timeout (seconds) for the SSH terminal backend. |
| `LEMON_SSH_TERMINAL_IDENTITY_FILE` | string | _(none)_ | yes | `lemon_core` | SSH identity (private key) file for the SSH terminal backend. |
| `LEMON_SSH_TERMINAL_PORT` | string | `22` |  | `lemon_core` | SSH port for the SSH terminal backend. |
| `LEMON_SSH_TERMINAL_STRICT_HOST_KEY_CHECKING` | string | `yes` |  | `lemon_core` | SSH StrictHostKeyChecking setting for the SSH terminal backend. |
| `LEMON_SSH_TERMINAL_TARGET` | string | _(none)_ |  | `lemon_core` | SSH target (user@host) for the SSH terminal backend. |
| `LEMON_SSH_TERMINAL_USER_KNOWN_HOSTS_FILE` | string | _(none)_ |  | `lemon_core` | Known-hosts file used by the SSH terminal backend. |
| `LEMON_SSH_TERMINAL_WORKDIR` | string | _(none)_ |  | `lemon_core` | Remote working directory for the SSH terminal backend. |

### Persistence / store

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_STORE_DB_PATH` | string | _(none)_ |  | `lemon_core` | Override path for the SQLite store database file. |
| `LEMON_STORE_PATH` | string | _(none)_ |  | `lemon_core` | Override path for the primary JSONL/SQLite data store. |

### Error reporting (Sentry)

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `SENTRY_DSN` | string | _(none)_ | yes | `lemon_core` | Sentry DSN; error reporting is dormant unless this is set. |
| `SENTRY_ENVIRONMENT` | string | _(none)_ |  | `lemon_core` | Sentry environment name override (falls back to LEMON_ENV, then Mix env). |

### HTTP endpoints & tokens

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_ACP_API_TOKEN` | string | _(none)_ | yes | `lemon_control_plane` | Bearer token required for the ACP (agent control protocol) HTTP API. |
| `LEMON_AGENT_PROFILES_CWD` | string | _(none)_ |  | `lemon_router` | Working directory override used to resolve router agent profiles. |
| `LEMON_CONTROL_PLANE_PORT` | integer | _(none)_ |  | `lemon_control_plane` | Port the control-plane HTTP server listens on. |
| `LEMON_GATEWAY_HEALTH_PORT` | integer | _(none)_ |  | `lemon_gateway` | Port the gateway health-check endpoint listens on. |
| `LEMON_OPENAI_COMPAT_API_TOKEN`<br>_(alias: `LEMON_OPENAI_COMPAT_TOKEN`)_ | string | _(none)_ | yes | `lemon_control_plane` | Bearer token required for the OpenAI-compatible HTTP API. |
| `LEMON_OPENAI_COMPAT_IMAGE_URL_ALLOWED_HOSTS`<br>_(alias: `LEMON_OPENAI_COMPAT_IMAGE_HOST_ALLOWLIST`)_ | list (comma-separated) | `[]` |  | `lemon_control_plane` | Comma-separated hostname allowlist for OpenAI-compat image URL fetch. |
| `LEMON_OPENAI_COMPAT_IMAGE_URL_FETCH` | boolean | `false` |  | `lemon_control_plane` | Whether the OpenAI-compat endpoint is allowed to fetch image URLs from messages. |
| `LEMON_ROUTER_HEALTH_PORT` | integer | _(none)_ |  | `lemon_router` | Port the router health-check endpoint listens on. |
| `LEMON_SIM_UI_ACCESS_TOKEN` | string | _(none)_ | yes | `lemon_sim_ui` | Admin bearer/session token; required with at least 32 bytes for a production Sim UI endpoint. |
| `LEMON_SIM_UI_BIND_IP` | string | `127.0.0.1` |  | `lemon_sim_ui` | Bind IP address for the LemonSimUi dev endpoint. |
| `LEMON_SIM_UI_HOST` | string | `localhost` |  | `lemon_sim_ui` | Public hostname for the LemonSimUi prod endpoint; must be explicit in production. |
| `LEMON_SIM_UI_MAX_CONCURRENT_RUNNERS` | integer | `8` |  | `lemon_sim_ui` | Maximum active simulation runners per instance; persisted recoveries queue until capacity is available. |
| `LEMON_SIM_UI_MAX_STORED_SIMS` | integer | `500` |  | `lemon_sim_ui` | Maximum terminal simulation snapshots retained; active and recoverable runs are never pruned. |
| `LEMON_SIM_UI_PORT` | integer | `4090` |  | `lemon_sim_ui` | Port LemonSimUi listens on. |
| `LEMON_SIM_UI_URL_PORT` | integer | `443` |  | `lemon_sim_ui` | Public URL port for generated LemonSimUi links. |
| `LEMON_SIM_UI_URL_SCHEME` | string | `https` |  | `lemon_sim_ui` | Public URL scheme for generated links. Hosted rooms require HTTPS in production. |
| `LEMON_SIM_UI_PUBLIC_VENDING_LAUNCHER` | boolean | `false` |  | `lemon_sim_ui` | Whether the public VendingBench launcher page is exposed. |
| `LEMON_SIM_UI_SECRET_KEY_BASE` | string | _(none)_ | yes | `lemon_sim_ui` | Phoenix secret_key_base; required with at least 64 bytes for a production Sim UI endpoint. |
| `LEMON_SIM_UI_SUITE_ROOTS` | list (comma-separated) | `[]` |  | `lemon_sim_ui` | Colon-separated extra suite root directories for LemonSimUi. |
| `LEMON_WEB_ACCESS_TOKEN` | string | _(none)_ | yes | `lemon_web` | Bearer token required to access the LemonWeb HTTP API. |
| `LEMON_WEB_HOST` | string | `localhost` |  | `lemon_web` | Public hostname for the LemonWeb prod endpoint. |
| `LEMON_WEB_PORT` | integer | `4080` |  | `lemon_web` | Port LemonWeb listens on. |
| `LEMON_WEB_URL_PORT` | integer | `443` |  | `lemon_web` | Public URL port for generated LemonWeb links. |
| `LEMON_WEB_URL_SCHEME` | string | `https` |  | `lemon_web` | Public URL scheme for generated LemonWeb links (http or https). |
| `LEMON_WEB_SECRET_KEY_BASE` | string | _(none)_ | yes | `lemon_web` | Phoenix secret_key_base for the LemonWeb prod endpoint. |
| `LEMON_WEB_UPLOADS_DIR` | string | _(none)_ |  | `lemon_web` | Directory used for LemonWeb file uploads. |
| `PHX_SERVER` | boolean | `false` |  | `lemon_web`, `lemon_sim_ui` | Standard Phoenix flag to start the HTTP server in a release (ecosystem-standard name). |

### Skills / MCP

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_AGENT_ID` | string | `default` |  | `lemon_skills` | Default agent id used by `mix lemon.skill` CLI operations. |
| `LEMON_HARNESS_SKILLS_DIR` | string | _(none)_ |  | `lemon_skills` | Override directory for harness/eval skill fixtures. |
| `LEMON_MCP_DISABLED` | boolean | `false` |  | `lemon_skills` | Kill switch to disable all MCP tool sources. |
| `LEMON_MCP_SERVERS` | string | _(none)_ |  | `lemon_skills` | JSON-encoded list of MCP server configs, overriding the TOML/app config. |

### Browser tool

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_BROWSER_ATTACH_ONLY` | boolean | `false` |  | `lemon_browser` | Whether the browser tool only attaches to an existing browser instead of launching one. |
| `LEMON_BROWSER_CDP_ENDPOINT` | string | _(none)_ |  | `lemon_browser` | Chrome DevTools Protocol websocket endpoint to attach to instead of launching a browser. |
| `LEMON_BROWSER_CDP_PORT` | integer | `18800` |  | `lemon_browser` | Local CDP port used when launching a managed browser instance. |
| `LEMON_BROWSER_DRIVER_PATH` | string | _(none)_ |  | `lemon_browser` | Path to the browser automation driver binary. |

### Coding-agent CLI runners

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `FACTORY_API_KEY` | string | _(none)_ | yes | `agent_core` | Factory (Droid CLI) API key. |
| `LEMON_CLAUDE_YOLO` | boolean | `false` |  | `agent_core` | Whether the Claude CLI runner skips permission prompts (`--dangerously-skip-permissions`-style). |
| `LEMON_CODEX_AUTO_APPROVE` | boolean | `false` |  | `agent_core` | Whether the Codex CLI runner auto-approves tool calls. |
| `LEMON_CODEX_EXTRA_ARGS` | list (comma-separated) | `[]` |  | `agent_core` | Extra whitespace-separated CLI args appended to Codex invocations. |
| `PI_CODING_AGENT_DIR` | string | _(none)_ |  | `agent_core` | Working directory override for the Pi coding-agent CLI runner. |
| `PI_DEBUG` | boolean | `false` |  | `coding_agent`, `agent_core` | Debug flag for the Pi coding-agent CLI runner / CodingAgent.Config. |

### AI provider diagnostics & tuning

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_AI_DEBUG` | boolean | `false` |  | `ai` | Whether raw Anthropic SSE traffic is logged to a debug file. |
| `LEMON_AI_DEBUG_FILE` | string | `/tmp/lemon_anthropic_sse.log` |  | `ai` | File path used for Anthropic SSE debug logging. |
| `LEMON_AI_HTTP_TRACE` | boolean | `false` |  | `ai` | Whether low-level HTTP request/response tracing is enabled for provider calls. |
| `LEMON_AI_PROMPT_DIAGNOSTICS` | boolean | `false` |  | `ai` | Whether prompt diagnostics logging is enabled. |
| `LEMON_AI_PROMPT_DIAGNOSTICS_LOG_LEVEL` | string | _(none)_ |  | `ai` | Log level used for prompt diagnostics output. |
| `LEMON_AI_PROMPT_DIAGNOSTICS_TOP_N` | integer | _(none)_ |  | `ai` | Number of top prompt-diagnostics entries to report. |
| `LEMON_ANTHROPIC_CLAUDE_PATH` | string | _(none)_ |  | `ai` | Override path to the `claude` executable used for Anthropic OAuth. |
| `LEMON_KIMI_MAX_REQUEST_MESSAGES` | integer | _(none)_ |  | `ai` | Max message-history length sent per request to Kimi (history-limited provider). |
| `PI_CACHE_RETENTION` | string | _(none)_ |  | `ai` | When set to "long", requests 24h prompt-cache retention from OpenAI-compatible providers. |

### Provider (misc)

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `OPENAI_BASE_URL` | string | _(none)_ |  | `ai` | OpenAI API base URL override (ecosystem-standard name). |

### Provider credentials (ecosystem-standard names)

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `ANTHROPIC_API_KEY` | string | _(none)_ | yes | `ai` | Anthropic API key. |
| `AWS_ACCESS_KEY_ID` | string | _(none)_ | yes | `lemon_core`, `agent_core` | AWS access key id for Bedrock (ecosystem-standard name). |
| `AWS_DEFAULT_REGION` | string | _(none)_ |  | `lemon_core` | AWS region fallback (ecosystem-standard AWS CLI name). |
| `AWS_PROFILE` | string | _(none)_ |  | `agent_core` | Named AWS CLI credentials profile to resolve Bedrock credentials from. |
| `AWS_REGION` | string | `us-east-1` |  | `lemon_core` | AWS region for Bedrock (ecosystem-standard name). |
| `AWS_SECRET_ACCESS_KEY` | string | _(none)_ | yes | `lemon_core`, `agent_core` | AWS secret access key for Bedrock (ecosystem-standard name). |
| `AWS_SESSION_TOKEN` | string | _(none)_ | yes | `lemon_core` | AWS temporary session token for Bedrock (ecosystem-standard name). |
| `AZURE_OPENAI_API_KEY` | string | _(none)_ | yes | `ai` | Azure OpenAI API key. |
| `AZURE_OPENAI_API_VERSION` | string | _(none)_ |  | `lemon_core` | Azure OpenAI API version. |
| `AZURE_OPENAI_BASE_URL` | string | _(none)_ |  | `lemon_core` | Azure OpenAI resource base URL. |
| `AZURE_OPENAI_DEPLOYMENT_NAME_MAP` | string | _(none)_ |  | `lemon_core` | JSON map of model id to Azure OpenAI deployment name. |
| `AZURE_OPENAI_RESOURCE_NAME` | string | _(none)_ |  | `lemon_core` | Azure OpenAI resource name. |
| `CHATGPT_TOKEN` | string | _(none)_ | yes | `ai` | ChatGPT/Codex session token (fallback for OPENAI_CODEX_API_KEY). |
| `GCLOUD_PROJECT` | string | _(none)_ |  | `ai`, `lemon_cli`, `lemon_core` | Google Cloud project id (gcloud CLI convention name). |
| `GEMINI_API_KEY` | string | _(none)_ | yes | `ai` | Gemini API key (alt name). |
| `GITHUB_COPILOT_CLIENT_ID` | string | _(none)_ |  | `ai` | GitHub Copilot OAuth client id override. |
| `GOOGLE_API_KEY` | string | _(none)_ | yes | `ai` | Google Generative AI API key (alt name). |
| `GOOGLE_APPLICATION_CREDENTIALS` | string | _(none)_ | yes | `ai`, `agent_core` | Path to a Google service-account JSON credentials file (ecosystem-standard name). |
| `GOOGLE_APPLICATION_CREDENTIALS_JSON` | string | _(none)_ | yes | `lemon_core` | Inline Google service-account JSON credentials. |
| `GOOGLE_CLOUD_LOCATION` | string | _(none)_ |  | `lemon_core` | Google Cloud / Vertex AI region. |
| `GOOGLE_CLOUD_PROJECT` | string | _(none)_ |  | `ai`, `lemon_cli`, `lemon_core` | Google Cloud project id (ecosystem-standard name). |
| `GOOGLE_CLOUD_PROJECT_ID` | string | _(none)_ |  | `ai`, `lemon_cli`, `lemon_core` | Google Cloud project id (alt ecosystem name). |
| `GOOGLE_GEMINI_CLI_OAUTH_CLIENT_ID` | string | _(none)_ |  | `ai` | Google Gemini CLI OAuth client id override. |
| `GOOGLE_GEMINI_CLI_OAUTH_CLIENT_SECRET` | string | _(none)_ | yes | `ai` | Google Gemini CLI OAuth client secret override. |
| `GOOGLE_GENERATIVE_AI_API_KEY` | string | _(none)_ | yes | `ai` | Google Generative AI API key (primary name). |
| `LEMON_GEMINI_PROJECT_ID` | string | _(none)_ |  | `ai`, `lemon_cli`, `lemon_core` | Lemon-specific override for the Gemini/Vertex project id, checked before the GOOGLE_CLOUD_* names. |
| `MAGIC_EDEN_API_KEY` | string | _(none)_ | yes | `lemon_tcg` | Magic Eden marketplace API key. |
| `MISTRAL_API_KEY` | string | _(none)_ | yes | `ai` | Mistral API key. |
| `OPENAI_API_KEY` | string | _(none)_ | yes | `ai` | OpenAI API key. |
| `OPENAI_CODEX_API_KEY` | string | _(none)_ | yes | `ai` | OpenAI Codex API key. |
| `OPENAI_CODEX_OAUTH_CLIENT_ID` | string | _(none)_ |  | `ai` | OpenAI Codex OAuth client id override. |
| `OPENCODE_API_KEY` | string | _(none)_ | yes | `ai` | OpenCode provider API key. |
| `OPENSEA_API_KEY` | string | _(none)_ | yes | `lemon_tcg` | OpenSea marketplace API key. |
| `PRICECHARTING_API_TOKEN` | string | _(none)_ | yes | `lemon_tcg` | PriceCharting API token. |

### X (Twitter) API

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `X_API_ACCESS_TOKEN` | string | _(none)_ | yes | `x_api` | X (Twitter) API OAuth1 access token. |
| `X_API_ACCESS_TOKEN_SECRET` | string | _(none)_ | yes | `x_api` | X (Twitter) API OAuth1 access token secret. |
| `X_API_CONSUMER_KEY` | string | _(none)_ | yes | `x_api` | X (Twitter) API OAuth1 consumer key. |
| `X_API_CONSUMER_SECRET` | string | _(none)_ | yes | `x_api` | X (Twitter) API OAuth1 consumer secret. |

### lemon_tcg wallets

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `EVM_PRIVATE_KEY` | string | _(none)_ | yes | `lemon_tcg` | EVM wallet private key used to sign on-chain transactions. |
| `SOLANA_KEYPAIR_FILE` | string | _(none)_ | yes | `lemon_tcg` | Path to a Solana keypair JSON file used to sign wallet transactions. |
| `SOLANA_SECRET_KEY` | string | _(none)_ | yes | `lemon_tcg` | Base58/array-encoded Solana secret key used to sign wallet transactions. |

### lemon_evals live-model opt-in checks

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_EVAL_API_KEY`<br>_(alias: `INTEGRATION_API_KEY`, `ANTHROPIC_API_KEY`)_ | string | _(none)_ | yes | `lemon_evals` | Live-eval provider API key. |
| `LEMON_EVAL_API_KEY_SECRET`<br>_(alias: `INTEGRATION_API_KEY_SECRET`)_ | string | _(none)_ | yes | `lemon_evals` | Secrets-store key name resolving to the live-eval API key. |
| `LEMON_EVAL_API_TYPE`<br>_(alias: `INTEGRATION_API_TYPE`)_ | string | _(none)_ |  | `lemon_evals` | Live-eval `Ai.Types.Model.api` atom override (default: anthropic_messages). |
| `LEMON_EVAL_BASE_URL`<br>_(alias: `INTEGRATION_BASE_URL`)_ | string | _(none)_ |  | `lemon_evals` | Live-eval API base URL override. |
| `LEMON_EVAL_MODEL`<br>_(alias: `INTEGRATION_MODEL`)_ | string | _(none)_ |  | `lemon_evals` | Live-eval model id (default: kimi-for-coding). |
| `LEMON_EVAL_PROVIDER`<br>_(alias: `INTEGRATION_PROVIDER`)_ | string | _(none)_ |  | `lemon_evals` | Live-eval provider atom override (default: kimi). |

### Always-on model arenas / sim

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `LEMON_ARENA_LEAGUE_ROOT` | string | _(none)_ |  | `lemon_sim_ui` | Persistent root directory under which each arena domain's league dir defaults to `<domain>_league`; required when production arenas omit per-domain dirs. |
| `LEMON_ARENA_POKER_ENABLED` | boolean | `true` |  | `lemon_sim_ui` | Whether the poker arena is enabled (only checked once MODELS is set). |
| `LEMON_ARENA_POKER_GAME_DELAY_MS` | integer | _(none)_ |  | `lemon_sim_ui` | Delay between games (ms) for the poker arena. |
| `LEMON_ARENA_POKER_LEAGUE_DIR` | string | _(none)_ |  | `lemon_sim_ui` | League standings directory for the poker arena. |
| `LEMON_ARENA_POKER_MODELS` | list (comma-separated) | `[]` |  | `lemon_sim_ui` | Comma-separated provider:model specs enabling the poker arena. |
| `LEMON_ARENA_POKER_PLAYER_COUNT` | integer | _(none)_ |  | `lemon_sim_ui` | Player count for the poker arena. |
| `LEMON_ARENA_SPACE_STATION_ENABLED` | boolean | `true` |  | `lemon_sim_ui` | Whether the space_station arena is enabled (only checked once MODELS is set). |
| `LEMON_ARENA_SPACE_STATION_GAME_DELAY_MS` | integer | _(none)_ |  | `lemon_sim_ui` | Delay between games (ms) for the space_station arena. |
| `LEMON_ARENA_SPACE_STATION_LEAGUE_DIR` | string | _(none)_ |  | `lemon_sim_ui` | League standings directory for the space_station arena. |
| `LEMON_ARENA_SPACE_STATION_MODELS` | list (comma-separated) | `[]` |  | `lemon_sim_ui` | Comma-separated provider:model specs enabling the space_station arena. |
| `LEMON_ARENA_SPACE_STATION_PLAYER_COUNT` | integer | _(none)_ |  | `lemon_sim_ui` | Player count for the space_station arena. |
| `LEMON_ARENA_STOCK_MARKET_ENABLED` | boolean | `true` |  | `lemon_sim_ui` | Whether the stock_market arena is enabled (only checked once MODELS is set). |
| `LEMON_ARENA_STOCK_MARKET_GAME_DELAY_MS` | integer | _(none)_ |  | `lemon_sim_ui` | Delay between games (ms) for the stock_market arena. |
| `LEMON_ARENA_STOCK_MARKET_LEAGUE_DIR` | string | _(none)_ |  | `lemon_sim_ui` | League standings directory for the stock_market arena. |
| `LEMON_ARENA_STOCK_MARKET_MODELS` | list (comma-separated) | `[]` |  | `lemon_sim_ui` | Comma-separated provider:model specs enabling the stock_market arena. |
| `LEMON_ARENA_STOCK_MARKET_PLAYER_COUNT` | integer | _(none)_ |  | `lemon_sim_ui` | Player count for the stock_market arena. |
| `LEMON_ARENA_SURVIVOR_ENABLED` | boolean | `true` |  | `lemon_sim_ui` | Whether the survivor arena is enabled (only checked once MODELS is set). |
| `LEMON_ARENA_SURVIVOR_GAME_DELAY_MS` | integer | _(none)_ |  | `lemon_sim_ui` | Delay between games (ms) for the survivor arena. |
| `LEMON_ARENA_SURVIVOR_LEAGUE_DIR` | string | _(none)_ |  | `lemon_sim_ui` | League standings directory for the survivor arena. |
| `LEMON_ARENA_SURVIVOR_MODELS` | list (comma-separated) | `[]` |  | `lemon_sim_ui` | Comma-separated provider:model specs enabling the survivor arena. |
| `LEMON_ARENA_SURVIVOR_PLAYER_COUNT` | integer | _(none)_ |  | `lemon_sim_ui` | Player count for the survivor arena. |
| `LEMON_ARENA_WEREWOLF_ENABLED`<br>_(alias: `WEREWOLF_ARENA_ENABLED`)_ | boolean | `true` |  | `lemon_sim_ui` | Whether the werewolf arena is enabled (only checked once MODELS is set). |
| `LEMON_ARENA_WEREWOLF_GAME_DELAY_MS`<br>_(alias: `WEREWOLF_ARENA_GAME_DELAY_MS`)_ | integer | _(none)_ |  | `lemon_sim_ui` | Delay between games (ms) for the werewolf arena. |
| `LEMON_ARENA_WEREWOLF_MAX_GAME_RECORDS`<br>_(alias: `WEREWOLF_ARENA_MAX_GAME_RECORDS`)_ | integer | `1000` |  | `lemon_sim_ui` | Rolling number of Werewolf league game records retained on disk and included in standings. |
| `LEMON_ARENA_WEREWOLF_LEAGUE_DIR`<br>_(alias: `WEREWOLF_LEAGUE_DIR`)_ | string | _(none)_ |  | `lemon_sim_ui` | League standings directory for the werewolf arena. |
| `LEMON_ARENA_WEREWOLF_MODELS`<br>_(alias: `WEREWOLF_ARENA_MODELS`)_ | list (comma-separated) | `[]` |  | `lemon_sim_ui` | Comma-separated provider:model specs enabling the werewolf arena. |
| `LEMON_ARENA_WEREWOLF_PLAYER_COUNT`<br>_(alias: `WEREWOLF_ARENA_PLAYER_COUNT`)_ | integer | _(none)_ |  | `lemon_sim_ui` | Player count for the werewolf arena. |
| `LEMON_WEREWOLF_HOSTED_ENABLED` | boolean | `false` in prod; `true` in dev/test |  | `lemon_sim_ui` | Enables hosted human Werewolf. Disabled boot does not recover room timers or AI work. |
| `LEMON_WEREWOLF_HOST_CREATE_TOKEN` | string | _(none)_ | yes | `lemon_sim_ui` | Room-creation invite; required at 32+ bytes when production hosted rooms are enabled. |
| `LEMON_WEREWOLF_HOSTED_ROOM_LIMIT` | integer | `100` |  | `lemon_sim_ui` | Maximum active hosted rooms per single-node instance (1–500). |
| `LEMON_WEREWOLF_HOSTED_ROOM_RETENTION` | integer | `500` |  | `lemon_sim_ui` | Maximum retained terminal room records (25–5000). |
| `LEMON_WEREWOLF_HOSTED_LOBBY_TTL_SECONDS` | integer | `86400` |  | `lemon_sim_ui` | Abandoned-lobby retention before serialized pruning (300–2592000 seconds). |
| `LEMON_WEREWOLF_HOSTED_INACTIVE_TTL_SECONDS` | integer | `604800` |  | `lemon_sim_ui` | Paused-room retention before serialized pruning (3600–31536000 seconds). |
| `LEMON_WEREWOLF_HOSTED_AI_MODEL` | string | _(none)_ |  | `lemon_sim_ui` | `provider:model` frozen into new rooms with AI seats; provider credentials are validated before start/recovery. |
| `LEMON_WEREWOLF_HOSTED_AI_CONCURRENCY` | integer | `4` |  | `lemon_sim_ui` | Global hosted AI provider-task limit per instance (1–64). |
| `LEMON_GOAL_JUDGE_MODEL` | string | _(none)_ |  | `lemon_automation` | Model id used to judge automation goal completion. |
| `LEMON_SIM_AUTO_LOOP` | boolean | `false` |  | `lemon_sim_ui` | Whether the werewolf auto-loop starts automatically on boot. |
| `LEMON_SIM_WEREWOLF_PLAYERS` | integer | `6` |  | `lemon_sim_ui` | Player count for the werewolf auto-loop. |

### Platform / BEAM release (standard names)

| Env Var | Type | Default | Secret | Apps | Description |
|---|---|---|---|---|---|
| `HOME` | string | _(none)_ |  | `lemon_core`, `ai`, `coding_agent` | Standard POSIX home directory; used for default `.lemon` locations and OAuth token caches. |
| `MIX_ENV` | string | _(none)_ |  | `lemon_core` | Standard Mix environment (dev/test/prod). |
| `RELEASE_NAME` | string | _(none)_ |  | `lemon_core` | Standard Elixir release name; selects which endpoint(s) boot in a multi-app release. |
| `RELEASE_NODE` | string | _(none)_ |  | `lemon_core` | Standard Elixir release node name; presence indicates a running release (vs. `mix`). |
| `RELEASE_VSN` | string | _(none)_ |  | `lemon_core` | Standard Elixir release version. |
| `SHELL` | string | `/bin/sh` |  | `lemon_sim` | Standard POSIX shell path, used as a fallback shell for the external decider. |
| `TERM` | string | _(none)_ |  | `lemon_cli` | Standard terminal type variable; used to detect non-interactive/dumb terminals. |
