# CodingAgent.LayeredConfig - Layered Configuration System

This document describes the `CodingAgent.LayeredConfig` module, an Elixir-native configuration system with multiple layers of configuration that merge together.

## Overview

The `LayeredConfig` module provides a flexible configuration system where settings can be defined at multiple levels:

1. **Global** - User-wide defaults (`~/.lemon/agent/config.exs`)
2. **Project** - Per-project overrides (`<project>/.lemon/config.exs`)
3. **Session** - In-memory runtime overrides

Configuration is merged in order (global -> project -> session), with later values taking precedence.

## Location

File: `apps/coding_agent/lib/coding_agent/layered_config.ex`

## Configuration File Format

Config files are Elixir scripts that return a keyword list or map:

```elixir
# ~/.lemon/agent/config.exs
[
  model: "claude-sonnet-4-20250514",
  thinking_level: :medium,

  # Nested configuration
  tools: [
    bash: [timeout: 120_000, sandbox: false],
    read: [max_lines: 5000],
    glob: [max_results: 2000]
  ],

  # Compaction settings
  compaction: [
    enabled: true,
    reserve_tokens: 16384,
    keep_recent_tokens: 20000
  ],

  # Extensions
  extensions: [
    "~/.lemon/agent/extensions/my-ext"
  ],

  # Display
  theme: "dracula",
  debug: false
]
```

## Loading Configuration

### load/1

Load configuration for a project directory:

```elixir
config = CodingAgent.LayeredConfig.load("/path/to/project")
```

This loads and merges:
1. Global config from `~/.lemon/agent/config.exs`
2. Project config from `/path/to/project/.lemon/config.exs`

### load_file/1

Load a specific config file:

```elixir
project_config = CodingAgent.LayeredConfig.load_file("/path/to/config.exs")
```

Returns an empty map if the file doesn't exist or can't be evaluated.

### reload/1

Re-read config files from disk while preserving session overrides:

```elixir
config = CodingAgent.LayeredConfig.reload(config)
```

## Accessing Values

### get/3

Get a value with an optional default:

```elixir
# Simple access
model = LayeredConfig.get(config, :model)

# With default value
model = LayeredConfig.get(config, :model, "claude-sonnet-4-20250514")

# Nested access using key list
timeout = LayeredConfig.get(config, [:tools, :bash, :timeout], 60_000)
```

### get!/2

Get a value, raising `KeyError` if not found:

```elixir
model = LayeredConfig.get!(config, :model)
# Raises KeyError if :model not in any layer or defaults
```

### has_key?/2

Check if a key exists in any layer or defaults:

```elixir
if LayeredConfig.has_key?(config, :model) do
  # Key exists
end
```

## Setting Values

### put/3

Set a session-level value (highest precedence):

```elixir
config = LayeredConfig.put(config, :thinking_level, :high)
config = LayeredConfig.put(config, [:tools, :bash, :timeout], 300_000)
```

### put_layer/4

Set a value at a specific layer:

```elixir
config = LayeredConfig.put_layer(config, :project, :model, "gpt-4")
config = LayeredConfig.put_layer(config, :global, :theme, "monokai")
```

### get_layer/3

Get the raw value from a specific layer (without merging):

```elixir
global_model = LayeredConfig.get_layer(config, :global, :model)
```

## Exporting Configuration

### to_map/1

Get the fully merged configuration as a map:

```elixir
all_config = LayeredConfig.to_map(config)
# Returns merged global + project + session + defaults
```

### layer_to_map/2

Get a specific layer as a map:

```elixir
project_only = LayeredConfig.layer_to_map(config, :project)
```

## Persistence

### save_global/1

Save the global layer to disk:

```elixir
:ok = LayeredConfig.save_global(config)
# Writes to ~/.lemon/agent/config.exs
```

### save_project/1

Save the project layer to disk:

```elixir
:ok = LayeredConfig.save_project(config)
# Writes to <cwd>/.lemon/config.exs
```

## Default Values

The module includes sensible defaults for all settings:

```elixir
%{
  # Model settings
  model: nil,
  thinking_level: :off,

  # Compaction settings
  compaction: %{
    enabled: true,
    reserve_tokens: 16384,
    keep_recent_tokens: 20000
  },

  # Retry settings
  retry: %{
    enabled: true,
    max_retries: 3,
    base_delay_ms: 1000
  },

  # Tool settings
  tools: %{
    bash: %{timeout: 120_000, sandbox: false},
    read: %{max_lines: 2000},
    write: %{confirm: false},
    edit: %{confirm: false},
    glob: %{max_results: 1000},
    grep: %{max_results: 500, context_lines: 2}
  },

  # Extension paths
  extensions: [],

  # Shell settings
  shell: %{
    path: nil,
    command_prefix: nil
  },

  # Display settings
  theme: "default",
  debug: false
}
```

## Layer Precedence

Values are resolved in this order (highest to lowest precedence):

1. **Session** - Runtime overrides set via `put/3`
2. **Project** - From `<project>/.lemon/config.exs`
3. **Global** - From `~/.lemon/agent/config.exs`
4. **Defaults** - Built-in default values

For nested maps, deep merging is performed - only the specified keys are overridden.

## Examples

### Basic Usage

```elixir
alias CodingAgent.LayeredConfig

# Load config for current project
config = LayeredConfig.load("/home/user/my-project")

# Get model with fallback
model = LayeredConfig.get(config, :model, "claude-sonnet-4-20250514")

# Get nested tool config
bash_timeout = LayeredConfig.get(config, [:tools, :bash, :timeout])

# Override for this session
config = LayeredConfig.put(config, :thinking_level, :high)
```

### Per-Project Overrides

Create `.lemon/config.exs` in your project:

```elixir
# my-project/.lemon/config.exs
[
  # Use a different model for this project
  model: "claude-opus-4-20250514",
  thinking_level: :high,

  # Longer timeout for complex builds
  tools: [
    bash: [timeout: 300_000]
  ]
]
```

### Checking Configuration Sources

```elixir
# See where a value comes from
global_model = LayeredConfig.get_layer(config, :global, :model)
project_model = LayeredConfig.get_layer(config, :project, :model)
session_model = LayeredConfig.get_layer(config, :session, :model)

IO.puts("Global: #{inspect(global_model)}")
IO.puts("Project: #{inspect(project_model)}")
IO.puts("Session: #{inspect(session_model)}")
IO.puts("Effective: #{inspect(LayeredConfig.get(config, :model))}")
```

### Exporting Configuration

```elixir
# Export full merged config
all = LayeredConfig.to_map(config)
IO.inspect(all, label: "Full config")

# Export just project overrides
project = LayeredConfig.layer_to_map(config, :project)
IO.inspect(project, label: "Project config")
```

## Relationship to SettingsManager

`LayeredConfig` is complementary to `CodingAgent.SettingsManager`:

| Feature | LayeredConfig | SettingsManager |
|---------|---------------|-----------------|
| Format | Elixir scripts (.exs) | JSON |
| Features | Deep merge, nested keys | Flat settings, validation |
| Use case | Advanced configuration | Simple settings |
| Layers | Global, Project, Session | Global, Project |

Both can be used together - `SettingsManager` for simple settings, `LayeredConfig` for complex configuration.
