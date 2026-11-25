# LemonCore

<!-- Maintenance: strict Credo cleanup keeps runtime behavior unchanged. -->

Foundational shared library for the Lemon umbrella project. All other apps depend on `lemon_core` -- it provides configuration management, configured-implementation contract validation, encrypted secrets, pluggable storage, an event bus, live named-node invocation routing, session routing primitives, idempotency, execution approvals, telemetry, and quality tooling.

`LemonCore.Context` is the shared versioned preview/resolve boundary for
root-confined file and folder references, shell-free git diffs, SSRF-guarded
public URLs, redacted session exports, and format-sniffed document text. See
[`docs/user-guide/context-references.md`](../../docs/user-guide/context-references.md).

This app has **zero dependencies on other umbrella apps** and must remain that way.

`LemonCore.Rpc.Client` is the shared `gen_statem` for RPC request ownership:
per-request deadlines, original-caller monitors, fail-all on transport loss,
bounded JSONL/Content-Length framing and redacted management status. Drivers
retain protocol semantics and process lifecycle; they never automatically replay
unknown outcomes. The module is an additive published-package API and has no
umbrella dependencies.

`LemonCore.TaskSupervisor` is the shared bounded task-admission boundary.
Its default of **1024 concurrent children per supervisor is caller policy**,
not a benchmark-derived throughput setting. Set an explicit positive integer
`:max_children` in `child_spec/1`, or configure a name-keyed map under
`config :lemon_core, :task_supervisor_max_children, %{SupervisorName => 256}`.
Explicit child options win; changes apply when the supervisor starts.
The standalone `lemon_ai` package uses the same policy under its own
`:lemon_ai` application configuration, without depending on core.
Core's private doctor supervisor instead caps each invocation at its job count.
`start_child/3`, `async/3` and `async_nolink/3` return tagged success or
`:task_capacity_reached` / `:task_supervisor_unavailable` admission errors.
Rejected work has not run and is not automatically retried. Other supervisor
exits retain the caller's existing unknown-outcome handling: losing the
admission reply does not prove that a task's side effects never began.

## Architecture Overview

```
                   +-----------------------+
                   |    LemonCore.Config   |  TOML parsing, env overrides,
                   |  .Modular / .Providers|  hot reload, validation
                   +-----------+-----------+
                               |
                   +-----------+-----------+
                   |  LemonCore.ConfigCache |  ETS cache with mtime-based
                   |  LemonCore.ConfigReloader| invalidation + FileSystem watcher
                   +-----------+-----------+
                               |
          +--------------------+--------------------+
          |                    |                    |
+---------+--------+ +--------+--------+ +---------+--------+
| LemonCore.Secrets| | LemonCore.Store | | LemonCore.Bus    |
| .Crypto/.External| | .EtsBackend     | | (Phoenix.PubSub) |
| .Source/.Runner  | | .SqliteBackend  | |                  |
| .MasterKey       | |                 | | LemonCore.Event  |
+------------------+ | .ReadCache      | +------------------+
                     +-----------------+
                               |
          +--------------------+--------------------+
          |                    |                    |
+---------+--------+ +--------+--------+ +---------+--------+
| LemonCore.       | | LemonCore.      | | LemonCore.       |
| Idempotency      | | ExecApprovals   | | Introspection    |
+------------------+ +-----------------+ +------------------+
          |
+---------+--------+
| LemonCore.       |
| RouterBridge     |  Runtime bridge to :lemon_router
| SessionKey       |  without compile-time coupling
| RunRequest       |
| InboundMessage   |
+------------------+
```

## Supervised Process Tree

`LemonCore.Application` starts these children under a `:one_for_one` supervisor:

| # | Child | Purpose |
|---|-------|---------|
| 1 | `LemonCore.RuntimeCache` | ETS owner for runtime registrations, cache metadata and warning flags |
| 2 | `LemonCore.Dedupe.Supervisor` | Dynamic supervisor for each named deduplication table's owner |
| 3 | `Phoenix.PubSub` (name: `LemonCore.PubSub`), or a `Registry` | Backbone for the Bus; see `LemonCore.Bus` for which one is used |
| 4 | `LemonCore.Drain` | Coordinated shutdown and directly readable phase ETS table |
| 5 | `LemonCore.ACPClientBridge` | Registry for direct ACP client request/reply |
| 6 | `LemonCore.NodeRegistry` | Socket-owned unique Registry, retained generation floors and temporary per-invocation processes |
| 7 | `LemonCore.ConfigCache` | ETS-backed config cache with TTL fingerprinting |
| 8 | `LemonCore.Store` | Key-value storage GenServer with pluggable backends and owned read-cache tables |
| 9 | `LemonCore.RuntimeOwner` | Cross-VM ownership lock of a file-backed store; only its holder reconciles other runtimes' records |
| 10 | `LemonCore.UsageLedger` | Finished-run usage aggregation |
| 11 | `LemonCore.ExecApprovalExpiry` | Expiry for approvals whose run or session ended |
| 12 | `LemonCore.Secrets.SourceTaskSupervisor` | Owns bounded external-source tasks |
| 13 | `LemonCore.Secrets.SourceCache` | Bounded optional process-local source cache |
| 14 | `LemonCore.RunHistoryStore` | Run history persistence (only when `:exqlite` is available) |
| 15 | `LemonCore.ConfigReloader` | Reload orchestrator with diff computation |
| 16 | `LemonCore.ConfigReloader.Watcher` | FileSystem watcher for `config.toml` and `.env` |

One-shot commands boot a client tree instead (`config :lemon_core, :boot_mode`,
set by `LemonCore.CLI.start/2`): no `RuntimeOwner`, `RunHistoryStore`,
`ConfigReloader`, `Watcher` or `Drain` (no SIGTERM trap), Store sweeps off, and
`ExecApprovalExpiry` with `recover: false`; see `LemonCore.Application`.

`config :lemon_core, :services` selects service groups: `:core` (always:
`RuntimeCache`, `RuntimeLatch`, dedupe, the Bus, `ConfigCache`, `Store` and the
secrets helpers), `:runtime_control` (`Drain`, `ACPClientBridge`,
`NodeRegistry`, `RuntimeOwner`, `SessionActivity`, `UsageLedger`,
`ExecApprovalExpiry`, the config reloader) and `:run_history`
(`RunHistoryStore`). Unset starts every group. A library consumer that only uses
the agent and store APIs can start just the core:

```elixir
config :lemon_core, :services, [:core]
```

A product that cannot run without durability or a group lists it in
`config :lemon_core, :required_capabilities` (`:durable_store`, `:run_history`,
`:runtime_control`); lemon_core then refuses to start, logging the fix, when one
is unavailable. See `LemonCore.Capabilities`.

Named-node sockets register themselves, so Registry removes dead connections
without node-monitor bookkeeping. Each temporary `LemonCore.NodeInvocation` owns
its timeout, recipient/socket monitors, sequence validation and controls.
Streamed events and shell frames go directly to it rather than through a shared
GenServer. Disconnect, replacement, timeout and caller death remain terminal;
the authenticated connection generation and retained generation floor prevent
stale frames or controls from crossing a reconnect. WebSocket/JSON is unchanged.

Durable memory moved to `lemon_memory`, the workspace stores to `lemon_agent`,
and provider credential-pool rotation to `lemon_agent`
(`LemonAgent.ModelRuntime.ProviderPoolRotator`); each supervises its own
processes.

