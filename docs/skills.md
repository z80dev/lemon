# CodingAgent.Skills - Skill Definitions and Loading

This document describes the `CodingAgent.Skills` module for managing reusable knowledge modules that get injected into agent context when relevant.

## Overview

Skills are markdown files with YAML frontmatter that contain domain-specific knowledge. When a user's request matches a skill's description, the skill content is automatically injected into the system prompt to provide the agent with relevant context.

## Location

File: `apps/coding_agent/lib/coding_agent/skills.ex`

## Skill File Structure

Skills are stored in directories:

- **Project skills**: `.lemon/skill/<skill-name>/SKILL.md`
- **Global skills**: `~/.lemon/agent/skill/<skill-name>/SKILL.md`

Project skills override global skills with the same name.

### SKILL.md Format

Each skill must have a `SKILL.md` file with YAML frontmatter:

```markdown
---
name: bun-file-io
description: Use this when working on file operations like reading, writing, or scanning files.
---

## When to use

- Editing file I/O code
- Handling directory operations
- Working with streams

## Patterns

- Use `Bun.file(path)` for file access
- Check `exists()` before reading
- Use `write()` with proper error handling

## Examples

### Reading a file
```javascript
const file = Bun.file("./data.txt");
if (await file.exists()) {
  const content = await file.text();
}
```

### Writing a file
```javascript
await Bun.write("./output.txt", "Hello, World!");
```
```

### Frontmatter Fields

| Field | Required | Description |
|-------|----------|-------------|
| `name` | No | Skill identifier (defaults to directory name) |
| `description` | Yes | Used for relevance matching |

## API Reference

### list/1

List all available skills for a working directory.

```elixir
skills = CodingAgent.Skills.list("/path/to/project")
# => [
#   %{
#     name: "bun-file-io",
#     description: "Use this when working on file operations...",
#     content: "## When to use\n...",
#     path: "/path/to/project/.lemon/skill/bun-file-io/SKILL.md"
#   }
# ]
```

### get/2

Get a specific skill by name.

```elixir
skill = CodingAgent.Skills.get("/path/to/project", "bun-file-io")
# => %{name: "bun-file-io", description: "...", content: "...", path: "..."}

# Returns nil if not found
nil = CodingAgent.Skills.get("/path/to/project", "nonexistent")
```

### find_relevant/3

Find skills relevant to a given context/query using keyword matching.

```elixir
# Find skills related to file operations
skills = CodingAgent.Skills.find_relevant(
  "/path/to/project",
  "I need to read and write files",
  3  # max results
)
# => [%{name: "bun-file-io", ...}]
```

The function scores skills based on:
- Name match (10 points if skill name appears in context)
- Description word matches (3 points each)
- Content word matches (1 point each)

### format_for_prompt/1

Format skills for injection into the system prompt.

```elixir
formatted = CodingAgent.Skills.format_for_prompt(skills)
# => """
# <skill name="bun-file-io">
# ## When to use
# ...
# </skill>
# """
```

### format_for_description/1

Format skill list for display to users.

```elixir
description = CodingAgent.Skills.format_for_description("/path/to/project")
# => "- bun-file-io: Use this when working on file operations...\n- react-hooks: ..."
```

## Creating Skills

### 1. Create the skill directory

```bash
# Project skill
mkdir -p .lemon/skill/my-skill

# Global skill
mkdir -p ~/.lemon/agent/skill/my-skill
```

### 2. Create SKILL.md

```bash
cat > .lemon/skill/my-skill/SKILL.md << 'EOF'
---
name: my-skill
description: Use this when working on X, Y, or Z tasks.
---

## Overview

Brief description of what this skill covers.

## Key Concepts

- Concept 1
- Concept 2

## Common Patterns

### Pattern 1

```code
example code
```

### Pattern 2

```code
example code
```

## Best Practices

- Practice 1
- Practice 2
EOF
```

### 3. Test the skill

