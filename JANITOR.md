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