Browser, media-job, and LSP drivers live in `lemon_browser`, `lemon_media`,
and `lemon_lsp`. Core doctor diagnostics may probe them at runtime, but
`lemon_core` must not depend on those apps.

## Module Inventory

### Configuration

| Module | Purpose |
|--------|---------|
| `LemonCore.Config` | Canonical TOML config loader with global/project merge and env overrides |
| `LemonCore.Config.Modular` | Newer typed config interface delegating to per-domain sub-modules |
| `LemonCore.Config.Providers` | LLM provider config (API keys, base URLs, secret refs, OAuth) |
| `LemonCore.Config.Secrets` | Exact configuration for explicitly enabled external secret sources |
| `LemonCore.Config.Agent` | Agent behavior settings sub-module |
| `LemonCore.Config.Gateway` | Gateway settings sub-module |
| `LemonCore.Config.Tools` | Web tools and WASM config sub-module |
| `LemonCore.Config.TUI` | Terminal UI theme and debug sub-module |
| `LemonCore.Config.Logging` | Log file and rotation sub-module |
| `LemonCore.Config.Automation` | `[automation]` cron catch-up/retention and `[cron]` failure-alert sub-module |
| `LemonCore.Config.Validator` | Validation for both legacy and modular config structs |
| `LemonCore.Config.ValidationError` | Raised by `Config.Modular.load!/1` on invalid config |
| `LemonCore.Contract` | Validates configuration-injected modules for loadability and required behaviour callbacks |
| `LemonCore.Config.Helpers` | Shared config parsing helpers |
| `LemonCore.Config.TomlPatch` | Textual TOML editing for targeted key upserts |
| `LemonCore.Config.LegacyAgentMigration` | Maps a deprecated `[agent]` table onto `[defaults]`/`[runtime]`/`[tui]` (load alias and file rewrite) |
| `LemonCore.ConfigCache` | ETS cache with mtime/size fingerprint-based invalidation |
| `LemonCore.ConfigCacheError` | Raised when ConfigCache is unavailable |
| `LemonCore.ConfigReloader` | Central reload orchestrator with digest diffing and Bus broadcast |
| `LemonCore.ConfigReloader.Digest` | File/env/secrets digest computation |
| `LemonCore.ConfigReloader.Watcher` | FileSystem watcher targeting config.toml and .env paths |
| `LemonCore.Setup.Readiness` | Read-only first-run readiness shared by setup, TUI, Web, and launchers |
| `LemonCore.GatewayConfig` | Unified gateway config access merging TOML, app env, and transport overrides |
| `LemonCore.A2A.Protocol` / `LemonCore.A2A.Client` | Generic A2A v1.0 wire shapes and credential-scrubbing HTTP client |
| `LemonCore.A2AStore` | Typed persistent A2A contexts, default peer conversations, tasks, and message history |
| `LemonCore.Dotenv` | `.env` file loader preserving existing env vars |
| `LemonCore.Logging` | Runtime log-to-file handler from `[logging]` config |
| `LemonCore.OAuth.LocalCallbackListener` | One-shot localhost OAuth callback capture with monitored listener failure and bounded wait/cleanup |

### Doctor and Support

| Module | Purpose |
|--------|---------|
| `LemonCore.Doctor.SupportBundle` | Doctor report, build metadata, parsed config and diagnostics ZIP writer; `collect/1` builds the sections in the runtime they describe (the daemon serves them as `doctor.bundle`) |
| `LemonCore.Doctor.Redaction` | The one redaction pass for everything doctor shares (bundle entries, `doctor --json`, `doctor.run`): paths become a hash and existence flag or `[path]`, chat/guild/channel/user/session id fields are dropped, credential fields and non-JSON terms are masked |
| `LemonCore.Doctor.ProviderDiagnostics` | Provider setup/routing diagnostics for support bundles without raw API keys, secret names, base URLs, env var names, prompts, or provider responses |
| `LemonCore.Doctor.Checks.Usage` | Usage aggregate and quota-pressure check backed by redacted shared usage diagnostics |

`mix lemon.doctor` includes `usage.status`, which reads the same redacted
aggregate usage diagnostics and warns when configured run, token, or cost
limits are exceeded.

Checks for domains owned by other apps live in those apps and register through
`config :lemon_core, :doctor_checks` (memory: `LemonMemory.Doctor.Checks.Memory`;
skills: `LemonSkills.Doctor.Checks.Skills`; channels and automation likewise).

### Secrets

| Module | Purpose |
|--------|---------|
| `LemonCore.Secrets` | Encrypted secrets API and store/external/environment resolution |
| `LemonCore.Secrets.Crypto` | AES-256-GCM encryption with HKDF-SHA256 key derivation |
| `LemonCore.Secrets.EnvCatalog` | Ordered environment-secret catalog for packaged and Mix check/import commands |
| `LemonCore.Secrets.External` | Ordered, supervised, fail-closed external-source orchestration and redacted diagnostics |
| `LemonCore.Secrets.Source` | Read-only source behaviour implemented by 1Password, Bitwarden, and command adapters |
| `LemonCore.Secrets.SourceRunner` | Minimal-environment argv runner with timeout and output caps |
| `LemonCore.Secrets.SourceCache` | Bounded optional process-local TTL cache |
| `LemonCore.Secrets.Keychain` | macOS Keychain integration for master key storage |
| `LemonCore.Secrets.MasterKey` | Master key resolution chain (keychain -> env var) |

`LemonCore.Redact` is the common credential policy: `text/1` masks assignments,
Bearer/Basic authorization, provider keys, JWTs, and PEM private keys; `map/1`
also masks sensitive-key values recursively through maps, structs, lists, and
tuples. Structs become plain maps. `sensitive_key?/1` accepts atom/string keys.
Redaction is idempotent and does not truncate output.

Use `text(text, count: true)` for `{redacted_text, replacement_count}`,
`drop_keys: true` when secret names must also be omitted, and `strict: true`
for portable profile/config exports that also omit full sensitive assignment
lines and unlabelled hex keys. Keep caller-specific content allowlists, URL/path
omission, collection/depth/byte bounds, and bounded error summaries: credential
redaction alone does not make arbitrary data safe to export. Redact before
truncating so partial credentials cannot escape.

### Storage

| Module | Purpose |
|--------|---------|
| `LemonCore.Store` | Generic table GenServer with pluggable backends plus the serialized run lifecycle (append/finalize) |
| `LemonCore.RunStore` | Typed run lifecycle/history wrapper over `:runs` and `:sessions_index`; finalization is synchronous and retry-safe |
| `LemonCore.ChatStateStore` | Per-scope chat state in `:chat` with a 24h expiry |
| `LemonCore.Store.Backend` | Behaviour for storage backends (init/put/put_new/get/delete/list) |
| `LemonCore.Store.EtsBackend` | In-memory ETS backend (ephemeral, default) |
| `LemonCore.Store.SqliteBackend` | SQLite backend with WAL mode and optional ephemeral tables |
| `LemonCore.Store.ReadCache` | Public ETS read-through cache for hot domains |
| `LemonCore.PolicyStore` | Typed policy API and metadata owner for the existing agent, channel, session, and runtime policy tables |
| `LemonCore.ToolPolicy` | Strict validated tool authorization shared by every execution boundary |
| `LemonCore.ExecutionContext` | Versioned identity, provenance, policy, workspace, capability, and limit authority for root and child runs |