```elixir
iex> CodingAgent.Skills.list("/path/to/project")
[%{name: "my-skill", ...}]

iex> CodingAgent.Skills.find_relevant("/path/to/project", "working on X")
[%{name: "my-skill", ...}]
```

## Example Skills

### Database Operations

```markdown
---
name: database
description: Use for database queries, migrations, and data modeling.
---

## Schema Design

- Use UUIDs for primary keys
- Add timestamps to all tables
- Use foreign key constraints

## Query Patterns

### Select with JOIN
```sql
SELECT u.name, o.total
FROM users u
JOIN orders o ON o.user_id = u.id
WHERE o.created_at > NOW() - INTERVAL '30 days';
```

## Migrations

Always create reversible migrations with `up` and `down` methods.
```

### React Components

```markdown
---
name: react-components
description: Use when building React components, hooks, or managing state.
---

## Component Structure

```tsx
interface Props {
  title: string;
  onSubmit: () => void;
}

export function MyComponent({ title, onSubmit }: Props) {
  const [loading, setLoading] = useState(false);

  return (
    <div>
      <h1>{title}</h1>
      <button onClick={onSubmit} disabled={loading}>
        Submit
      </button>
    </div>
  );
}
```

## Hooks

- Use `useState` for local state
- Use `useEffect` for side effects
- Create custom hooks for reusable logic
```

### API Design

```markdown
---
name: api-design
description: Use when designing REST APIs, handling requests, or writing endpoints.
---

## Endpoint Naming

- Use plural nouns: `/users`, `/orders`
- Use kebab-case: `/order-items`
- Use nesting for relationships: `/users/:id/orders`

## HTTP Methods

| Method | Purpose |
|--------|---------|
| GET    | Retrieve resource(s) |
| POST   | Create new resource |
| PUT    | Replace resource |
| PATCH  | Partial update |
| DELETE | Remove resource |

## Response Codes

- 200 OK - Successful GET/PUT/PATCH
- 201 Created - Successful POST
- 204 No Content - Successful DELETE
- 400 Bad Request - Invalid input
- 404 Not Found - Resource doesn't exist
- 500 Internal Error - Server failure
```

## Integration

Skills are typically used during session initialization:

```elixir
# In session setup
skills = CodingAgent.Skills.list(cwd)

# Or find relevant skills based on user query
relevant = CodingAgent.Skills.find_relevant(cwd, user_query, 3)

# Format for system prompt
skill_content = CodingAgent.Skills.format_for_prompt(relevant)

system_prompt = """
You are a coding assistant.

#{skill_content}

Follow the patterns and practices described in the skills above.
"""
```

## Project vs Global Skills

| Aspect | Project Skills | Global Skills |
|--------|----------------|---------------|
| Location | `.lemon/skill/` | `~/.lemon/agent/skill/` |
| Scope | Single project | All projects |
| Override | Overrides global | Default |
| Use case | Project-specific patterns | General knowledge |

When a skill exists in both locations, the project version takes precedence.

---

## MCP (Model Context Protocol) Server Integration

Lemon supports discovering and invoking tools from external MCP servers. This allows agents to use tools provided by external services that implement the Model Context Protocol.

### Configuration

MCP servers can be configured in several ways:

#### 1. Application Configuration

Add MCP server configurations to your `config/config.exs`:

```elixir
config :lemon_skills, :mcp_servers, [
  # Stdio transport (command-based)
  {:stdio, "npx", ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/files"]},
  
  # Stdio with uvx
  {:stdio, "uvx", ["mcp-server-git", "--repository", "/path/to/repo"]},
  
  # HTTP transport
  {:http, "http://localhost:3000/mcp"},
  
  # HTTP with authentication headers
  {:http, "https://api.example.com/mcp", [headers: [{"Authorization", "Bearer token"}]]}
]
```

#### 2. Environment Variable

Set the `LEMON_MCP_SERVERS` environment variable with a JSON array:

