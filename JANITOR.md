# JANITOR.md - Automated Code Improvement Log

This file tracks all automated improvements made by the Codex engine cron job.
Each entry records what was done, what worked, and what to focus on next.

## Instructions for Each Run

1. Read this file first to understand what previous runs accomplished
2. Pull latest state of `~/dev/openclaw` and `~/dev/ironclaw` for inspiration
3. Look for patterns, ideas, or techniques to apply to the lemon codebase
4. Make incremental improvements - commit as you go
5. Write/update tests for any changes
6. Update docs/README if needed
7. Log your work here before finishing

## Work Areas (rotate through these)

- **Feature Enhancement**: Add new capabilities inspired by openclaw/ironclaw
- **Test Expansion**: Add tests for untested modules, fix broken tests
- **Documentation**: Update README, add inline docs, create guides
- **Refactoring**: Clean up code, improve patterns, reduce tech debt
- **Bug Fixes**: Address any issues you discover

---

## Log Entries

### 2025-01-XX - Initial Setup
- Created JANITOR.md log file
- Scheduled cron job to run every 30 minutes
- First run kicked off manually

### 2025-02-19 - Test Infrastructure: Testing Harness Module
**Work Area**: Test Expansion / Feature Enhancement

**What was done:**
- Created `LemonCore.Testing` module inspired by Ironclaw's `testing.rs`
- Added `Testing.Harness` - A builder pattern for setting up test environments with:
  - Automatic temporary directory creation and cleanup
  - Environment variable management with automatic restoration
  - Optional Store process startup
  - Support for both sync and async test modes
- Added `Testing.Case` - A test case template that provides the harness automatically
- Added `Testing.Helpers` - Helper functions for tests:
  - `unique_token/0` - Generate unique positive integers
  - `unique_scope/1` - Generate unique scopes for test isolation
  - `unique_session_key/1` - Generate unique session keys
  - `unique_run_id/1` - Generate unique run IDs
  - `temp_file!/3` - Create temp files with content
  - `temp_dir!/2` - Create temp directories
  - `clear_store_table/1` - Clear Store tables
  - `mock_home!/1` - Set up mock HOME directory for config tests
  - `random_master_key/0` - Generate random master keys for secrets tests
- Created comprehensive tests for the Testing module (`testing_test.exs`)
- All 14 new tests pass
- Existing 119 tests still pass (1 pre-existing failure in architecture check unrelated to changes)

**Files changed:**
- `apps/lemon_core/lib/lemon_core/testing.ex` (new file - 280 lines)
- `apps/lemon_core/test/lemon_core/testing_test.exs` (new file - 14 tests)

**Commits:**
- (to be committed)

**What worked:**
- The builder pattern translates well from Rust to Elixir
- Using `ExUnit.Callbacks.on_exit` for cleanup works correctly
- The Harness struct provides a clean container for test resources

### 2025-02-19 - Config Infrastructure: Config.Helpers Module
**Work Area**: Feature Enhancement / Refactoring

**What was done:**
- Created `LemonCore.Config.Helpers` module inspired by Ironclaw's `config/helpers.rs`
- Provides consistent environment variable handling with proper type conversion:
  - `get_env/1,2` - Get optional env vars with default support
  - `get_env_int/2` - Parse integers with fallback
  - `get_env_float/2` - Parse floats with fallback
  - `get_env_bool/2` - Parse booleans (true/1/yes/on vs false/0/no/off)
  - `get_env_atom/2` - Convert to snake_case atoms
  - `get_env_list/2` - Split comma-separated values
  - `require_env!/1,2` - Require env vars with helpful error messages
  - `get_feature_env/3` - Feature-flag conditional env vars
  - `parse_duration/2, get_env_duration/2` - Parse durations (ms/s/m/h/d)
  - `parse_bytes/2, get_env_bytes/2` - Parse byte sizes (B/KB/MB/GB/TB)
- Created comprehensive tests (`helpers_test.exs`) with 66 test cases
- All 66 new tests pass
- Total test count: 185 (up from 119)
- Existing tests still pass (1 pre-existing architecture check failure unrelated)