### Memory

Durable memory moved to the `lemon_memory` app (`LemonMemory.*`). Core reaches
it only through the `LemonCore.Store` finalize-run hook the runtime configures.

### Event System

| Module | Purpose |
|--------|---------|
| `LemonCore.Bus` | PubSub wrapper with topic helpers |
| `LemonCore.Event` | Canonical event struct (type, ts_ms, payload, meta) |
| `LemonCore.ChatState` | Sticky execution state for auto-resume across router/gateway/channel boundaries |
| `LemonCore.EventBridge` | Cross-app event translation |

### Routing and Sessions

| Module | Purpose |
|--------|---------|
| `LemonCore.SessionKey` | Session key generation and parsing |
| `LemonCore.RouterBridge` | Runtime bridge to `:lemon_router` without compile-time coupling |
| `LemonCore.RunRequest` | Canonical run submission struct |
| `LemonCore.InboundMessage` | Normalized inbound message from any channel |
| `LemonCore.Binding` | Struct mapping transport/chat/topic to project config |
| `LemonCore.BindingResolver` | Binding resolution logic |
| `LemonCore.ChatScope` | Chat scope struct |
| `LemonCore.ResumeToken` | Resume token for session continuity |
| `LemonCore.NativeSessionOwner` | First-write-wins binding of a native session to the session key that created it; resume admission and chat checkpoint access require it |

### Operations

| Module | Purpose |
|--------|---------|
| `LemonCore.Capabilities` | Capabilities a product requires at boot (`:durable_store`, `:run_history`, `:runtime_control`); checked before the tree starts |
| `LemonCore.Idempotency` | At-most-once execution backed by Store; done results expire after 24h, unresolved claims never expire |
| `LemonCore.ExecApprovals` | Tool execution approval flow with scope-based persistence |
| `LemonCore.Checkpoint` | Shared checkpoint store plus filesystem diff/restore and lifecycle events; interactive restores need a random single-use preview token held server-side (`:checkpoint_restore_confirmations`), bound to caller, checkpoint revision, roots and tree fingerprint, with a five-minute TTL |
| `LemonCore.Introspection` | Canonical introspection event builder and persistence |
| `LemonCore.UsageStore` | Shared typed wrapper for usage records, current usage summaries, and quota counters |
| `LemonCore.UsageDiagnostics` | Redacted aggregate usage diagnostics shared by doctor checks and support bundles |
| `LemonCore.Dedupe.Ets` | Low-level ETS-backed TTL deduplication |

### Utilities

| Module | Purpose |
|--------|---------|
| `LemonCore` | Root module with module list |
| `LemonCore.Id` | UUID and unique ID generation |
| `LemonCore.Clock` | Time utilities (monotonic timestamps) |
| `LemonCore.Httpc` | `:httpc` wrapper ensuring `:inets`/`:ssl` started |
| `LemonCore.MapHelpers` | Map key access helpers (atom/string agnostic) |
| `LemonCore.Telemetry` | Telemetry event helpers and named event emitters |
| `LemonCore.FileAccess` | Shared root containment for chat `/file` transfers and the gateway send-file tools: symlink-free descriptor-bound walk below a physical root, case-insensitive built-in and `deny_globs` denies, identity-checked reads, private copies for queued attachments |
| `LemonCore.ConfinedFS` | Descriptor-bound file operations below a trusted root (port helper `priv/lemon_confined_fs`, built from `c_src/` during `mix compile`): no-follow directory walks (`openat2` `RESOLVE_BENEATH` on Linux), reads, exclusive creates, private-staging atomic replaces, appends, in-place overwrites, rename, unlink, tree removal and chmod relative to walked handles. Inside the Lemon umbrella (and therefore every release) the helper is required and `mix compile` fails without a C compiler and `make`. As a Hex dependency it is built when they are present; otherwise `ConfinedFS.available?/0` is `false` and every operation returns `{:error, :helper_unavailable}`, so confined callers (FileAccess, Checkpoint filesystem restore) fail closed instead of using path-based I/O |
| `Lemon.Reload` | Published low-level BEAM/extension reload API; see its moduledoc for retained contracts |
| `LemonCore.CodeReload` | Soft-loads changed BEAM files and invokes the configured session refresher for source-development reload |
| `LemonCore.TerminalBackend` / `TerminalBackends` / `TerminalBackendPolicy` | Shared terminal/process backend contract, registry, policy, and redacted diagnostics |

### Quality

| Module | Purpose |
|--------|---------|
| `LemonCore.Quality.DocsCheck` | Local markdown link check for tracked `docs/**/*.md` |
| `LemonCore.Quality.ArchitectureCheck` | `deps/0` direct-dependency policy check |
| `LemonCore.Quality.ArchitectureDocs` | Generated dependency-policy section in `docs/architecture_boundaries.md` |

### Mix Tasks

| Task | Purpose |
|------|---------|
| `mix lemon.config` | Validate and show configuration |
| `mix lemon.secrets.init` | Generate master key |
| `mix lemon.secrets.status` | Show secrets status |
| `mix lemon.secrets.list` | List secrets metadata |
| `mix lemon.secrets.set` | Store a secret |
| `mix lemon.secrets.delete` | Delete a secret |
| `mix lemon.secrets.check` | Check secrets health |
| `mix lemon.secrets.import_env` | Import env vars as secrets |
| `mix lemon.secrets.rotate_key` | Preview, then (`--confirm TOKEN`) rotate the master key and re-encrypt secrets |
| `mix lemon.onboard` | Top-level provider onboarding picker with interactive TUI selection |

Provider onboarding `preferred_models` should favor stable models that actually
work on Lemon's live transport path. Do not keep known-broken variants in those
default suggestions just because the upstream provider documents them.
| `mix lemon.onboard.anthropic` | Anthropic provider setup |
| `mix lemon.onboard.antigravity` | Antigravity (Google) provider setup with OAuth |
| `mix lemon.onboard.gemini` | Google Gemini CLI / Code Assist setup with OAuth |
| `mix lemon.onboard.codex` | OpenAI Codex provider setup with OAuth and localhost callback capture |
| `mix lemon.onboard.copilot` | GitHub Copilot provider setup with OAuth |
| `mix lemon.quality` | Run all quality checks |
| `mix lemon.store.migrate_jsonl_to_sqlite` | Migrate JSONL to SQLite |
| `mix lemon.introspection` | Query introspection events |
| `mix lemon.check_duplicate_tests` | Check for duplicate test names |

## Configuration System

### Config Sources (precedence: env > project > global)

1. **Global**: `~/.lemon/config.toml`
2. **Project**: `<cwd>/.lemon/config.toml`
3. **Environment**: `LEMON_*` and provider-specific variables override both

### Config Sections

- `providers` -- LLM API keys and base URLs (anthropic, openai, openai-codex, opencode, kimi, google)
- `defaults` -- Preferred home for default provider/model/thinking level/engine
- `runtime` -- Runtime behavior (compaction, retry, shell, tools, cli, extensions, theme)
- `profiles` -- Per-agent identity/model/node defaults and tool policies. The
  user-managed lifecycle lives in `LemonCore.ProfileStore`, with derived homes
  at `~/.lemon/profiles/<id>/` and stable `agent:<id>:main` session keys.
