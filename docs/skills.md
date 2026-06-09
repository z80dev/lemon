# LemonSkills - Skill Definitions and Loading

This document describes the `LemonSkills` module for managing reusable knowledge modules that get injected into agent context when relevant.

## Overview

Skills are markdown files with YAML frontmatter that contain domain-specific knowledge. When a user's request matches a skill's description, the skill content is automatically injected into the system prompt to provide the agent with relevant context.

## Location

File: `apps/lemon_skills/lib/lemon_skills.ex`

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

List all available skills.

```elixir
skills = LemonSkills.list()
skills = LemonSkills.list(cwd: "/path/to/project")
# => [%LemonSkills.Entry{key: "bun-file-io", ...}, ...]
```

**Options:**
- `:cwd` - Project working directory (optional, defaults to current directory)
- `:refresh` - Force refresh from disk (default: false)

### get/2

Get a specific skill by key.

```elixir
{:ok, skill} = LemonSkills.get("bun-file-io")
:error = LemonSkills.get("nonexistent")
```

**Options:**
- `:cwd` - Project working directory (optional)

### find_relevant/2

Find skills relevant to a given context/query using keyword matching.

```elixir
skills = LemonSkills.find_relevant("I need to read and write files", max_results: 3)
# => [%LemonSkills.Entry{key: "bun-file-io", ...}]
```

**Options:**
- `:cwd` - Project working directory (optional)
- `:max_results` - Maximum number of skills to return (default: 3)

### status/2

Check the status of a skill (whether required binaries/config are present).

```elixir
%{ready: true} = LemonSkills.status("simple-skill")
%{ready: false, missing_bins: ["kubectl"]} = LemonSkills.status("k8s-skill")
```

### install/2

Install a skill from a git repository or local path.

```elixir
{:ok, entry} = LemonSkills.install("https://github.com/user/skill-repo")
{:ok, entry} = LemonSkills.install("/local/path/to/skill", global: false)
```

**Options:**
- `:cwd` - Project working directory for local installation
- `:global` - Install globally (default: true)
- `:approve` - Pre-approve installation (default: false)

### update/2

Update an installed skill.

```elixir
{:ok, entry} = LemonSkills.update("my-skill")
```

### uninstall/2

Uninstall a skill.

```elixir
:ok = LemonSkills.uninstall("my-skill")
```

### enable/2, disable/2

Enable or disable a skill.

```elixir
:ok = LemonSkills.enable("my-skill")
:ok = LemonSkills.disable("my-skill")
```

### refresh/1

Force a reload of all skills from disk.

```elixir
:ok = LemonSkills.refresh()
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
iex> LemonSkills.list(cwd: "/path/to/project")
[%LemonSkills.Entry{key: "my-skill", ...}]

iex> LemonSkills.find_relevant("working on X", cwd: "/path/to/project")
[%LemonSkills.Entry{key: "my-skill", ...}]
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
skills = LemonSkills.list(cwd: cwd)

# Or find relevant skills based on user query
relevant = LemonSkills.find_relevant(user_query, cwd: cwd, max_results: 3)

# Skills are automatically injected into the system prompt when relevant
```

Agent tool usage emits skill-specific telemetry:

- `read_skill` emits `[:lemon_skills, :skill, :load]` for successful and missing skill loads.
- `skill_manage` emits `[:lemon_skills, :skill, :write]` for accepted and rejected write attempts.

Both events include `tool_call_id`, include session metadata when built through CodingAgent tool factories, avoid recording skill body content, update `LemonSkills.Usage`, and are persisted into introspection as `:skill_load_observed` / `:skill_write_observed`.

Usage and curation metadata lives outside `SKILL.md`:

| Scope | Sidecar |
|-------|---------|
| Global | `~/.lemon/agent/skills.usage.json` |
| Project | `<cwd>/.lemon/skills.usage.json` |

The sidecar tracks load/write counters, last-use fields, agent-authored creation provenance, and `lifecycle_state` (`active`, `stale`, `archived`, or `pinned`). Agents can use `skill_manage` actions `report`, `pin`, `unpin`, `archive`, and `restore` for curation. `report` returns usage rows plus stale/archive candidate flags for agent-authored skills; pinned skills are protected from delete/archive operations; archived skills are disabled through the normal `skills.json` mechanism.

`LemonSkills.Curator` runs the conservative maintenance pass over that sidecar:

