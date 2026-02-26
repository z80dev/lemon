# Extensions

Extensions are the plugin system for Lemon. They allow you to add custom tools, hooks, and capabilities to the coding agent without modifying the core codebase.

## Quick Start

1. Create a file in `~/.lemon/agent/extensions/` (global) or `.lemon/extensions/` (project-local)
2. Implement the `CodingAgent.Extensions.Extension` behaviour
3. The extension will be automatically loaded on session start

## Extension Behaviour

Every extension must implement the `CodingAgent.Extensions.Extension` behaviour with at least `name/0` and `version/0`:

```elixir
defmodule MyExtension do
  @behaviour CodingAgent.Extensions.Extension

  @impl true
  def name, do: "my-extension"

  @impl true
  def version, do: "1.0.0"

  # Optional: provide custom tools
  @impl true
  def tools(_cwd), do: []

  # Optional: register hooks
  @impl true
  def hooks, do: []
end
```

## Callbacks

| Callback | Required | Description |
|----------|----------|-------------|
| `name/0` | Yes | Returns the extension's unique name (lowercase with hyphens) |
| `version/0` | Yes | Returns the semantic version string |
| `tools/1` | No | Returns a list of `AgentCore.Types.AgentTool` structs |
| `hooks/0` | No | Returns a keyword list of event hooks |
| `capabilities/0` | No | Returns a list of capability atoms (e.g., `[:tools, :hooks]`) |
| `config_schema/0` | No | Returns a JSON Schema-like map for configuration options |
| `providers/0` | No | Returns a list of provider specifications for registration |

## Providing Tools

Extensions can provide custom tools that the agent can use:

```elixir
@impl true
def tools(_cwd) do
  [
    %AgentCore.Types.AgentTool{
      name: "my_tool",
      description: "What the tool does",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "input" => %{
            "type" => "string",
            "description" => "The input parameter"
          }
        },
        "required" => ["input"]
      },
      label: "My Tool",
      execute: fn _id, %{"input" => input}, _signal, _on_update ->
        %AgentCore.Types.AgentToolResult{
          content: [%{type: "text", text: "Result: #{input}"}]
        }
      end
    }
  ]
end
```

### Tool Parameters

- `name` - The tool identifier (used in LLM tool calls)
- `description` - What the tool does (shown to the LLM)
- `parameters` - JSON Schema for tool parameters
- `label` - Human-readable display name
- `execute` - Function with signature `(tool_use_id, args, abort_signal, on_update) -> AgentToolResult`

### Tool Execute Function

The execute function receives:
- `tool_use_id` - Unique ID for this tool invocation
- `args` - Map of parsed arguments matching your parameters schema
- `abort_signal` - An `AbortSignal` for checking if execution should stop
- `on_update` - Callback for streaming partial updates

Return an `AgentCore.Types.AgentToolResult`:

```elixir
%AgentCore.Types.AgentToolResult{
  content: [%{type: "text", text: "output"}],
  is_error: false  # optional, defaults to false
}
```

## Registering Hooks

Hooks allow extensions to respond to agent lifecycle events:

```elixir
@impl true
def hooks do
  [
    on_agent_start: fn -> :ok end,
    on_agent_end: fn messages -> :ok end,
    on_turn_start: fn -> :ok end,
    on_turn_end: fn message, tool_results -> :ok end,
    on_message_start: fn message -> :ok end,
    on_message_end: fn message -> :ok end,
    on_tool_execution_start: fn id, name, args -> :ok end,
    on_tool_execution_end: fn id, name, result, is_error -> :ok end
  ]
end
```

### Available Hooks

| Hook | Arguments | Description |
|------|-----------|-------------|
| `on_agent_start` | none | Called when agent run starts |
| `on_agent_end` | `messages` | Called when agent run ends |
| `on_turn_start` | none | Called when a new turn starts |
| `on_turn_end` | `message, tool_results` | Called when turn ends |
| `on_message_start` | `message` | Called when message processing starts |
| `on_message_end` | `message` | Called when message processing ends |
| `on_tool_execution_start` | `id, name, args` | Called when tool starts |
| `on_tool_execution_end` | `id, name, result, is_error` | Called when tool ends |