- `agent` -- Legacy alias for runtime/default settings (still supported)
- `agents` -- Legacy alias for profile settings (still supported)
- `tui` -- Theme, debug mode
- `logging` -- File logging, level, rotation
- `gateway` -- Max concurrent runs, engine bindings, SMS/email/webhook settings, plus per-platform `[gateway.<id>]` sections resolved by their own app (see `LemonCore.Config.Gateway.Channel`)

### Access Patterns

```elixir
# Cached read (default hot path) - uses ConfigCache when available
config = LemonCore.Config.load(cwd)

# Force reload from disk (updates cache)
config = LemonCore.Config.reload(cwd)

# Access nested values
provider = LemonCore.Config.get(config, [:agent, :default_provider], "anthropic")

# Modular config interface (typed sub-structs, validation)
config = LemonCore.Config.Modular.load(project_dir: cwd)
config = LemonCore.Config.Modular.load!(project_dir: cwd)
{:ok, config} = LemonCore.Config.Modular.load_with_validation(project_dir: cwd)
```

### Hot Reload Flow

```
LemonCore.ConfigReloader.reload/1
  |-- Acquire reload lock
  |-- Compute file/env/secrets digests
  |-- Compare with cached digests
  |-- Reload .env if changed
  |-- Reload TOML via LemonCore.Config.reload/2
  |-- Compute redacted diff vs previous snapshot
  |-- Update ConfigCache
  |-- Broadcast :config_reloaded on "system" topic
  |-- On failure: keep last good snapshot, emit :config_reload_failed
```

### First-run readiness

`LemonCore.Setup.Readiness.status/1` derives one shared readiness state from the
global config, secrets backend, default provider/model, and credential source.
It never performs a network request or mutates setup state. Clients use
`pending_steps/1` and `ready?/1` so a setup wizard, first-run gate, or browser
cannot silently invent a different definition of “ready.” Live provider
verification remains in `lemon_cli` and doctor diagnostics.

### Environment Variable Overrides

| Env Var | Overrides |
|---------|-----------|
| `LEMON_DEFAULT_PROVIDER` | `defaults.provider` |
| `LEMON_DEFAULT_MODEL` | `defaults.model` |
| `LEMON_PROVIDER_ROUTING_ENABLED` | `runtime.provider_routing.enabled` |
| `LEMON_PROVIDER_FALLBACK_PROVIDERS` | `runtime.provider_routing.fallback_providers` |
| `LEMON_PROVIDER_ROUTING_REQUIRE_CREDENTIALS` | `runtime.provider_routing.require_credentials` |
| `LEMON_TUI_DEBUG` | `tui.debug` |
| `LEMON_TUI_THEME` | `tui.theme` |
| `LEMON_LOG_FILE` | `logging.file` |
| `LEMON_LOG_LEVEL` | `logging.level` |
| `LEMON_WASM_ENABLED` | `runtime.tools.wasm.enabled` |
| `LEMON_WASM_RUNTIME_PATH` | `runtime.tools.wasm.runtime_path` |
| `LEMON_WASM_TOOL_PATHS` | `runtime.tools.wasm.tool_paths` |
| `LEMON_WASM_AUTO_BUILD` | `runtime.tools.wasm.auto_build` |
| `LEMON_BROWSER_DRIVER_PATH` | Path to local browser driver JS file |
| `ANTHROPIC_API_KEY` | `providers.anthropic.api_key` |
| `ANTHROPIC_TOKEN` | Ambient Anthropic OAuth token when `providers.anthropic.auth_source = "oauth"` |
| `CLAUDE_CODE_OAUTH_TOKEN` | Ambient Claude Code OAuth token when `providers.anthropic.auth_source = "oauth"` |
| `OPENAI_API_KEY` | `providers.openai.api_key` |
| `OPENAI_CODEX_API_KEY` | `providers.openai-codex.api_key` |
| `GOOGLE_GENERATIVE_AI_API_KEY` | `providers.google.api_key` |
| `GOOGLE_GEMINI_CLI_API_KEY` | `providers.google_gemini_cli.api_key` (JSON credential payload) |
| `LEMON_GEMINI_PROJECT_ID` | Runtime override for `providers.google_gemini_cli.project_id` |

## Secrets Management

### Storage Model

Secrets are encrypted at rest with AES-256-GCM. Per-secret encryption keys are derived via HKDF-SHA256 from a master key and a random 32-byte salt. The ciphertext, nonce, and salt are base64-encoded and stored in the `:secrets_v1` Store table.

### Master Key Resolution (in order)

1. macOS Keychain (`Lemon Secrets` service, `default` account) -- preferred
2. `LEMON_SECRETS_MASTER_KEY` environment variable -- fallback
3. `~/.lemon/secrets_master_key` file -- local non-keychain fallback
4. Fail with `:missing_master_key`

The order and the locations are configurable via `config :lemon_core, LemonCore.Secrets, key_providers: [:keychain, :env, :file], key_file: ..., env_var: ...`; see `LemonCore.Secrets.KeyProvider`. The key must be base64-encoded 32 bytes.

For local Linux/dev usage, treat `~/.lemon/secrets_master_key` as the canonical master key file. Every entry point (`./bin/lemon`, the release, CLI, Mix, runtime) resolves the same provider chain; launchers never export the key file, and a stale `LEMON_SECRETS_MASTER_KEY` holding a different key makes resolution fail with `{:conflicting_master_keys, sources}` instead of silently winning or losing. See [the secrets contract](../../docs/security/secrets-and-keychain.md).

To change the master key without re-entering secrets, run `lemon secrets rotate-key` (or `mix lemon.secrets.rotate_key`): it previews, then with the preview's `--confirm` token re-encrypts every stored secret under a new key and writes that key to the Keychain entry or key file that supplied the old one. See `LemonCore.Secrets.KeyRotation` and [the secrets contract](../../docs/security/secrets-and-keychain.md#master-key-rotation).

### API

```elixir
# Store a secret
{:ok, metadata} = LemonCore.Secrets.set("api_key", "secret_value", provider: "manual")

# Retrieve a secret
{:ok, value} = LemonCore.Secrets.get("api_key")

# Resolve (store first, then external sources, then env fallback)
{:ok, value, :store} = LemonCore.Secrets.resolve("api_key")
{:ok, value, "external:command:local_helper"} = LemonCore.Secrets.resolve("api_key")
{:ok, value, :env} = LemonCore.Secrets.resolve("MISSING_FROM_STORE")

# Convenience (returns value or nil)
value = LemonCore.Secrets.fetch_value("ANTHROPIC_API_KEY")

# Check existence
exists? = LemonCore.Secrets.exists?("api_key")

# List (metadata only, no values)
{:ok, metadata_list} = LemonCore.Secrets.list()

# Delete
:ok = LemonCore.Secrets.delete("api_key")

# Status
status = LemonCore.Secrets.status()
```

External sources are read-only fallbacks behind the encrypted store and ahead
of environment variables. They are disabled unless their config contains the
exact boolean `enabled = true`. Enabled-source failures stop resolution before
environment fallback; a source that succeeds without the requested name may
continue. Use `env_fallback: false` to disable both external and environment
fallbacks. Secret reads update usage metadata (`usage_count`, `last_used_at`)
without mutating `updated_at`.