- active agent-authored stale candidates become `stale`
- archive candidates become `archived` and are disabled in `skills.json`
- stale skills with recent activity are reactivated
- pinned and non-agent-authored skills are skipped
- no curator path deletes skills

Each curator run writes a machine report and a human report:

| Scope | Reports |
|-------|---------|
| Global | `~/.lemon/agent/logs/curator/<run>/run.json` and `REPORT.md` |
| Project | `<cwd>/.lemon/logs/curator/<run>/run.json` and `REPORT.md` |

`run.json` records the run timestamp, duration, transition counts, state transitions, candidates, whether an agent review is required, and the submitted review run id when the background curator launches a follow-up review. `REPORT.md` mirrors the same information in a scan-friendly form. The latest `run.json` path is also stored in `skills.curator.json` as `last_report_path`.

The CLI wrapper is `mix lemon.skill curator status|run|pause|resume`. `run --prompt` also prints the curator review prompt an agent can use to consolidate narrow learned skills into broader umbrella skills via `read_skill` and `skill_manage`. The prompt prefers patching an existing class-level skill first, then updating supporting files such as `references/`, `templates/`, or `scripts/`, then creating a new class-level umbrella only when no existing skill owns the reusable lesson.

`LemonAutomation.SkillCuratorManager` provides the Hermes-style background path. It checks for router idleness, respects the persisted curator interval/pause gates, runs the same conservative transitions, and submits the curator review prompt to `LemonRouter` only when agent-authored candidates need an agent consolidation pass. The default target is `agent:default:main`; override it with `config :lemon_automation, :skill_curator, agent_id: "...", session_key: "..."`. Background curator reviews default to a learning-only tool policy with `read_skill`, `skill_manage`, `search_memory`, and `memory_topic`.

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

Lemon supports discovering tools from external stdio, Streamable HTTP, and legacy HTTP+SSE MCP servers, plus listing/reading resources and listing/getting prompts from capable MCP servers. Discovered tools are exposed to models through `CodingAgent.ToolRegistry` with `mcp_<server>_<tool>` names, while the original MCP tool names remain inside the supervised client call boundary. Resource and prompt access is exposed through explicit utility tools such as `mcp_<server>_resources_list`, `mcp_<server>_resource_read`, `mcp_<server>_prompts_list`, and `mcp_<server>_prompt_get` when the server supports those MCP methods. Streamable HTTP also discovers OAuth protected-resource metadata from `WWW-Authenticate` challenges, follows declared authorization servers to their metadata documents, can use configured OAuth client credentials to fetch a bearer token from a discovered token endpoint before retrying the protected MCP request, supports `:client_secret_post` and `:client_secret_basic` token endpoint authentication, can retry with `grant_type=refresh_token` when a token response supplies a refresh token, rotates replacement refresh tokens, can reacquire a client-credentials bearer once when no refresh token is available, can use an authorization-code PKCE callback to acquire public-client bearer tokens, and can resume from persisted OAuth token cache material before making the first initialized MCP request. Configured Streamable HTTP sources can store token cache payloads in `LemonCore.Secrets` through an explicit `oauth.token_secret`; when a configured PKCE source uses a local `redirect_uri`, `LemonSkills.McpSource` reuses LemonCore's localhost OAuth listener, routes the authorization URL through a structured `mcp_*_oauth` operator approval, and then returns matching `code`/`state` to the MCP client. Stdio clients can opt into `sampling/createMessage` through a raw callback or a `LemonMCP.Sampling` policy wrapper; configured `LemonSkills.McpSource` stdio servers can bridge reviewed sampling through the existing `LemonCore.ExecApprovals` pipeline so control-plane and channel approval surfaces see only redacted sampling summaries before an operator approves or denies the delegate call. Lemon only advertises the sampling capability when one of those handlers is configured. Broader external-server compatibility remains a preview gap.

### Configuration

MCP servers can be configured in several ways:

#### 1. Application Configuration

Add MCP server configurations to your `config/config.exs`:

```elixir
config :lemon_skills, :mcp_servers, [
  # Stdio transport (command-based)
  {:stdio, "npx", ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/files"]},
  
  # Stdio with uvx
  {:stdio, "uvx", ["mcp-server-git", "--repository", "/path/to/repo"],
   allow_tools: ["git_status", "git_diff"]},
  
  # Streamable HTTP transport
  {:http, "http://localhost:3000/mcp"},
  
  # HTTP with authentication headers and exact tool filters
  {:http, "https://api.example.com/mcp",
   [headers: [{"Authorization", "Bearer token"}], allow_tools: ["search"]]},

  # HTTP with OAuth client-credentials token acquisition
  {:http, "https://oauth.example.com/mcp",
   [
     oauth: [
       client_id: "client",
       client_secret: "secret",
       scopes: ["tools"],
       token_auth_method: :client_secret_basic
     ]
   ]},

  # Legacy HTTP+SSE transport
  {:sse, "http://localhost:3001/sse"}
]
```