Hook errors are caught and logged but don't stop other hooks or the agent.

## Declaring Capabilities

Extensions can declare their capabilities for discovery and filtering:

```elixir
@impl true
def capabilities, do: [:tools, :hooks]
```

### Common Capability Atoms

| Capability | Description |
|------------|-------------|
| `:tools` | Extension provides custom tools |
| `:hooks` | Extension provides event hooks |
| `:prompts` | Extension provides custom prompts/skills |
| `:resources` | Extension provides resources (CLAUDE.md, etc.) |
| `:mcp` | Extension connects to MCP servers |

UIs can use capabilities to filter extensions by functionality.

## Configuration Schema

Extensions can declare a configuration schema to enable UIs to render settings forms:

```elixir
@impl true
def config_schema do
  %{
    "type" => "object",
    "properties" => %{
      "api_key" => %{
        "type" => "string",
        "description" => "API key for the service",
        "secret" => true
      },
      "timeout" => %{
        "type" => "integer",
        "description" => "Request timeout in milliseconds",
        "default" => 5000
      },
      "enabled" => %{
        "type" => "boolean",
        "description" => "Enable this extension",
        "default" => true
      }
    },
    "required" => ["api_key"]
  }
end
```

The schema follows JSON Schema conventions with optional extensions:
- `secret: true` - Indicates the field should be masked in UIs
- `default` - Default value for the field

## Registering Providers

Extensions can register custom providers that integrate with the core system. Currently, `:model` type providers are supported, allowing extensions to add custom AI model backends.

```elixir
@impl true
def providers do
  [
    %{
      type: :model,
      name: :my_custom_model,
      module: MyExtension.CustomModelProvider,
      config: %{api_key_env: "MY_API_KEY"}
    }
  ]
end
```

### Provider Specification Fields

| Field | Type | Description |
|-------|------|-------------|
| `type` | atom | The provider type (currently only `:model` is supported) |
| `name` | atom | Unique identifier for the provider |
| `module` | module | The module implementing the provider behaviour |
| `config` | map | Optional configuration passed to the provider |

### Provider Registration Process

1. **At session startup**: All extension providers are collected and registered into `Ai.ProviderRegistry`
2. **On extension reload**: Old providers are unregistered, extensions are reloaded, and new providers are registered
3. **Conflict detection**: When multiple extensions register the same provider name, the first (alphabetically by module name) wins

### Provider Precedence

Similar to tools, providers follow a precedence order:

1. **Built-in providers always win** - Core providers (anthropic, openai, etc.) take priority
2. **First loaded extension wins** - Extensions are sorted alphabetically by module name

### Provider Conflicts in Status Report

Provider registration conflicts are included in the extension status report:

```elixir
%{
  # ... other fields ...
  provider_registration: %{
    registered: [
      %{type: :model, name: :custom_model, module: MyProvider, extension: MyExtension}
    ],
    conflicts: [
      %{
        type: :model,
        name: :conflicting_model,
        winner: ExtensionA,          # or :builtin if shadowed by core
        shadowed: [ExtensionB, ExtensionC]
      }
    ],
    total_registered: 1,
    total_conflicts: 1
  }
}
```

### Implementing a Model Provider

Model providers must implement the `Ai.Provider` behaviour:

```elixir
defmodule MyExtension.CustomModelProvider do
  @behaviour Ai.Provider

  @impl true
  def stream(model, context, opts) do
    # Streaming implementation
    {:ok, event_stream}
  end

  @impl true
  def provider_id, do: :my_provider

  @impl true
  def api_id, do: :my_custom_model
end
```

See the `Ai.Provider` module documentation for full details on implementing providers.

## Extension Discovery