```bash
export LEMON_MCP_SERVERS='[
  {"type": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/files"]},
  {"type": "http", "url": "http://localhost:3000/mcp"}
]'
```

#### 3. JSON Configuration Files

Create MCP configuration files:

**Global configuration**: `~/.lemon/agent/mcp.json`
```json
{
  "enabled": true,
  "servers": [
    {
      "type": "stdio",
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/home/user/files"]
    }
  ]
}
```

**Project configuration**: `.lemon/mcp.json`
```json
{
  "enabled": true,
  "servers": [
    {
      "type": "stdio", 
      "command": "uvx",
      "args": ["mcp-server-git", "--repository", "."]
    }
  ]
}
```

Project configuration takes precedence over global configuration.

### MCP Server Configuration Schema

#### Stdio Transport

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | Yes | Must be `"stdio"` |
| `command` | string | Yes | The command to execute |
| `args` | array | No | Command arguments (default: `[]`) |

#### HTTP Transport

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | Yes | Must be `"http"` |
| `url` | string | Yes | The MCP server URL |
| `headers` | object | No | Additional HTTP headers |

### Tool Discovery and Caching

MCP tools are discovered automatically when the application starts and are cached for performance:

- **Cache TTL**: 5 minutes (configurable via `:cache_ttl_ms`)
- **Refresh Interval**: 1 minute (configurable via `:refresh_interval_ms`)
- **Graceful Degradation**: If an MCP server is unavailable, tools from that server are skipped

### Disabling MCP

To disable MCP integration:

```elixir
config :lemon_skills, :mcp_disabled, true
```

Or via environment variable:

```bash
export LEMON_MCP_DISABLED=1
```

### Tool Precedence

When tool names conflict, the precedence order is:

1. Built-in tools (highest priority)
2. WASM tools
3. Extension tools
4. MCP tools (lowest priority)

MCP tools with conflicting names will be shadowed by tools from other sources.

### Example: Using MCP Tools

Once configured, MCP tools appear alongside native tools:

```elixir
# List all available tools including MCP tools
tools = CodingAgent.ToolRegistry.get_tools("/path/to/project")

# MCP tools are tagged with label "MCP: <tool_name>"
Enum.each(tools, fn tool ->
  IO.puts("#{tool.name}: #{tool.label}")
end)
```

### Status and Debugging

Check MCP server status:

```elixir
# Get status of all MCP servers
LemonSkills.McpSource.status()
# => %{
#   disabled: false,
#   servers: %{
#     :abc123 => %{connected: true, tool_count: 5, last_error: nil},
#     :def456 => %{connected: false, tool_count: 0, last_error: {:connection_failed, :econnrefused}}
#   },
#   cached_tools: 5,
#   cache_ttl_ms: 300000
# }
```

Force a cache refresh:

```elixir
LemonSkills.McpSource.refresh()
```

### Validation

Validate MCP server configurations before applying them:

```elixir
configs = [
  {:stdio, "npx", ["-y", "server"]},
  {:http, "http://localhost:3000/mcp"}
]

case LemonSkills.Config.validate_mcp_servers(configs) do
  {:ok, valid_configs} ->
    IO.puts("All #{length(valid_configs)} configurations are valid")
  
  {:error, errors} ->
    Enum.each(errors, fn {:invalid, config, reason} ->
      IO.puts("Invalid config #{inspect(config)}: #{reason}")
    end)
end
```

### Supported MCP Servers

Popular MCP servers you can integrate:

- **Filesystem**: `@modelcontextprotocol/server-filesystem` - File operations
- **Git**: `mcp-server-git` - Git repository operations
- **SQLite**: `@modelcontextprotocol/server-sqlite` - Database operations
- **Brave Search**: `@modelcontextprotocol/server-brave-search` - Web search

For a comprehensive list, see the [MCP Server Registry](https://modelcontextprotocol.io/servers).