1Password, Bitwarden Secrets Manager, and arbitrary argv-only command adapters
share one supervised runner with exact config validation, minimal child
environments, stable redacted errors, and configured time/output limits. The
optional bounded process-local cache defaults off. Inspect or live-test them
without revealing values:

```bash
lemon secrets sources status --json
lemon secrets sources test [source-id] --json
```

See [`docs/config.md`](../../docs/config.md#external-secret-sources) for the
exact source schemas and bootstrap rules.

`LemonCore.Secrets.EnvCatalog.names/0` is the canonical ordered set used by
the packaged `lemon secrets check` / `lemon secrets import-env` commands and
their Mix equivalents. It is intentionally separate from the release-profile
runtime declarations in `LemonCore.Env`.

## Storage Backends

### When to Use Each

| Backend | Persistence | Use Case |
|---------|-------------|----------|
| `EtsBackend` | No (in-memory) | Tests, ephemeral data, default |
| `SqliteBackend` | Yes (single file) | Production, WAL mode, optional ephemeral tables for high-churn |

### Upgrading legacy JSONL installations

The JSONL runtime backend migration window ends with `lemon_core` 0.3.0.
It is removed now (issue #608); SQLite is the supported durable backend.
This is a breaking package change from 0.2.x.

Before upgrading, stop runtime writers, back up the JSONL store directory,
and run the migration using the old source checkout:

```bash
mix lemon.store.migrate_jsonl_to_sqlite --jsonl-path /var/lib/lemon/store --sqlite-path /var/lib/lemon/store.sqlite3 --dry-run
mix lemon.store.migrate_jsonl_to_sqlite --jsonl-path /var/lib/lemon/store --sqlite-path /var/lib/lemon/store.sqlite3
```

Use a new target database; `--replace` deletes an existing target. Add
`--include-runs` if run records must be retained (they are skipped by default),
and configure `ephemeral_tables: []` if SQLite must keep them after startup.
Switch the Store configuration to SQLite as below, verify the migrated data,
then upgrade. Keep the original backup until verification is complete.
The migration task remains available in 0.3.0 with a private read-only legacy
reader for recovery; it does not restore a JSONL runtime backend or modify the
source journals. Only migrate trusted local journals.

### Configuration

```elixir
# config/config.exs
config :lemon_core, LemonCore.Store,
  backend: LemonCore.Store.SqliteBackend,
  backend_opts: [path: "/var/lib/lemon/store.sqlite3"]
```

### Wrapper-First Table Access

```elixir
defmodule MyApp.WidgetStore do
  @table :widgets

  def put(id, widget), do: LemonCore.Store.put(@table, id, widget)
  def claim(id, widget), do: LemonCore.Store.put_new(@table, id, widget)
  def get(id), do: LemonCore.Store.get(@table, id)
end

MyApp.WidgetStore.put(id, widget)
widget = MyApp.WidgetStore.get(id)
```

`put_new/3` is the insert-if-absent primitive for durable claims. It returns `:ok` for the first writer and `{:error, :exists}` for later writers without overwriting the original value. `take/2` atomically consumes a key, `compare_and_swap/4` replaces a value only when its exact expected value is still current, and `compare_and_delete/3` conditionally removes an exact snapshot so a sweeper cannot erase a renewed lease or receipt. `compare_and_delete_many/1` first validates a set of exact snapshots in one serialized Store call. SQLite commits the set transactionally, ETS applies it under the Store owner, and ordered backends report the first failure so callers can place a safety-critical durable fence last.

Store calls are fail-soft: if the GenServer is overloaded/unavailable, write APIs return `{:error, :store_unavailable}` and ordinary read/list APIs return `nil`/`[]`. `get/3` and `list/2` are for genuinely optional or display data only and are never an admission, policy, idempotency or verification check. Correctness-sensitive callers use `fetch/3` and `fetch_all/2` to distinguish confirmed absence or an empty table from an unavailable backend.

Whole-table and range reads (`fetch_all/2`, `fetch_keys/2`, `fetch_range/5`, `list/2`, introspection listing) take a read handle from the Store in one short call and then read the backend in the caller's process — SQLite through a private read-only WAL connection — so a large scan never stalls other Store callers. `fetch_range/5` returns rows whose map value has an integer `:at_ms` in `[from, to)` (optionally plus untimed rows); SQLite indexes `:at_ms`. `:runs` cannot be read whole: read runs by id.

For power-loss-sensitive writes, pass `durable: true` to the explicit-server
mutation arity, for example
`LemonCore.Store.put(LemonCore.Store, :receipts, id, receipt, durable: true)`.
The option is also available on `put_new`, `compare_and_swap`, `delete`,
`compare_and_delete`, `compare_and_delete_many` and `take` (which returns the
removed value only after the barrier). SQLite scopes FULL
synchronization (and Darwin fullfsync) to that mutation, restoring NORMAL for
ordinary writes. Other backends sync before acknowledgement. A failed durable
mutation returns `{:error, :outcome_unknown}` rather than permission to retry;
confirmed `:exists` and `:mismatch` remain distinct. SQLite authority reads use
`Store.confirm_durable/1` without a checkpoint; ordered backends still sync so a
visible row from an earlier failed barrier cannot falsely acknowledge success.
`Store.sync/1` remains the explicit checkpoint barrier for a graceful-drain seal.
Store diagnostics hash keys for idempotency tables so caller replay secrets do not enter logs.

The JSONL backend fails initialization if journal discovery or any selected table
cannot be read or replayed. A malformed line or undecodable persisted term is
corruption, not an ignorable record; no valid prefix becomes authoritative.
Lazy access returns a bounded `{:jsonl_unavailable, classification}` backend
error and leaves the failed table unloaded. Repair the file, then access it again
to reload it; a startup failure requires starting the Store again after repair.
Only a confirmed missing table reads as empty. Failed loads never append to or
truncate the journal. Encoding and append failures return errors before memory
or the read cache is updated, rather than crashing the Store. JSONL appends are
still unsynced: use `durable: true` for acknowledgement-sensitive writes, or
`Store.sync/1` for an explicit seal over preceding writes.
Diagnostics omit journal contents, raw paths and exception messages.

Use the generic table API only inside wrapper modules, backend internals, or explicitly app-local legacy tables. Shared-domain runtime code should go through typed wrappers so table ownership stays localized. Wrappers are plain modules over the generic API; `LemonCore.Store` has no domain-specific chat-state, policy, or progress functions.

### Specialized APIs

Shared-domain callers should prefer typed wrappers:

- **Chat state**: `LemonCore.ChatStateStore.put/2`, `get/1`, `fetch/1`, `delete/1`
  (each also takes a store name first); stamps a 24h `:expires_at` on write,
  treats expired entries as absent on read, and the store's periodic sweep
  removes expired `:chat` entries. `fetch` reports an unreadable store as
  `{:error, :store_unavailable}` instead of "no state"
- **Run history**: `LemonCore.RunStore.append_event/2`, `finalize/2`, `history/2`, `fetch_history/2`, `fetch_sessions/1`, `get/1`
- **Policies**: `LemonCore.PolicyStore.fetch_agent/1`, `fetch_channel/1`, `fetch_session/1`,
  `fetch_runtime/0` (strict: `{:ok, nil}` only for a confirmed absent row,
  `{:error, :store_unavailable}` otherwise; the router rejects admission with
  `:policy_unavailable`), `update_session/2` (compare-and-swap merge),
  `put_agent/2`, `put_channel/2`, `put_session/2`, `put_runtime/1`
- **Idempotency**: `LemonCore.IdempotencyStore.fetch/2`, `put_new/3`, `compare_and_swap/4`, `compare_and_delete/3`, `put/3`, `delete/2`
- **Introspection**: `LemonCore.IntrospectionStore.append/1`, `list/1`
- **Project bindings**: `LemonCore.ProjectBindingStore.get_override/1`, `put_override/2`, `delete_override/1` (per-scope selection of an operator-configured project id; projects come only from config)
- **Exec approvals**: `LemonCore.ExecApprovalStore.get_pending/1`, `put_pending/2`, policy getters/setters by scope

`RunStore.finalize/2` returns `:ok` only after the immutable final summary and
its session index are written. Retrying the same summary repairs a partial index
failure without double-counting the run: the session entry remembers its last
32 indexed run ids, so its size stays fixed however many runs the session has.
Finalize hooks execute after persistence in a monitored caller-side worker, not
inside the Store process. All hooks share a five-second budget, configurable via
`:lemon_core, :store_hook_budget_ms`. The worker is killed when that budget
expires; hooks are not automatically retried. Successful persistence still
returns `:ok` even when a hook fails or times out. Explicit finalization retries
can redeliver hooks, so implementations must be idempotent by run id.

The `:runs` table contains summaries and lifecycle metadata only. The Store
keeps events in a separate bounded per-run buffer (first 200 plus latest, 2,000
in all), so ordinary run reads do not copy it. The summary and frozen buffer
are swept `:runs_retention_ms` (default 24 hours) after finalization. A durable
marker in `:run_terminals` makes `RunStore.fetch/1` return `{:error, :evicted}`
for finished runs without a retained summary, including after a restart.
Durable per-session history is in `LemonCore.RunHistoryStore`. Usage pages read
only ledger occurrences, not `:runs`.

Goal and kanban coordination uses this Store but belongs to
`LemonAutomation.{GoalStore, KanbanStore}`. Heartbeats use automation cron jobs
and cron history.

### ReadCache

`LemonCore.Store.ReadCache` maintains public ETS tables for hot domains (`:runs`, plus the default cached tables `:sessions_index`, `:chat`, and `:progress`, plus tables collaborators add with `register_cached_table/1`). Reads bypass the GenServer entirely for O(1) ETS lookup, while writes go through the GenServer which updates both the backend and cache atomically.

This cache scope remains deliberately unchanged; expand it only when measurements
show a hot read path that benefits from caching.

The Store owns those tables; their references and the effective cached-domain
list live in `LemonCore.RuntimeCache`, not `:persistent_term`, because runtime
registration and Store restarts change them. Runtime hook registrations are
serialized by that separate supervised owner, retain order, deduplicate values
and survive registering-process exits and Store restarts. Registration before
an individual Store starts is supported once `:lemon_core` is running.

### Runtime ETS ownership

`LemonCore.Dedupe.Ets.init/1` starts a table owner under
`LemonCore.Dedupe.Supervisor`. Concurrent initialization is serialized, and the
first caller's exit no longer destroys the table. An owner crash recreates an
empty table; dedupe is still volatile and best-effort. Use durable idempotency
for replay fences.

Core's other named ETS tables belong to `ConfigCache`, `Drain`,
`NodeRegistry.Generations`, the individual Store, or `RuntimeCache`, all
supervised services. Test barriers use unnamed, creator-owned table references
instead of synthesizing named tables and atoms. RuntimeCache also holds
atomically claimed once-only warning flags and the lazily resolved process UID.
Its contents are volatile: its own restart clears registrations and metadata,
whereas a Store restart does not. Collaborators register again at application
startup. Drain's protected phase table disappears with its coordinator, so a
stopped coordinator cannot leave a stale `:stopping` value behind.

Core uses `:persistent_term` for boot/configuration publications and the
rotation-invalidated master-key cache:

| Writer | Retained immutable value |
| --- | --- |
| `LemonCore.Bus.child_spec_for_backend/0` | Backend selected while building the application supervision tree |
| `LemonCore.ConfigCache.init/1` | Cache timeout/fingerprint defaults for that configured instance |
| `LemonCore.ExecApprovalExpiry.init_runtime_id/0` | VM incarnation, initialized by the application callback and retained across worker restarts |
| `LemonCore.Secrets.MasterKey` | Resolved key material; invalidated under the secrets lease on initialization and rotation |

Ordinary Bus detection and approval-runtime reads never lazily publish. Public
dedupe, Drain, Store hook and listener API signatures are unchanged; the core
application supplies their ETS owners.

### Backend Behaviour

Implementing a new backend requires the `LemonCore.Store.Backend` behaviour:

```elixir
@callback init(opts()) :: {:ok, state()} | {:error, term()}
@callback put(state(), table(), key(), value()) :: {:ok, state()}
@callback put_new(state(), table(), key(), value()) :: {:ok, state()} | {:exists, state()} | {:error, term()}
@callback get(state(), table(), key()) :: {:ok, value() | nil, state()}
@callback delete(state(), table(), key()) :: {:ok, state()}
@callback list(state(), table()) :: {:ok, [{key(), value()}], state()}
```

SQLite serializes keys and values with `:erlang.term_to_binary/1`. The JSONL
backend uses a JSON codec that preserves atoms, tuples, structs, and nested map
keys for portable append-only files.

`LemonCore.Durable` owns stable-storage barriers. JSONL `sync/1` flushes every
table file and then its directory; acknowledgement requires every actual
barrier to succeed. Directories use OTP 29 raw directory descriptors and native
`file:sync`, without Python or GNU coreutils. Darwin directory sync provides
`F_BARRIERFSYNC`, not device-wide `F_FULLFSYNC`. File sync retains the packaged
Python 3 helper and `F_FULLFSYNC` on Darwin: Store journals, native-process
cleanup ledgers, paired-eval cleanup manifests and coding-session replacement
snapshots retain their stable-content guarantees. Paths are literal argv,
never shell commands; failed barriers remain errors.

## Event Bus

### Standard Topics

| Topic | Purpose |
|-------|---------|
| `"run:<run_id>"` | Run-specific events |
| `"session:<session_key>"` | Session-scoped events |
| `"channels"` | Channel lifecycle |
| `"cron"` | Cron/automation events |
| `"exec_approvals"` | Approval requests/resolutions |
| `"nodes"` | Node pairing/invocation |
| `"system"` | Config reload, global events |
| `"logs"` | Log streaming |

### Usage

```elixir
# Subscribe
LemonCore.Bus.subscribe("run:" <> run_id)

# Receive
receive do
  %LemonCore.Event{type: :delta, payload: payload} -> handle_delta(payload)
  %LemonCore.Event{type: :completed, payload: payload} -> handle_completion(payload)
after
  30_000 -> :timeout
end

# Broadcast
event = LemonCore.Event.new(:run_started, %{engine: "lemon"}, %{run_id: run_id})
LemonCore.Bus.broadcast("session:" <> session_key, event)

# Unsubscribe
LemonCore.Bus.unsubscribe("run:" <> run_id)
```

## Session Keys

Session keys provide stable identifiers for routing and state management.

### Formats

- Main: `agent:<agent_id>:main[:sub:<sub_id>]`
- Channel: `agent:<agent_id>:<channel_id>:<account_id>:<peer_kind>:<peer_id>[:thread:<thread_id>][:sub:<sub_id>]`

### Usage

```elixir
key = LemonCore.SessionKey.main("my_agent")
# => "agent:my_agent:main"

key = LemonCore.SessionKey.channel_peer(%{
  agent_id: "my_agent", channel_id: "demo",
  account_id: "bot123", peer_kind: :dm, peer_id: "user456"
})

%{agent_id: id, kind: :main} = LemonCore.SessionKey.parse(key)
```

## Execution Approvals

Tool execution gating with scope-based persistence. Placed in `lemon_core` so any app can request/resolve approvals without depending on `:lemon_router`.

### Scopes

| Scope | Persistence |
|-------|-------------|
| `:approve_once` | Not persisted (single request) |
| `:approve_session` | Persisted per session_key and optional private invocation context |
| `:approve_agent` | Persisted per agent_id and optional private invocation context |
| `:approve_global` | Persisted globally |

Context-owned team runs carry the trusted private `invocation_context_key`
through their native approval request. Session/agent grants are bound to both
the public identity and this exact principal/policy context: one teammate user's
grant cannot authorize another user or a changed policy on the same shared bot
session. Context-owned requests never fall back to legacy unscoped session/agent
grants. Nil-context native requests keep their original scope behavior; explicit
operator global/node grants remain independent. The typed pending record retains
the private key for owner policy writes, but direct JSON, wire approval events,
pending lists, resolution receipts and introspection never expose it.

```elixir
# Request (blocks until resolved)
case LemonCore.ExecApprovals.request(%{
  run_id: run_id, session_key: session_key,
  tool: "shell", action: %{command: "rm -rf /tmp/old"},
  expires_in_ms: 60_000
}) do
  {:ok, :approved, scope} -> proceed()
  {:ok, :denied} -> halt()
  {:error, :timeout} -> handle_timeout()
end

# Resolve (called by UI/admin). Compare and consume the exact owner identity.
{:ok, %{decision: :approve_session, outcome: :approved, replayed: false}} =
  LemonCore.ExecApprovals.resolve(approval_id, :approve_session,
    expected_session_key: session_key, expected_run_id: run_id)
```

Resolve, cancellation and timeout atomically replace the exact pending snapshot;
only the winner installs grants or emits resolution events. The resolution receipt
returns the actual decision/outcome and approval/run/session identity. Wrong
identity or changed previews (`expected_pending`) leave the live approval untouched.
Expired, cancelled, unknown and conflicting decisions return distinct errors.
Pending accessors exclude redacted terminal records. Retained completed state
allows the same decision to replay only when **both** expected identities match,
without new grants/events. An unbound repeated call is `:already_resolved`, not
an acknowledgement. Missing retained state is `:not_found`; IDs with retained
state cannot be reused for another invocation. A crash during policy installation
leaves an in-progress record that fails closed, never a fabricated completion.

Approval requests, resolutions, and timeouts also write redacted
`approval_*` introspection events with approval id, tool, action type/hash, and
decision/scope metadata. Raw action payloads, prompts, and secrets are not
stored in the timeline. Timeouts also broadcast `:approval_resolved` with
`decision: :timeout` so operator clients can clear stale pending requests live.

### Owner expiry

A pending approval belongs to the run (`:run_id`) and native session
(`:session_id`) that requested it. When that owner ends, nobody can use the
answer, so the approval expires immediately: there is no grace window, and it
applies to requests with `expires_in_ms: :infinity` too.

```elixir
{:ok, count} = LemonCore.ExecApprovals.expire_owner({:run, run_id})
{:ok, count} = LemonCore.ExecApprovals.expire_owner({:session, session_id})
```

Each match atomically becomes a redacted `:expired` receipt (the same exact-record
transition as resolve, cancel and timeout, so there is one winner), a live waiter
receives `{:ok, :denied}`, no policy is installed and `:approval_resolved` is
broadcast with `decision: :expired` (time-based expiry keeps `:timeout`). A later
`resolve/3` returns `{:error, :expired}`; it cannot approve. An
`:approval_expired` introspection event records id, tool and owner kind.

`LemonCore.ExecApprovalExpiry` observes every successful Store run finalization,
including runs without a session-history key, and monitors native session
processes independently of `terminate/2`, including forced shutdown. Store hooks
only cast asynchronously, avoiding recursive Store calls. Retained SQLite
requests from an earlier daemon incarnation expire during recovery before they
can be resolved, but only in the VM that owns the store (`LemonCore.RuntimeOwner`):
a second runtime on the same database leaves them alone, and one-shot client VMs
never recover. Recovery runs in `handle_continue/2` and retries with backoff when
the store is unavailable. Run and session end read only that owner's approvals
through `ExecApprovalStore`'s owner index, and terminal receipts are swept after
24 hours. Restarting only the expiry worker preserves live owners and
restores session monitors; it does not start a new daemon incarnation.

## Idempotency

At-most-once execution backed by the Store. A key is claimed atomically
(`pending`), then completed by compare-and-swap (`done`); concurrent callers
never both execute. An unreadable Store is `{:error, :store_unavailable}`,
never a miss. Completed results expire after 24h. A pending claim never
expires and is never swept (it has no `"inserted_at_ms"`): its outcome may be
unknown, so it keeps its key and metadata (for example a fixed run ID) until a
caller reconciles it authoritatively with `complete/2` or `release/1` on the
claim `begin/3` returns as `{:pending, claim}` (`meta/1` reads its metadata).

```elixir
{:ok, result} = LemonCore.Idempotency.execute("messages", msg_id, fn ->
  perform_operation()
end)
```

Callers that must release a claim after a definite failure, or reconcile an
earlier unresolved claim, use `begin/3`, `complete/2` and `release/1`.

## Introspection

Canonical event persistence with redaction for tool arguments and sensitive fields.

```elixir
:ok = LemonCore.Introspection.record(:tool_completed,
  %{tool_name: "exec", result_preview: "ok"},
  run_id: run_id, session_key: session_key, engine: "codex"
)

events = LemonCore.Introspection.list(run_id: run_id, limit: 50)
```

## RouterBridge

Channel adapters forward runs to `:lemon_router` without compile-time coupling. The router registers itself at startup.

```elixir
{:ok, run_id} = LemonCore.RouterBridge.submit_run(run_request)
:ok = LemonCore.RouterBridge.abort_session(session_key, :user_requested)
{:ok, busy?} = LemonCore.RouterBridge.session_busy?(session_key)
{:ok, active_run_id} = LemonCore.RouterBridge.active_run(session_key)
{:ok, sessions} = LemonCore.RouterBridge.list_active_sessions()
```

An unregistered router returns `{:error, :unavailable}`. A configured mutating
callback that raises, throws, returns a malformed acknowledgement, times out,
or exits returns `{:error, :outcome_unknown}`: even a `:noproc` exit may follow
an earlier side effect inside a multi-step callback. Callers must not retry
automatically without independent idempotency or reconciliation. Read-only
query exits and throws remain unavailable because they cannot duplicate a side
effect. Query calls do not substitute `false`, `:none`, or `[]`; callers must
handle unknown router state explicitly. Query exceptions return the sanitized
`{:error, :query_failed}` rather than carrying exception messages across the
bridge.

Configured implementations are validated against the bridge behaviours before
use. `submit_run/1` accepts only `{:ok, nonempty_binary_run_id}` as success, and
an explicit `{:error, reason}` other than `{:error, :outcome_unknown}` means
the implementation guarantees the mutation did not take effect. Malformed
mutation answers are outcome-unknown; malformed query answers remain
`{:error, {:unexpected_answer, value}}`. Active-session lists are accepted only
when every entry has non-empty binary `session_key` and `run_id` fields.
For abort and keep-alive commands, `:ok` acknowledges that the router accepted
or dispatched the decision; it does not wait for synchronous application by
the target run process.
Failure logs contain only a sanitized callback MFA and failure class; raw
exceptions, exit reasons, stacktraces, and callback arguments are neither
logged nor returned for query exceptions.

## Telemetry Events

| Event | Measurements | Metadata |
|-------|-------------|----------|
| `[:lemon, :run, :submit]` | `%{count: 1}` | session_key, origin, engine |
| `[:lemon, :run, :start]` | `%{ts_ms: ...}` | run_id |
| `[:lemon, :run, :first_token]` | `%{latency_ms: ...}` | run_id |
| `[:lemon, :run, :stop]` | `%{duration_ms: ..., ok: bool}` | run_id |
| `[:lemon, :run, :exception]` | `%{}` | run_id, exception, stacktrace |
| `[:lemon, :channels, :inbound]` | `%{count: 1}` | channel_id |
| `[:lemon, :approvals, :requested]` | `%{count: 1}` | approval_id, tool |
| `[:lemon, :approvals, :resolved]` | `%{count: 1}` | approval_id, decision |
| `[:lemon, :cron, :tick]` | `%{job_count: ...}` | |
| `[:lemon, :config, :reload, :start/stop/exception]` | duration | reload_id, reason, sources |

## Dependencies

| Dependency | Purpose |
|------------|---------|
| `jason` | JSON encoding/decoding |
| `toml` | TOML parsing |
| `telemetry` | Metrics and instrumentation |

Everything else is **optional** — lemon_core boots without it, with the
degradation noted below. UUIDs are generated by the vendored `LemonCore.Id`.

| Optional dependency | Purpose | Without it |
|------------|---------|------------|
| `phoenix_pubsub` | Bus transport | `LemonCore.Bus` falls back to a local-node Registry |
| `exqlite` | SQLite driver | `SqliteBackend` and `RunHistoryStore` are unavailable; use `EtsBackend` |
| `sentry` + `finch` | Error reporting sink | The Sentry logger handler is skipped |
| `file_system` | File watching for config reload | The reloader polls |

### If you want run history, declare `exqlite` yourself

`exqlite` being optional has a consequence that is easy to miss: `LemonCore.Application`
only starts `LemonCore.RunHistoryStore` when the SQLite NIF is loadable. An application
that depends on lemon_core but does not itself declare `exqlite` boots fine, but run
history is disabled — `RunHistoryStore.get/2` returns `[]` and the finalize-run hooks
that persist history do nothing. The only signal is a warning at boot.

Optional dependencies are not inherited: add it to your own `deps/0` to enable it.

```elixir
{:exqlite, "~> 0.34"}
```

Durable memory has the same requirement in `lemon_memory`.

Read retained history directly with `LemonCore.RunHistoryStore.get(session_key,
limit: 10)` (or `get(history_server, session_key, opts)` for a named instance).
Results are newest-first `{run_id, data}` pairs; `get` returns `[]` for display
when the owner is unavailable or a row cannot be read. Use
`RunHistoryStore.fetch/2,3` when that must remain distinct from an empty
session: an unavailable owner, a failed SQLite read and an undecodable row are
`{:error, reason}`. History reads do not go through the main `Store` process and
require no history-provider configuration.

### What the Hex package leaves out

The Hex tarball ships the library, not this repository's tooling: the
architecture/docs lint (`LemonCore.Quality.*`, `mix lemon.quality`,
`mix lemon.architecture.docs`, `mix lemon.check_duplicate_tests`), the
managed-install self-updater (`LemonCore.Update.*`, `mix lemon.update`), the
platform benchmark runner (`mix lemon.bench`) and the repo task catalog
(`mix lemon.help`) exist only in the lemon checkout.

## Filesystem layout

Everything lemon_core reads or writes by convention hangs off a per-user state
directory (`~/.lemon`) and a per-project one (`<project>/.lemon`). The defaults
are the reference runtime's; `LemonCore.Paths` makes them configurable so a
host application can put its state somewhere not named after Lemon:

```elixir
config :lemon_core, :paths,
  state_dir: ".lemon",          # per-user and per-project directory name
  config_file: "config.toml",   # file inside it
  home_state_dir: nil,          # pin the per-user directory outright
  global_config: nil            # pin the global config file outright
```

Renaming `:state_dir` moves everything derived from it: both config files, the
config reloader's watched paths, the default run-history store directory, and the
doctor's extension directory. Two locations
are configured separately because they are not part of that layout: the secrets
master key (`config :lemon_core, LemonCore.Secrets, key_file: ...`) and the
store backend path (`config :lemon_core, LemonCore.Store, backend_opts: [path: ...]`).

## Testing

```bash
# Run all lemon_core tests
mix test apps/lemon_core

# Run specific test file
mix test apps/lemon_core/test/lemon_core/config_test.exs

# Run with coverage
mix test --cover apps/lemon_core
```

### Test Harness

The harness (`LemonCore.Testing*`) serves this repository's own test suites
and is not part of the published Hex package.

```elixir
defmodule MyTest do
  use LemonCore.Testing.Case, async: true

  test "example", %{harness: harness, tmp_dir: tmp_dir} do
    path = temp_file!(harness, "config.toml", "[agent]\ndefault_model = \"test\"")
    key = unique_session_key("mytest")
  end
end
```

Available helpers: `unique_token/0`, `unique_scope/0`, `unique_session_key/0`, `unique_run_id/0`, `temp_file!/3`, `temp_dir!/2`, `clear_store_table/1`, `mock_home!/1`, `random_master_key/0`. `use LemonCore.Testing.Case, with_store: true` (or `@tag with_store: true`) starts `LemonCore.Store` for the module (or test).

## Important Notes

- Never add umbrella app dependencies to `lemon_core` -- it is the base layer
- Keep module interfaces stable -- other apps depend on them
- `LemonCore.Config.load/2` uses the cache by default; `LemonCore.Config.reload/2` forces a disk read
- Secret values are never logged or returned by list/status APIs
- SQLite store values serialize with `:erlang.term_to_binary/1`; JSONL uses a
  JSON codec with Elixir-term markers for portable persistence
- Events use millisecond timestamps from `System.system_time(:millisecond)`
- `RouterBridge` returns `{:error, :unavailable}` when `:lemon_router` has not
  registered, and `{:error, :outcome_unknown}` when a configured mutation
  loses its acknowledgement; never automatically retry the latter
- `Dedupe.Ets` uses monotonic time for TTL; `Idempotency` uses wall-clock time
- `Config.Modular` is the newer typed approach; `Config` is still the primary interface