Extensions are discovered from:

1. **Global directory**: `~/.lemon/agent/extensions/`
2. **Project-local directory**: `.lemon/extensions/` (relative to working directory)

Supported file patterns:
- `*.ex` and `*.exs` files in the extensions directory
- `*/lib/**/*.ex` files for complex extensions with subdirectories

## Example Extension

See `examples/extensions/hello_world_extension.ex` for a complete working example.

```elixir
defmodule HelloWorldExtension do
  @behaviour CodingAgent.Extensions.Extension

  @impl true
  def name, do: "hello-world"

  @impl true
  def version, do: "1.0.0"

  @impl true
  def tools(_cwd) do
    [
      %AgentCore.Types.AgentTool{
        name: "hello",
        description: "Says hello to someone",
        parameters: %{
          "type" => "object",
          "properties" => %{
            "name" => %{"type" => "string", "description" => "Name to greet"}
          },
          "required" => ["name"]
        },
        label: "Hello",
        execute: fn _id, %{"name" => name}, _signal, _on_update ->
          %AgentCore.Types.AgentToolResult{
            content: [%{type: "text", text: "Hello, #{name}!"}]
          }
        end
      }
    ]
  end

  @impl true
  def hooks do
    [
      on_agent_start: fn -> IO.puts("Agent started!") end
    ]
  end
end
```

## Tool Precedence

All tools (built-in and extension) are assembled through `CodingAgent.ToolRegistry`, which provides:
- Centralized conflict detection
- Per-session enable/disable via `:disabled` and `:enabled_only` options
- Extension path customization via `:extension_paths` option

When multiple tools share the same name, the following precedence rules apply:

1. **Built-in tools always win** - Core tools (read, write, edit, bash, etc.) take priority over extension tools
2. **First loaded extension wins** - Extensions are loaded in alphabetical order by module name, so earlier modules take precedence

When a conflict is detected, a warning is logged that includes:
- The conflicting tool name
- The module that was shadowed
- Whether it was shadowed by a built-in or an earlier extension

Example warning:
```
[warning] Tool name conflict: extension tool 'read' from MyExtension is shadowed by built-in tool
```

This ensures deterministic tool resolution across sessions while allowing extensions to add new tools without risking silent conflicts.

## Extension Metadata API

For UIs and diagnostics, the extension system provides functions to query loaded extension metadata:

```elixir
# Get metadata for specific extensions
info = CodingAgent.Extensions.get_info(extensions)
# => [%{name: "my-ext", version: "1.0.0", module: MyExt, source_path: "/path/to/ext.ex",
#       capabilities: [:tools, :hooks], config_schema: %{"type" => "object", ...}}]

# Get source path for a specific extension module
path = CodingAgent.Extensions.get_source_path(MyExtension)
# => "/home/user/.lemon/agent/extensions/my_extension.ex"

# List all loaded extensions (global view)
all_extensions = CodingAgent.Extensions.list_extensions()
# => [%{name: "ext1", version: "1.0.0", module: Ext1, source_path: "...", ...}, ...]

# Find duplicate tool names across extensions (before merging with built-ins)
duplicates = CodingAgent.Extensions.find_duplicate_tools(extensions, cwd)
# => %{"my_tool" => [ExtensionA, ExtensionB]}
```

Each extension metadata map includes:
- `name` - The extension's name (from `name/0` callback)
- `version` - The extension's version (from `version/0` callback)
- `module` - The Elixir module implementing the extension
- `source_path` - The file path from which the extension was loaded
- `capabilities` - List of capability atoms (defaults to `[]` if not implemented)
- `config_schema` - JSON Schema-like map for configuration (defaults to `%{}` if not implemented)

## Tool Conflict Report API

For plugin observability, the `ToolRegistry` provides a structured conflict report that shows how tool name conflicts are resolved and captures extension load failures:

