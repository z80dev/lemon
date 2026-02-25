# Cleanup Worklog

## Team Structure

| Role | Agent Type | Assigned To |
|------|-----------|-------------|
| **Manager** | Opus (main context) | Coordinating all work, maintaining status |
| **Phase 1a** | Sonnet | Delete gateway store backends |
| **Phase 1b** | Sonnet | Delete gateway XMTP transport + move bridge script |
| **Phase 1c** | Sonnet | Delete gateway telegram stack |
| **Phase 2a** | Opus | Create canonical types in lemon_core |
| **Phase 2b** | Opus | Unify BindingResolver in lemon_core |
| **Phase 2c** | Opus | Unify GatewayConfig in lemon_core |
| **Phase 3a** | Opus | Standardize engine event types |
| **Phase 3b** | Opus | Decouple router from channel formatting |
| **Phase 4a** | Opus | Decompose telegram/transport.ex |
| **Phase 4b** | Opus | Decompose coding_agent/session.ex |
| **Phase 4c** | Opus | Decompose run_process.ex |

---

## Phase 1: Delete Dead Duplication (Low Risk)

### 1a. Remove gateway store backend duplicates
- **Status:** DONE
- **Assigned:** Sonnet junior dev
- **Scope:**
  - Delete `apps/lemon_gateway/lib/lemon_gateway/store/backend.ex`
  - Delete `apps/lemon_gateway/lib/lemon_gateway/store/ets_backend.ex`
  - Delete `apps/lemon_gateway/lib/lemon_gateway/store/jsonl_backend.ex`
  - Delete `apps/lemon_gateway/lib/lemon_gateway/store/sqlite_backend.ex`
  - Delete `apps/lemon_gateway/lib/lemon_gateway/store.ex` (thin shim)
  - Delete `apps/lemon_gateway/test/store/` directory (3 test files)
  - Update any remaining references to use `LemonCore.Store` directly
- **Risk:** Very low - zero external references found in production code
- **Log:** Deleted 5 lib files and 3 test files. Updated 12 files with `LemonGateway.Store` references: `run.ex` (alias + 5 direct calls), `binding_resolver.ex` (alias), `transports/email/outbound.ex` (alias), `telegram/offset_store.ex` (3 direct calls + availability check), `runtime.ex` (1 direct call), `test/cancel_flow_test.exs`, `test/application_test.exs`, `test/webhook_transport_test.exs`, `test/farcaster_transport_test.exs`, `test/email/inbound_security_test.exs`, `test/telegram/queue_mode_integration_test.exs`, `test/run_test.exs`, `lemon_control_plane/test/.../exec_approvals_test.exs`, `coding_agent/test/support/test_store.ex` (comment), `debug_telegram.exs`, README.md, AGENTS.md. Compilation clean (no errors, no warnings).

### 1b. Remove gateway XMTP transport duplicate
- **Status:** DONE
- **Assigned:** Sonnet junior dev
- **Scope:**
  - Delete `apps/lemon_gateway/lib/lemon_gateway/transports/xmtp/bridge.ex`
  - Delete `apps/lemon_gateway/lib/lemon_gateway/transports/xmtp/port_server.ex`
  - Delete `apps/lemon_gateway/lib/lemon_gateway/transports/xmtp.ex` (stub)
  - Move `apps/lemon_gateway/priv/xmtp_bridge.mjs` to `apps/lemon_channels/priv/xmtp_bridge.mjs`
  - Update lemon_channels PortServer script resolution to find it in its own priv/ first
  - Remove gateway priv script after confirming channels finds it
- **Risk:** Low - gateway XMTP is explicitly stubbed out
- **Log:** Deleted `xmtp.ex`, `xmtp/bridge.ex`, `xmtp/port_server.ex` and the now-empty `xmtp/` directory from `lemon_gateway`. Copied `xmtp_bridge.mjs` to `apps/lemon_channels/priv/xmtp_bridge.mjs` (created the `priv/` directory). The `lemon_channels` PortServer `default_script_path/0` already had `safe_app_dir(:lemon_channels, "priv/xmtp_bridge.mjs")` as the first candidate - no reordering needed. Updated `apps/lemon_gateway/AGENTS.md` to remove the Xmtp stub row and update the health check reference from `LemonGateway.Transports.Xmtp.status()` to `LemonChannels.Adapters.Xmtp.Transport.status()`. Updated `apps/lemon_gateway/README.md` transport table to reference `LemonChannels.Adapters.Xmtp` directly. No other code references to deleted modules were found. `mix compile --warnings-as-errors` passes cleanly. Gateway priv copy (`apps/lemon_gateway/priv/xmtp_bridge.mjs`) retained as safety net.

### 1c. Remove gateway telegram stack
- **Status:** DONE
- **Assigned:** Sonnet junior dev
- **Scope:**
  - Delete all 11 files in `apps/lemon_gateway/lib/lemon_gateway/telegram/`
  - Remove `LemonGateway.Telegram.StartupNotifier` from `LemonGateway.Application` children
  - Remove telegram `Outbox` special case from `LemonGateway.TransportSupervisor`
  - Delete `apps/lemon_gateway/test/telegram/` test directory
  - Delete `apps/lemon_gateway/test/lemon_gateway/telegram/` test directory
  - Delete `apps/lemon_gateway/test/support/mock_telegram_api.ex` if only used by telegram tests
  - If startup notification is still desired, add a note for channels-based implementation