**Files changed:**
- `apps/lemon_core/lib/lemon_core/config/helpers.ex` (new file - 280 lines)
- `apps/lemon_core/test/lemon_core/config/helpers_test.exs` (new file - 66 tests)

**What worked:**
- Ironclaw's helper pattern translates well to Elixir
- Comprehensive type conversion with sensible defaults
- Duration and byte parsing are particularly useful for config

### 2025-02-19 - Config Refactoring: Extract Agent Config Module
**Work Area**: Refactoring / Feature Enhancement

**What was done:**
- Created `LemonCore.Config.Agent` module following Ironclaw's `config/agent.rs` pattern
- Extracted agent-specific configuration from the monolithic `config.ex` (1253 lines)
- Agent config includes:
  - `default_provider`, `default_model`, `default_thinking_level`
  - `compaction` settings (enabled, reserve_tokens, keep_recent_tokens)
  - `retry` settings (enabled, max_retries, base_delay_ms)
  - `shell` settings (path, command_prefix)
  - `extension_paths` list
  - `theme` selection
- Uses `Config.Helpers` for consistent env var resolution
- Priority: environment variables > TOML config > defaults
- Added `defaults/0` function for the base configuration
- Created comprehensive tests (`agent_test.exs`) with 17 test cases
- All 17 new tests pass
- Total test count: 202 (up from 185)
- Existing tests still pass (1 pre-existing architecture check failure unrelated)

**Files changed:**
- `apps/lemon_core/lib/lemon_core/config/agent.ex` (new file - 180 lines)
- `apps/lemon_core/test/lemon_core/config/agent_test.exs` (new file - 17 tests)

**What worked:**
- Ironclaw's modular config pattern works well in Elixir
- Using `Config.Helpers` keeps the code clean and consistent
- The `resolve/1` pattern provides clear separation of concerns
- Proper handling of `false` values (not falsy like `||` would treat them)

**Next run should focus on:**
- Extract more config sections: `LemonCore.Config.Tools`, `LemonCore.Config.Gateway`, `LemonCore.Config.Logging`
- Gradually migrate `config.ex` to use the new modular config modules
- Eventually split config.ex into multiple focused modules like Ironclaw's config/
- Add Config.Helpers to other apps in the umbrella
- Look at Ironclaw's benchmark suite for performance testing inspiration

### 2025-02-19 - Config Refactoring: Extract Tools Config Module
**Work Area**: Refactoring / Feature Enhancement

**What was done:**
- Created `LemonCore.Config.Tools` module following Ironclaw's modular config pattern
- Extracted tools-specific configuration from the monolithic `config.ex` (1253 lines)
- Tools config includes:
  - `auto_resize_images` - automatic image resizing setting
  - `web.search` - web search provider configuration (brave, perplexity)
    - `failover` settings for search provider fallback
    - `perplexity` specific configuration
  - `web.fetch` - web fetch configuration (max_chars, readability, firecrawl)
    - `firecrawl` integration settings
    - `allowed_hostnames` for private network access
  - `web.cache` - caching configuration (persistent, path, max_entries)
  - `wasm` - WASM runtime configuration
    - memory limits, timeout, fuel limits
    - tool paths, cache settings
- Uses `Config.Helpers` for consistent env var resolution
- Supports byte size parsing for memory limits (e.g., "10MB", "1GB")
- Priority: environment variables > TOML config > defaults
- Added `defaults/0` function for the base configuration
- Created comprehensive tests (`tools_test.exs`) with 25 test cases
- All 25 new tests pass
- Total test count: 227 (up from 202)
- Existing tests still pass (1 pre-existing architecture check failure unrelated)

**Files changed:**
- `apps/lemon_core/lib/lemon_core/config/tools.ex` (new file - 350 lines)
- `apps/lemon_core/test/lemon_core/config/tools_test.exs` (new file - 25 tests)

**What worked:**
- Complex nested config structures work well with the modular pattern
- Using `Config.Helpers.get_env_bytes/2` for memory limits is elegant
- Firecrawl's tri-state `enabled` (true/false/nil) handled correctly
- Environment variable lists (comma-separated) work well for hostnames and paths