```elixir
report = CodingAgent.ToolRegistry.tool_conflict_report(cwd)
# => %{
#   conflicts: [
#     %{
#       tool_name: "read",
#       winner: :builtin,
#       shadowed: [{:extension, MyExtension}]
#     },
#     %{
#       tool_name: "custom_tool",
#       winner: {:extension, ExtensionA},
#       shadowed: [{:extension, ExtensionB}]
#     }
#   ],
#   total_tools: 14,
#   builtin_count: 13,
#   extension_count: 1,
#   shadowed_count: 2,
#   load_errors: [
#     %{
#       source_path: "/path/to/broken_extension.ex",
#       error: %CompileError{...},
#       error_message: "Compile error: unexpected token"
#     }
#   ]
# }
```

The report includes:
- `conflicts` - List of conflict entries, each containing:
  - `tool_name` - The conflicting tool name
  - `winner` - Source that won (`:builtin` or `{:extension, module()}`)
  - `shadowed` - List of `{:extension, module()}` tuples that were shadowed
- `total_tools` - Total number of tools available after conflict resolution
- `builtin_count` - Number of built-in tools
- `extension_count` - Number of extension tools (after shadowing)
- `shadowed_count` - Total number of shadowed tools
- `load_errors` - List of extension load errors, each containing:
  - `source_path` - Path to the file that failed to load
  - `error` - The error exception/term
  - `error_message` - Human-readable error message

This is useful for:
- Debugging why a custom tool isn't appearing
- Building UIs that show plugin health/status
- Detecting extension conflicts before they cause issues
- Identifying broken extensions that failed to compile or load

## Extension Status Report

At session startup, a comprehensive extension status report is built and published as an event. This provides a single source of truth for UI/CLI consumption about extension health.

### Getting the Status Report

```elixir
# From the session state
state = Session.get_state(session)
report = state.extension_status_report

# Or via the dedicated API
report = Session.get_extension_status_report(session)
```

### Subscribing to the Status Report Event

The report is also published as an event after session initialization:

```elixir
# Subscribe to session events
unsub = Session.subscribe(session)

receive do
  {:session_event, _session_id, {:extension_status_report, report}} ->
    IO.inspect(report, label: "Extension Status")
end
```

### Status Report Structure

```elixir
%{
  # Successfully loaded extensions with metadata
  extensions: [
    %{
      name: "my-extension",
      version: "1.0.0",
      module: MyExtension,
      source_path: "/path/to/extension.ex",
      capabilities: [:tools, :hooks],
      config_schema: %{...}
    }
  ],

  # Extensions that failed to load
  load_errors: [
    %{
      source_path: "/path/to/bad_extension.ex",
      error: %CompileError{...},
      error_message: "Compile error: unexpected token"
    }
  ],

  # Tool conflict report from ToolRegistry
  tool_conflicts: %{
    conflicts: [...],
    total_tools: 14,
    builtin_count: 13,
    extension_count: 1,
    shadowed_count: 0
  },

  # Provider registration report
  provider_registration: %{
    registered: [
      %{type: :model, name: :custom_model, module: CustomProvider, extension: MyExtension}
    ],
    conflicts: [],
    total_registered: 1,
    total_conflicts: 0
  },

  # Summary counts
  total_loaded: 2,
  total_errors: 1,
  loaded_at: 1706745600000
}
```

### Loading Extensions with Error Tracking

For programmatic use, you can load extensions and capture errors:

```elixir
{:ok, extensions, load_errors, validation_errors} = CodingAgent.Extensions.load_extensions_with_errors([
  "~/.lemon/agent/extensions",
  "/path/to/project/.lemon/extensions"
])

# Register extension providers
provider_report = CodingAgent.Extensions.register_extension_providers(extensions)

# Build a status report manually
report = CodingAgent.Extensions.build_status_report(extensions, load_errors,
  cwd: "/project",
  provider_registration: provider_report
)
```

This is useful for:
- CLI status displays showing extension health
- Web UIs rendering extension management panels
- Diagnostic tools troubleshooting extension issues
- Build systems validating extension configurations