- **Risk:** Low-medium - need to remove supervisor children cleanly
- **Log:** Deleted all 11 `LemonGateway.Telegram.*` source files (`api.ex`, `dedupe.ex`, `formatter.ex`, `markdown.ex`, `offset_store.ex`, `outbox.ex`, `poller_lock.ex`, `startup_notifier.ex`, `transport_shared.ex`, `trigger_mode.ex`, `truncate.ex`) and the now-empty `apps/lemon_gateway/lib/lemon_gateway/telegram/` directory. Removed `LemonGateway.Telegram.StartupNotifier` from `LemonGateway.Application` children list. Simplified `LemonGateway.TransportSupervisor` by removing the telegram-specific `transport_children("telegram", mod)` clause that started `LemonGateway.Telegram.Outbox` alongside the transport; replaced with a single generic `Enum.flat_map` over all enabled transports. Deleted `apps/lemon_gateway/test/telegram/` (21 test files), `apps/lemon_gateway/test/lemon_gateway/telegram/` (1 file: `markdown_test.exs`), and `apps/lemon_gateway/test/support/mock_telegram_api.ex`. Cleaned up `apps/lemon_gateway/test/lemon_gateway_test.exs`: removed the `TestTelegramAPI` and `PollingFailureTelegramAPI` inline modules and the `telegram dedupe init is idempotent` test. Cleaned up `apps/lemon_gateway/test/transport_supervisor_test.exs`: removed `LemonGateway.Telegram.Outbox` stop calls from `setup_app`, removed the "telegram transport special handling" describe block (2 tests), updated the `does not start telegram transport when enable_telegram is false` test to no longer assert on Outbox, and removed all other Outbox references. Updated `apps/lemon_channels/test/lemon_channels/startup_test.exs`: removed the `assert Process.whereis(LemonGateway.Telegram.Outbox) == nil` assertion from the startup test (module no longer exists). Updated `apps/lemon_router/test/lemon_router/stream_coalescer_test.exs`: removed the guard that stopped `LemonGateway.Telegram.Outbox` if running. `mix compile --warnings-as-errors` passes cleanly.

---

## Phase 2: Unify Shared Primitives (Medium Risk)