**Next run should focus on:**
- Extract remaining config sections: `LemonCore.Config.Gateway`, `LemonCore.Config.Logging`, `LemonCore.Config.TUI`
- Start using the new modular config modules in the main Config module
- Consider creating a Config.LLM module for provider-specific settings
- Eventually the main config.ex should just orchestrate the sub-modules
- Add Config.Helpers to other apps in the umbrella

### 2025-02-19 - Config Refactoring: Extract Gateway Config Module
**Work Area**: Refactoring / Feature Enhancement

**What was done:**
- Created `LemonCore.Config.Gateway` module following Ironclaw's modular config pattern
- Extracted gateway-specific configuration from the monolithic `config.ex` (1253 lines)
- Gateway config includes:
  - Core settings: `max_concurrent_runs`, `default_engine`, `default_cwd`, `auto_resume`
  - Telegram settings: `enable_telegram`, `require_engine_lock`, `engine_lock_timeout_ms`
  - `bindings` - list of transport bindings (telegram chat_id to agent_id mappings)
  - `projects` - project-specific configuration map
  - `sms` - SMS provider configuration
  - `queue` - queue management settings (mode, cap, drop strategy)
  - `telegram` - Telegram bot configuration with:
    - Token resolution (supports ${ENV_VAR} syntax)
    - Compaction settings (context_window_tokens, reserve_tokens, trigger_ratio)
  - `engines` - engine-specific configuration map
- Uses `Config.Helpers` for consistent env var resolution
- Supports env var interpolation for sensitive values like tokens (${TELEGRAM_BOT_TOKEN})
- Priority: environment variables > TOML config > defaults
- Added `defaults/0` function for the base configuration
- Created comprehensive tests (`gateway_test.exs`) with 22 test cases
- All 22 new tests pass
- Total test count: 249 (up from 227)
- Existing tests still pass (1 pre-existing architecture check failure unrelated)

**Files changed:**
- `apps/lemon_core/lib/lemon_core/config/gateway.ex` (new file - 230 lines)
- `apps/lemon_core/test/lemon_core/config/gateway_test.exs` (new file - 22 tests)

**What worked:**
- Env var interpolation (${VAR}) pattern works well for sensitive config like tokens
- The modular pattern scales well to complex nested configurations
- Telegram compaction settings follow the same pattern as agent compaction
- Queue configuration with nil defaults allows for optional feature enablement

**Next run should focus on:**
- Extract remaining config sections: `LemonCore.Config.Logging`, `LemonCore.Config.TUI`, `LemonCore.Config.Providers`
- Start integrating the modular config modules into the main Config module
- Consider creating a Config.LLM module for provider-specific settings
- Eventually the main config.ex should just orchestrate the sub-modules
- Add Config.Helpers to other apps in the umbrella

### 2025-02-19 - Config Refactoring: Extract Logging and TUI Config Modules
**Work Area**: Refactoring / Feature Enhancement

**What was done:**
- Created `LemonCore.Config.Logging` module for logging configuration:
  - `file` - log file path
  - `level` - log level (:debug, :info, :warning, :error)
  - `max_no_bytes` - maximum log file size before rotation
  - `max_no_files` - number of rotated files to keep
  - `compress_on_rotate` - whether to compress rotated files
  - `filesync_repeat_interval` - disk sync interval in milliseconds
  - Supports log level parsing (including "warn" -> :warning)
  - Handles invalid integer env vars gracefully
- Created `LemonCore.Config.TUI` module for TUI configuration:
  - `theme` - TUI theme (separate from agent theme)
  - `debug` - debug mode flag
  - Simple configuration with sensible defaults
- Both modules use `Config.Helpers` for consistent env var resolution
- Priority: environment variables > TOML config > defaults
- Added `defaults/0` functions for base configurations
- Created comprehensive tests:
  - `logging_test.exs` with 20 test cases
  - `tui_test.exs` with 12 test cases
- All 32 new tests pass
- Total test count: 281 (up from 249)
- Existing tests still pass (1 pre-existing architecture check failure unrelated)