## Extensions Status Tool

The agent has access to a built-in `extensions_status` tool that allows it to self-diagnose plugin loading issues, conflicts, and reload extensions during a session. This is useful for debugging when:
- An expected tool isn't available
- Extensions fail to load with syntax or compile errors
- Tool name conflicts prevent extension tools from being used
- Extensions have been added, modified, or removed during the session

### Using the Tool

The agent can call the tool with optional `action` and `include_details` parameters:

```
# Summary view (default)
extensions_status {}

# Detailed view with source paths and modules
extensions_status {"include_details": true}

# Reload extensions (re-discover and refresh tool registry)
extensions_status {"action": "reload"}

# Reload with details
extensions_status {"action": "reload", "include_details": true}
```

### Actions

| Action | Description |
|--------|-------------|
| `status` | Get the current extension status report (default) |
| `reload` | Re-discover extensions from all paths, refresh the tool registry, and update the status report |

### Output Format

The tool returns a markdown-formatted report including:

```markdown
# Extension Status Report

- **Extensions loaded:** 2
- **Load errors:** 1
- **Loaded at:** 2024-01-31 15:30:00 UTC

## Loaded Extensions
- **my-extension** v1.0.0 (tools, hooks)
- **another-ext** v2.0.0

## Load Errors
- `/path/to/bad_extension.ex`
  - Compile error: unexpected token at line 15

## Tool Registry
- **Total tools:** 17
- **Built-in:** 16
- **From extensions:** 1
- **Shadowed:** 0
```

When `include_details: true`, extension entries also show:
- Source file path
- Module name
- Whether the extension has a config schema

### Reloading Extensions

The `reload` action allows the agent to refresh the extension system without restarting the session. This is useful when:
- New extension files have been added to the extensions directories
- Existing extensions have been modified
- Extensions have been removed and should no longer be loaded

When reload is triggered:
1. All currently loaded extension modules are purged from the code server
2. Extensions are re-discovered from all configured paths
3. The tool registry is rebuilt with conflict detection
4. The session's tools and hooks are updated
5. A new `{:extension_status_report, report}` event is broadcast

```elixir
# Reload via tool (from within agent)
extensions_status {"action": "reload"}

# Reload via Session API (from external code)
{:ok, report} = CodingAgent.Session.reload_extensions(session)
```

### Fallback Mode and Cached Errors

When the `extensions_status` tool is called without an active session context (e.g., no session_id or session not found), it operates in "fallback mode". In this mode, it retrieves:

- **Loaded extensions** from the global extension registry
- **Tool conflicts** computed for the current working directory
- **Cached load errors** from the most recent `load_extensions_with_errors/1` call

This allows observability into extension issues even when no session context exists. The cached errors include:
- Source path of the failed extension
- Error type and message
- Timestamp of when extensions were last loaded

```elixir
# Retrieve cached errors programmatically
{errors, loaded_at} = CodingAgent.Extensions.last_load_errors()
# => {[%{source_path: "/path/to/bad.ex", error_message: "Syntax error..."}], 1706745600000}
```

The fallback title in the tool result also includes error counts:
- `"2 loaded, 1 errors (no session context)"` - when there are load errors
- `"2 loaded, 1 conflicts (session not found)"` - when there are tool conflicts
- `"2 loaded, 1 errors, 1 conflicts (no session context)"` - when both exist

## Best Practices

1. **Use descriptive names** - Tool names should clearly indicate what they do
2. **Provide helpful descriptions** - The LLM uses descriptions to decide when to use tools
3. **Validate inputs** - Check arguments before processing
4. **Handle errors gracefully** - Return `is_error: true` with a helpful message
5. **Keep hooks lightweight** - Don't block the agent with slow hook processing
6. **Use the `cwd` parameter** - Make tools context-aware when needed
7. **Use unique tool names** - Avoid naming tools the same as built-ins or other extensions