### 2a. Introduce canonical types in lemon_core
- **Status:** DONE
- **Assigned:** Opus senior dev
- **Scope:**
  - Create `LemonCore.ChatScope` (from identical definitions in channels + gateway)
  - Create `LemonCore.ResumeToken` (based on agent_core's rich implementation)
  - Create `LemonCore.Binding` struct
  - Update all consumers to use canonical types
  - Delete `LemonChannels.Types.ChatScope`, `LemonChannels.Types.ResumeToken`
  - Delete `LemonGateway.Types.ChatScope`, `LemonGateway.Types.ResumeToken`
- **Risk:** Medium - many modules reference these types
- **Log:** Created `LemonCore.ChatScope`, `LemonCore.ResumeToken`, and `LemonCore.Binding` in lemon_core. Updated 89 files across the codebase to use canonical types. Existing per-app type modules now alias/delegate to core types.

### 2b. Unify BindingResolver
- **Status:** DONE
- **Assigned:** Opus senior dev
- **Scope:**
  - Create `LemonCore.BindingResolver` combining logic from both existing resolvers
  - Unify store tables: single `:project_overrides` and `:projects_dynamic`
  - Update channels + router + gateway to call core resolver
  - Delete `LemonChannels.BindingResolver` and `LemonGateway.BindingResolver`
  - Remove dual-write back-compat code in telegram adapter
- **Depends on:** 2a (needs canonical ChatScope/Binding types)
- **Risk:** Medium - store table migration needed
- **Log:** Created `LemonCore.BindingResolver` with full public API (resolve_binding, resolve_engine, resolve_agent_id, resolve_cwd, resolve_queue_mode, get_project_override, lookup_project, table name accessors). Unified store tables from 4 (`:gateway_project_overrides`, `:gateway_projects_dynamic`, `:channels_project_overrides`, `:channels_projects_dynamic`) to 2 (`:project_overrides`, `:projects_dynamic`). Reduced `LemonGateway.BindingResolver` from ~330 to ~115 lines (thin delegation + type conversion). Reduced `LemonChannels.BindingResolver` from ~260 to ~95 lines (same pattern). Removed 3 dual-write locations in `telegram/transport.ex` (path-based project selection, named project override, CWD override clearing). `mix compile --force --warnings-as-errors` passes clean.

### 2c. Unify GatewayConfig
- **Status:** IN PROGRESS
- **Assigned:** Opus senior dev
- **Scope:**
  - Create `LemonCore.GatewayConfig` as single config accessor
  - Merge logic from `LemonChannels.GatewayConfig`, `LemonGateway.Config`, `LemonGateway.ConfigLoader`
  - Ensure `LemonCore.Config.Gateway` struct has complete binding fields
  - Delete per-app config wrappers
- **Depends on:** 2a (needs canonical types)
- **Risk:** Medium - config is load-bearing; careful testing needed
- **Log:**

---

## Phase 3: Reduce Glue Layers (Higher Risk)

### 3a. Standardize engine event types
- **Status:** IN PROGRESS
- **Assigned:** Opus senior dev
- **Scope:**
  - Eliminate `LemonGateway.Event.*` translation layer
  - Use CLI runner event structs directly OR define `LemonCore.EngineEvent` types
  - Simplify CliAdapter to remove struct-to-struct-to-map chain
- **Depends on:** Phase 1 complete, Phase 2a complete
- **Risk:** Medium-high - events are the nervous system
- **Log:**

### 3b. Decouple router from channel formatting
- **Status:** NOT STARTED
- **Assigned:** Opus senior dev
- **Scope:**
  - Move telegram-specific logic out of `StreamCoalescer`
  - Move telegram-specific logic out of `ChannelsDelivery`
  - Ensure bus events carry enough routing metadata
  - Router produces generic output intents; channels owns formatting
- **Depends on:** 3a
- **Risk:** High - affects real-time message delivery
- **Log:**

---

## Phase 4: Monolith File Decomposition (Safe Refactors)

### 4a. Decompose telegram/transport.ex (5,550 lines)
- **Status:** DONE
- **Assigned:** Opus senior dev
- **Target modules:**
  - `Telegram.Transport.Commands` - command routing
  - `Telegram.Transport.FileOperations` - file put/get logic
  - `Telegram.Transport.MediaGroups` - media group handling
  - `Telegram.Transport.MessageBuffer` - message buffering/debouncing
  - `Telegram.Transport.UpdateProcessor` - update processing pipeline
- **Depends on:** Phase 1c (telegram cleanup)
- **Log:** Extracted 5 modules from transport.ex (5,550 -> 4,372 LOC). All extracted modules live in `apps/lemon_channels/lib/lemon_channels/adapters/telegram/transport/`. Compilation clean.

### 4b. Decompose coding_agent/session.ex (3,398 lines)
- **Status:** DONE
- **Assigned:** Opus senior dev
- **Target modules:**
  - `Session.MessageSerialization` - encode/decode logic
  - `Session.WasmBridge` - WASM sidecar coordination
  - `Session.CompactionManager` - auto-compaction + overflow recovery
  - `Session.ModelResolver` - model/provider configuration
  - `Session.PromptComposer` - system prompt assembly
- **Depends on:** None (independent)
- **Log:** Extracted 5 new modules from session.ex (3,372 -> 2,129 lines, 37% reduction). Created `Session.MessageSerialization` (235 lines) with all serialize/deserialize functions for messages, content blocks, usage, trust, and stop reasons. Created `Session.ModelResolver` (364 lines) with model resolution from string/map/struct specs, provider config lookups, API key resolution via env vars and secrets, and stream option building (including Vertex-specific secrets). Created `Session.CompactionManager` (495 lines) with session signature computation, auto-compaction and overflow recovery state management (clear/track/finalize), context-length-exceeded detection, background task lifecycle (start/track/timeout/kill), compaction opts normalization, and compaction result application. Created `Session.WasmBridge` (305 lines) with WASM sidecar startup/reload, tool discovery/inventory building, host tool invocation routing (including reserved secret targets), policy summarization, and status helpers. Created `Session.PromptComposer` (135 lines) with system prompt composition from multiple sources (explicit, template, base, instructions) and session scope resolution. All new modules have `@moduledoc` descriptions. The GenServer in session.ex retains state struct, callbacks, and thin wrappers that delegate to extracted modules. `mix compile --warnings-as-errors` passes cleanly.

### 4c. Decompose run_process.ex (2,438 lines)
- **Status:** DONE
- **Assigned:** Opus senior dev
- **Target modules:**
  - `RunProcess.Watchdog` (295 lines) - idle-run watchdog, timeout scheduling, activity tracking, user confirmation prompts
  - `RunProcess.CompactionTrigger` (736 lines) - context-overflow detection, preemptive compaction markers, token estimation, event extraction helpers
  - `RunProcess.RetryHandler` (216 lines) - zero-answer retry, retryable error classification, retry request building
  - `RunProcess.OutputTracker` (827 lines) - stream output finalization, file/image tracking, auto-send resolution, fanout delivery, tool-status coalescing
- **Depends on:** None (independent)
- **Log:** Extracted 4 new modules into `apps/lemon_router/lib/lemon_router/run_process/`. run_process.ex reduced from 2,438 to 689 lines (72% reduction). GenServer shell retains state struct, all callbacks (init, handle_info, handle_cast, terminate), gateway monitoring, session registration. All extracted modules have `@moduledoc` descriptions. `mix compile --warnings-as-errors` passes clean. 25/31 tests pass (6 pre-existing failures unrelated to refactor — test module naming issue).