**Files changed:**
- `apps/lemon_core/lib/lemon_core/config/logging.ex` (new file - 130 lines)
- `apps/lemon_core/test/lemon_core/config/logging_test.exs` (new file - 20 tests)
- `apps/lemon_core/lib/lemon_core/config/tui.ex` (new file - 60 lines)
- `apps/lemon_core/test/lemon_core/config/tui_test.exs` (new file - 12 tests)

**What worked:**
- Log level normalization (warn -> warning) improves user experience
- Nil defaults for optional settings allow flexible configuration
- The modular pattern works well for both simple and complex configs
- Clear separation between TUI theme and agent theme avoids confusion

**Config modules created so far:**
- ✅ `LemonCore.Config.Helpers` - env var utilities
- ✅ `LemonCore.Config.Agent` - agent behavior settings
- ✅ `LemonCore.Config.Tools` - web tools and WASM settings
- ✅ `LemonCore.Config.Gateway` - Telegram, SMS, engine bindings
- ✅ `LemonCore.Config.Logging` - log file and rotation settings
- ✅ `LemonCore.Config.TUI` - terminal UI theme and debug

**Next run should focus on:**
- Create `LemonCore.Config.Providers` for LLM provider configurations
- Start integrating all modular config modules into the main Config module
- Refactor main config.ex to use the new modules (reduce from 1253 lines)
- Eventually config.ex should just orchestrate sub-modules like Ironclaw's config/mod.rs
- Add Config.Helpers to other apps in the umbrella

### 2025-02-19 - Config Refactoring: Extract Providers Config Module
**Work Area**: Refactoring / Feature Enhancement

**What was done:**
- Created `LemonCore.Config.Providers` module for LLM provider configurations:
  - `api_key` - direct API key for providers
  - `base_url` - custom base URL for API endpoints
  - `api_key_secret` - reference to secret store for API keys
  - Supports known providers with env var mappings:
    - `anthropic`: `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`
    - `openai`: `OPENAI_API_KEY`, `OPENAI_BASE_URL`
    - `openai-codex`: `OPENAI_CODEX_API_KEY`, `OPENAI_BASE_URL`
  - Supports arbitrary custom providers
  - Filters out non-map provider configs (invalid configs are ignored)
  - Nil/empty values are filtered out from provider configs
  - Added helper functions:
    - `get_provider/2` - get specific provider config
    - `get_api_key/2` - get API key for a provider
    - `list_providers/1` - list all configured provider names
- Uses `Config.Helpers` for consistent env var resolution
- Priority: environment variables > TOML config > defaults
- Created comprehensive tests (`providers_test.exs`) with 18 test cases
- All 18 new tests pass
- Total test count: 299 (up from 281)
- Existing tests still pass (1 pre-existing architecture check failure unrelated)

**Files changed:**
- `apps/lemon_core/lib/lemon_core/config/providers.ex` (new file - 170 lines)
- `apps/lemon_core/test/lemon_core/config/providers_test.exs` (new file - 18 tests)

**What worked:**
- Provider env var mappings make it easy to add new known providers
- Filtering invalid configs prevents crashes from malformed config
- The `api_key_secret` field provides flexibility for secret management
- Helper functions make it easy to work with provider configs

**Config modules completed:**
- ✅ `LemonCore.Config.Helpers` - env var utilities (66 tests)
- ✅ `LemonCore.Config.Agent` - agent behavior settings (17 tests)
- ✅ `LemonCore.Config.Tools` - web tools and WASM settings (25 tests)
- ✅ `LemonCore.Config.Gateway` - Telegram, SMS, engine bindings (22 tests)
- ✅ `LemonCore.Config.Logging` - log file and rotation settings (20 tests)
- ✅ `LemonCore.Config.TUI` - terminal UI theme and debug (12 tests)
- ✅ `LemonCore.Config.Providers` - LLM provider configurations (18 tests)

**Total: 7 config modules, 198 tests**

**Next run should focus on:**
- Create a `LemonCore.Config` module that orchestrates all sub-modules
- Refactor main config.ex to use the new modular config modules
- Reduce config.ex from 1253 lines by delegating to sub-modules
- Eventually config.ex should just be a thin wrapper like Ironclaw's config/mod.rs
- Add Config.Helpers to other apps in the umbrella

