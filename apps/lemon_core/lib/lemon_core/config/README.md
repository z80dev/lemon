# LemonCore.Config

Modular configuration system for Lemon, inspired by Ironclaw's config architecture.

## Overview

The configuration system has been refactored from a monolithic 1253-line module into focused, modular components. Each module handles a specific domain of configuration:

| Module | Purpose | Tests |
|--------|---------|-------|
| `Helpers` | Environment variable utilities | 66 |
| `Agent` | Agent behavior settings | 17 |
| `Tools` | Web tools and WASM configuration | 25 |
| `Gateway` | Telegram, SMS, engine bindings | 22 |
| `Logging` | Log file and rotation settings | 20 |
| `TUI` | Terminal UI theme and debug | 12 |
| `Providers` | LLM provider configurations | 18 |
| **Total** | | **198** |

## Architecture

### Priority Order

Configuration values are resolved in the following priority:

1. **Environment variables** (highest priority)
2. **TOML config file** (`~/.lemon/config.toml` or project `.lemon/config.toml`)
3. **Default values** (lowest priority)

### Module Structure

Each config module follows a consistent pattern:

```elixir
defmodule LemonCore.Config.Example do
  @moduledoc """Documentation with configuration examples."""
  
  alias LemonCore.Config.Helpers
  
  defstruct [:field1, :field2]
  
  @type t :: %__MODULE__{field1: type1(), field2: type2()}
  
  @doc "Resolves configuration from settings and environment variables."
  @spec resolve(map()) :: t()
  def resolve(settings) do
    # Resolution logic using Helpers
  end
  
  @doc "Returns the default configuration as a map."
  @spec defaults() :: map()
  def defaults do
    %{"field1" => default1, "field2" => default2}
  end
end
```

## Usage

### Loading Configuration

```elixir
# Load full configuration
config = LemonCore.Config.load()

# Access specific modules
agent_config = LemonCore.Config.Agent.resolve(settings)
tools_config = LemonCore.Config.Tools.resolve(settings)
```

### Environment Variables

Each module documents its environment variables. Common patterns:

- `LEMON_*` - General lemon settings
- `ANTHROPIC_API_KEY`, `OPENAI_API_KEY` - Provider-specific API keys
- `LEMON_GATEWAY_*` - Gateway settings
- `LEMON_LOG_*` - Logging settings

### Configuration File

Example `~/.lemon/config.toml`:

```toml
[agent]
default_provider = "anthropic"
default_model = "claude-sonnet-4-20250514"

[agent.compaction]
enabled = true
reserve_tokens = 16384

[providers.anthropic]
api_key = "sk-ant-..."

[gateway]
enable_telegram = true

[[gateway.bindings]]
transport = "telegram"
chat_id = 123456789
agent_id = "default"

[logging]
file = "./logs/lemon.log"
level = "debug"
```

## Module Documentation

### Config.Helpers

Environment variable parsing utilities:

- `get_env/1,2` - Get string values
- `get_env_int/2` - Parse integers
- `get_env_float/2` - Parse floats
- `get_env_bool/2` - Parse booleans
- `get_env_atom/2` - Parse atoms
- `get_env_list/2` - Parse comma-separated lists
- `get_env_duration/2` - Parse durations (e.g., "30s", "5m")
- `get_env_bytes/2` - Parse byte sizes (e.g., "10MB", "1GB")
- `require_env!/1,2` - Require environment variables

### Config.Agent

Agent behavior configuration:

- `default_provider` - Default LLM provider
- `default_model` - Default model identifier
- `default_thinking_level` - Thinking level (low/medium/high)
- `compaction` - Context compaction settings
- `retry` - Retry behavior
- `shell` - Shell configuration
- `extension_paths` - List of extension directories
- `theme` - Agent theme

Environment variables:
- `LEMON_DEFAULT_PROVIDER`, `LEMON_DEFAULT_MODEL`
- `LEMON_DEFAULT_THINKING_LEVEL`
- `LEMON_COMPACTION_ENABLED`, `LEMON_COMPACTION_RESERVE_TOKENS`
- `LEMON_RETRY_ENABLED`, `LEMON_MAX_RETRIES`
- `LEMON_EXTENSION_PATHS`, `LEMON_THEME`

### Config.Tools

Tool configuration:

- `auto_resize_images` - Automatic image resizing
- `web.search` - Web search provider (brave, perplexity)
- `web.fetch` - Web fetch settings (max_chars, readability)
- `web.cache` - Caching configuration
- `wasm` - WASM runtime settings

Environment variables:
- `LEMON_WEB_SEARCH_PROVIDER`, `LEMON_WEB_SEARCH_API_KEY`
- `LEMON_WEB_FETCH_MAX_CHARS`, `LEMON_WEB_FETCH_READABILITY`
- `LEMON_WASM_ENABLED`, `LEMON_WASM_DEFAULT_MEMORY_LIMIT`

### Config.Gateway

Gateway configuration:

- `max_concurrent_runs` - Concurrent run limit
- `default_engine` - Default execution engine
- `default_cwd` - Default working directory
- `enable_telegram` - Enable Telegram bot
- `bindings` - Transport bindings
- `telegram` - Telegram bot settings
- `queue` - Queue management

Environment variables:
- `LEMON_GATEWAY_MAX_CONCURRENT_RUNS`
- `LEMON_GATEWAY_DEFAULT_ENGINE`
- `LEMON_GATEWAY_ENABLE_TELEGRAM`
- `TELEGRAM_BOT_TOKEN` (via `${TELEGRAM_BOT_TOKEN}` interpolation)

### Config.Logging

Logging configuration:

- `file` - Log file path
- `level` - Log level (debug, info, warning, error)
- `max_no_bytes` - Max log file size
- `max_no_files` - Number of rotated files
- `compress_on_rotate` - Compress rotated files
- `filesync_repeat_interval` - Disk sync interval

Environment variables:
- `LEMON_LOG_FILE`, `LEMON_LOG_LEVEL`
- `LEMON_LOG_MAX_NO_BYTES`, `LEMON_LOG_MAX_NO_FILES`

### Config.TUI

TUI configuration:

- `theme` - TUI theme (lemon, dark, etc.)
- `debug` - Debug mode flag

Environment variables:
- `LEMON_TUI_THEME`, `LEMON_TUI_DEBUG`

### Config.Providers

LLM provider configuration:

- `api_key` - API key for the provider
- `base_url` - Custom base URL
- `api_key_secret` - Secret store reference

Environment variables:
- `ANTHROPIC_API_KEY`, `ANTHROPIC_BASE_URL`
- `OPENAI_API_KEY`, `OPENAI_BASE_URL`
- `OPENAI_CODEX_API_KEY`

Helper functions:
- `get_provider/2` - Get provider config
- `get_api_key/2` - Get API key
- `list_providers/1` - List configured providers

## Migration Guide

### From Old Config

The main `LemonCore.Config` module continues to work as before. The internal implementation now delegates to the modular components.

### Using New Modules Directly

For new code, you can use the modular config directly:

```elixir
# Instead of loading full config
config = LemonCore.Config.load()
agent = config.agent

# Use the module directly
settings = load_settings_somehow()
agent = LemonCore.Config.Agent.resolve(settings)
```

## Testing

Each config module has comprehensive tests:

```bash
cd apps/lemon_core
mix test test/lemon_core/config/
```

## Future Work

- [ ] Refactor main `config.ex` to use modular components
- [ ] Add `Config.LLM` for LLM-specific settings
- [ ] Add `Config.Agents` for multi-agent configurations
- [ ] Add validation using Ecto or similar
- [ ] Add config reloading support