#### 2. Environment Variable

Set the `LEMON_MCP_SERVERS` environment variable with a JSON array:

```bash
export LEMON_MCP_SERVERS='[
  {"type": "stdio", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/files"]},
  {"type": "stdio", "command": "uvx", "args": ["mcp-server-git", "--repository", "."]},
  {"type": "sse", "url": "http://localhost:3001/sse"}
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
      "args": ["mcp-server-git", "--repository", "."],
      "allow_tools": ["git_status", "git_diff"],
      "block_prompts": ["unsafe_prompt"]
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
| `allow_tools` / `block_tools` | array | No | Exact MCP tool names to allow or block |
| `allow_resources` / `block_resources` | array | No | Exact MCP resource URIs or names to allow or block |
| `allow_prompts` / `block_prompts` | array | No | Exact MCP prompt names to allow or block |

Stdio clients can also be started directly with a `sampling_policy` on
`LemonMCP.Client.start_link/1`. `LemonMCP.Sampling` summarizes requests without
raw prompt text, enforces max-token and model allowlist limits, and can require
a reviewer approval before calling a model-backed delegate:

```elixir
sampling_policy: [
  mode: :reviewed_model,
  reviewer: :ops_approval,
  delegate: fn params, summary -> call_model(params, summary) end,
  max_tokens: 1_024,
  allowed_models: ["lemon"],
  approval_context: [
    run_id: run_id,
    session_key: session_key,
    agent_id: agent_id
  ]
]
```

When `reviewer: :ops_approval` is configured through `LemonSkills.McpSource`,
Lemon creates a pending `mcp_<server>_sampling` approval using only the redacted
summary fields: request hash, message count, roles, content-kind counts, text
character count, max tokens, and requested model. Control-plane approval
resolution, Telegram, and Discord reuse the normal execution approval flow. The raw
sampling request only reaches the configured delegate after approval.

The lower-level `sampling_handler` option is still available for integrations
that already own review and policy checks. It receives raw `sampling/createMessage`
params and must return either `{:ok, result_map}` or `{:error, reason}`.

#### HTTP Transport

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | Yes | Must be `"http"` |
| `url` | string | Yes | The MCP server URL |
| `headers` | object | No | Additional HTTP headers |
| `oauth` | object | No | OAuth settings: client-credentials `client_id` / `client_secret`, `client_secret_secret`, optional `token_secret`, or `flow: "authorization_code_pkce"` with public `client_id`, local `redirect_uri`, optional `scope` / `scopes`, `token_secret`, `authorization_timeout_ms`, `authorization_approval` (defaults true for local PKCE), and an optional runtime callback provider |
| `allow_tools` / `block_tools` | array | No | Exact MCP tool names to allow or block |
| `allow_resources` / `block_resources` | array | No | Exact MCP resource URIs to allow or block |
| `allow_prompts` / `block_prompts` | array | No | Exact MCP prompt names to allow or block |

Streamable HTTP entries use supervised `LemonMCP.Client.HTTP` startup, perform the MCP initialize/initialized handshake, send the required `Accept: application/json, text/event-stream` header, retain server-issued `Mcp-Session-Id` values, include the negotiated `MCP-Protocol-Version` on later requests, decode JSON responses, decode per-request SSE `message` responses, discover OAuth protected-resource metadata from 401 `WWW-Authenticate` challenges, follow `authorization_servers` entries to OAuth authorization-server metadata documents, use configured OAuth client credentials to request a bearer token from discovered token endpoints with form-post or HTTP Basic client authentication, retain refresh tokens returned by token endpoints, prefer `grant_type=refresh_token` on later 401 challenges when possible, use authorization-code PKCE callbacks for public clients, auto-host local PKCE callback capture for configured sources with localhost `redirect_uri`, route those local authorization requests through structured `mcp_*_oauth` operator approvals, persist and resume OAuth tokens through configured cache callbacks or `LemonSkills.McpSource` secret-backed `oauth.token_secret`, discover tools/resources/prompts, and call tools or access resources/prompts through the same `LemonSkills.McpSource` and `CodingAgent.ToolRegistry` path as stdio entries. Metadata discovery requests do not forward configured MCP headers or bearer tokens. HTTP resource/prompt utility tools are exposed when the server supports those methods.

#### Legacy HTTP+SSE Transport

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | Yes | Must be `"sse"` |
| `url` | string | Yes | The MCP SSE endpoint URL |
| `headers` | object | No | Additional HTTP headers |
| `allow_tools` / `block_tools` | array | No | Exact MCP tool names to allow or block |
| `allow_resources` / `block_resources` | array | No | Exact MCP resource URIs to allow or block |
| `allow_prompts` / `block_prompts` | array | No | Exact MCP prompt names to allow or block |

Legacy HTTP+SSE entries use supervised `LemonMCP.Client.SSE` startup, open the SSE stream, consume the server `endpoint` event, POST JSON-RPC messages to that endpoint, and receive JSON-RPC responses from SSE `message` events. They expose the same tool/resource/prompt utility path and exact filters as stdio and Streamable HTTP entries.

### Tool Discovery and Caching

MCP tools are discovered through `LemonSkills.McpSource`, cached for performance, and surfaced through `CodingAgent.ToolRegistry`:

- **Cache TTL**: 5 minutes (configurable via `:cache_ttl_ms`)
- **Refresh Interval**: 1 minute (configurable via `:refresh_interval_ms`)
- **Graceful Degradation**: If an MCP server is unavailable, tools from that server are skipped
- **Model-facing names**: stdio, Streamable HTTP, and legacy HTTP+SSE tools are exposed as `mcp_<server>_<tool>` so they do not collide with built-in, WASM, or extension tools
- **Resource/prompt utilities**: capable stdio, Streamable HTTP, and legacy HTTP+SSE servers also expose `resources/list`, `resources/read`, `prompts/list`, and `prompts/get` through model-facing utility tools
- **Exact filters**: stdio, Streamable HTTP, and legacy HTTP+SSE configs can constrain model-facing tools, resources, and prompts with exact allow/block lists before they enter the registry
- **Current proof**: `MIX_ENV=test mix run scripts/live_mcp_stdio_smoke.exs --out .lemon/proofs/mcp-stdio-latest.json` proves stdio startup, discovery, registry exposure, success/error calls, resource/prompt list/read/get utilities, exact allow/block filtering, degraded missing-command startup, `notifications/initialized` compatibility, the opt-in `sampling/createMessage` callback wrapper, the reviewed model-backed sampling policy wrapper, and the `mcp_stdio_sampling_ops_approval_bridge` through redacted pending approvals
- **HTTP proof**: `MIX_ENV=test mix run scripts/live_mcp_http_smoke.exs --out .lemon/proofs/mcp-http-latest.json` proves 24 Streamable HTTP checks: initialize, JSON and per-request SSE responses, session/protocol headers, OAuth protected-resource and authorization-server metadata discovery, OAuth client-credentials token acquisition, `client_secret_post` and `client_secret_basic` token endpoint auth, protected-request retry, refresh-token grant retry after a later 401, one-shot client-credentials bearer reacquisition when no refresh token is available, authorization-code PKCE callback/token exchange, OAuth token cache resume without another metadata/token request, configured-source loopback OAuth callback capture with `mcp_*_oauth` operator approval routing, tool/resource/prompt discovery, success/error calls, source resource/prompt utility invocation, registry exposure, status capability shape, and exact HTTP filtering
- **SSE proof**: `MIX_ENV=test mix run scripts/live_mcp_sse_smoke.exs --out .lemon/proofs/mcp-sse-latest.json` proves legacy HTTP+SSE endpoint discovery, tool/resource/prompt discovery, success/error calls, source resource/prompt utility invocation, registry exposure, status capability shape, and exact SSE filtering

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

# MCP tools are named like "mcp_elixir_echo" and tagged with label "MCP <tool_name>"
# Resource/prompt utilities are named like "mcp_elixir_resource_read" and "mcp_elixir_prompt_get"
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
#     :abc123 => %{connected: true, tool_count: 5, resource_count: 2, prompt_count: 1, capabilities: %{tools: true, resources: true, prompts: true}, last_error: nil},
#     :def456 => %{connected: false, tool_count: 0, resource_count: 0, prompt_count: 0, capabilities: %{}, last_error: {:connection_failed, :econnrefused}}
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

For reference implementations and server examples, see the
[Model Context Protocol servers repository](https://github.com/modelcontextprotocol/servers).