### 2025-02-19 - Documentation: Config Module README
**Work Area**: Documentation

**What was done:**
- Created comprehensive README for the new modular config system (`config/README.md`):
  - Overview of all 7 config modules with test counts
  - Architecture explanation with priority order
  - Module structure pattern documentation
  - Usage examples for each module
  - Configuration file examples (TOML)
  - Environment variable documentation for all modules
  - Migration guide for using new modules directly
  - Testing instructions
  - Future work checklist
- Created `readme_test.exs` to verify all README examples work correctly:
  - Tests for each config module's basic usage
  - Tests for helper functions
  - Tests for environment variable priority
  - 8 comprehensive tests
- All 8 new tests pass
- Total test count: 307 (up from 299)
- Existing tests still pass (1 pre-existing architecture check failure unrelated)

**Files changed:**
- `apps/lemon_core/lib/lemon_core/config/README.md` (new file - 260 lines)
- `apps/lemon_core/test/lemon_core/config/readme_test.exs` (new file - 8 tests)

**What worked:**
- Documentation-driven development ensures examples are correct
- README tests catch documentation drift
- Comprehensive docs help users understand the new modular structure
- The modular pattern is now well-documented for future contributors

**Config system status:**
- ✅ 7 config modules extracted (198 tests)
- ✅ Documentation complete with examples
- ✅ All examples tested and verified
- 🔄 Next: Integration into main Config module

**Next run should focus on:**
- Create a new `LemonCore.Config.New` module that orchestrates all sub-modules
- Gradually migrate functionality from the 1253-line config.ex
- Add deprecation warnings for old config patterns
- Eventually replace config.ex with the new modular implementation
- Consider adding validation (Ecto-style or similar)

### 2025-02-19 - Feature: Modular Config Interface
**Work Area**: Feature Enhancement

**What was done:**
- Created `LemonCore.Config.Modular` module as the new configuration interface:
  - Provides a unified `load/1` function that orchestrates all sub-modules
  - Loads and merges global config (`~/.lemon/config.toml`) and project config (`.lemon/config.toml`)
  - Uses `Toml.decode/1` for parsing TOML files
  - Deep merges configuration maps (project overrides global)
  - Delegates to each modular config module for resolution:
    - `Agent.resolve/1` for agent settings
    - `Tools.resolve/1` for tools configuration
    - `Gateway.resolve/1` for gateway settings
    - `Logging.resolve/1` for logging configuration
    - `TUI.resolve/1` for TUI settings
    - `Providers.resolve/1` for provider configurations
  - Returns a unified struct with all configuration sections
  - Helper functions:
    - `global_path/0` - returns path to global config
    - `project_path/1` - returns path to project config
- Created comprehensive tests (`modular_test.exs`):
  - Tests for loading configuration
  - Tests for default values
  - Tests for environment variable overrides
  - Tests for path helpers
  - Tests for integration with all sub-modules
  - 12 comprehensive tests
- All 12 new tests pass
- Total test count: 319 (up from 307)
- Existing tests still pass (1 pre-existing architecture check failure unrelated)

**Files changed:**
- `apps/lemon_core/lib/lemon_core/config/modular.ex` (new file - 160 lines)
- `apps/lemon_core/test/lemon_core/config/modular_test.exs` (new file - 12 tests)

**What worked:**
- The modular interface provides a clean migration path from the old config
- Deep merge allows project configs to override specific fields without replacing entire sections
- Error handling for missing/invalid config files prevents crashes
- The new interface can coexist with the legacy config during transition

**Config system status:**
- ✅ 7 config modules extracted (198 tests)
- ✅ Documentation complete with examples (8 tests)
- ✅ New modular interface ready (12 tests)
- ✅ 218 tests for config system
- 🔄 Next: Gradually migrate usage from legacy config to modular config

**Next run should focus on:**
- Start using `LemonCore.Config.Modular` in new code
- Add deprecation notices to legacy config functions
- Gradually replace usage of old config with new modular config
- Eventually remove the 1253-line legacy config.ex
- Add validation to the modular config (Ecto-style or similar)

### 2025-02-19 - Test Expansion: ExecApprovals Tests
**Work Area**: Test Expansion

**What was done:**
- Created comprehensive tests for the `LemonCore.ExecApprovals` module (previously untested):
  - Tests for `request/1` function:
    - Returns approved immediately when global approval exists
    - Returns approved immediately when session approval exists
    - Returns approved immediately when agent approval exists
    - Creates pending approval when no existing approval
    - Returns denied when approval is denied
    - Returns timeout when approval times out
  - Tests for `resolve/2` function:
    - Stores session approval when resolved with :approve_session
    - Stores agent approval when resolved with :approve_agent
    - Stores global approval when resolved with :approve_global
    - Does not store approval when resolved with :approve_once
    - Deletes pending approval after resolution
    - Handles non-existent approvals gracefully
  - Tests for approval scope hierarchy:
    - Global approval takes precedence over agent and session
    - Agent approval takes precedence over session
  - Tests for action hashing:
    - Same actions produce same hash
    - Different actions produce different hashes
  - Tests for wildcard approvals:
    - Wildcard :any action hash matches any action
  - 17 comprehensive tests covering the 342-line module
- All 17 new tests pass
- Total test count: 336 (up from 319)
- Existing tests still pass (1 pre-existing architecture check failure unrelated)

**Files changed:**
- `apps/lemon_core/test/lemon_core/exec_approvals_test.exs` (new file - 17 tests)

**What worked:**
- Testing the approval hierarchy (global > agent > session) ensures correct precedence
- Testing both synchronous (existing approval) and asynchronous (pending approval) paths
- Testing edge cases like timeouts and non-existent approvals
- The module's design with separate Store tables for each scope makes testing clean

**Test coverage improvement:**
- Before: ExecApprovals module (342 lines) had 0 tests
- After: ExecApprovals module has 17 tests
- This was one of the gaps identified in the missing tests audit

**Next run should focus on:**
- Continue adding tests for other untested modules:
  - `clock` - Time utilities
  - `config_cache` - Config caching
  - `dedupe_ets` - Deduplication
  - `httpc` - HTTP client
  - `logger_setup` - Logger initialization
- Or start using the new modular config in actual code
- Or add validation to the modular config system

### 2025-02-19 - Test Expansion: Clock Tests
**Work Area**: Test Expansion

**What was done:**
- Created comprehensive tests for the `LemonCore.Clock` module (previously untested):
  - Tests for `now_ms/0`: returns current time in milliseconds
  - Tests for `now_sec/0`: returns current time in seconds
  - Tests for `now_utc/0`: returns current UTC datetime
  - Tests for `from_ms/1`: converts milliseconds to DateTime, handles zero
  - Tests for `to_ms/1`: converts DateTime to milliseconds, round-trip with from_ms
  - Tests for `expired?/2`: expired timestamps, non-expired, exact boundary, past boundary
  - Tests for `elapsed_ms/1`: elapsed time since timestamp, zero for current timestamp
  - 13 comprehensive tests covering the 64-line module
- All 13 new tests pass
- Total test count: 349 (up from 336)
- Existing tests still pass (1 pre-existing architecture check failure unrelated)

**Files changed:**
- `apps/lemon_core/test/lemon_core/clock_test.exs` (new file - 13 tests)

**What worked:**
- Testing time functions requires careful timing assertions
- Round-trip testing (ms -> DateTime -> ms) verifies correctness
- Boundary testing for expiration logic catches edge cases
- Simple modules are quick to test but still important for coverage

**Test coverage progress:**
- Before: Clock module (64 lines) had 0 tests
- After: Clock module has 13 tests
- Remaining untested modules:
  - `config_cache` - Config caching
  - `dedupe_ets` - Deduplication
  - `httpc` - HTTP client
  - `logger_setup` - Logger initialization

**Total progress:**
- Started with 119 tests
- Now have 349 tests
- Added 230 tests across multiple runs

**Next run should focus on:**
- Continue adding tests for remaining untested modules
- Or add integration tests using the new modular config
- Or add validation to the modular config system
