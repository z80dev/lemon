# LemonSkills - Skill Definitions and Loading

This document describes the `LemonSkills` module for managing reusable knowledge modules that agents load explicitly when relevant.

## Overview

Skills are markdown files with YAML frontmatter that contain domain-specific knowledge. The stable system prompt lists every displayable skill as a compact key plus one-line discovery description, with a marker for unavailable skills. Agents use `read_skill` to load instructions, paths, provenance, and requirement details on demand. Relevance selection uses cached metadata, keywords, and bounded body excerpts without injecting turn-specific skill bodies into the system prompt.

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
| `tags` | No | Up to 32 bounded safe strings |
| `keywords` | No | Up to 32 bounded relevance terms |
| `hide` | No | `true` omits the skill from the model-visible prompt listing, per-turn relevant-skill hints and missing-skill suggestions; it stays loadable by name (`read_skill`, `skill://`, `/skill:<name>`) and in `list`/CLI. Alias: `disable-model-invocation` (Agent Skills standard). Only boolean `true` hides. |

Present names and descriptions must be non-empty, single-line, valid UTF-8 without control or bidirectional formatting characters. Names are limited to 128 bytes, descriptions to 1,024 bytes, and each tag/keyword or requirement item to 128 bytes; list fields accept at most 32 string entries. Prompt rendering applies an additional defensive flatten/clamp/XML-escape pass. All catalog metadata is treated as untrusted discovery data; source/trust provenance is disclosed when a skill is loaded.

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

Search documents are precomputed and automatically invalidated when a coalesced content-identity check detects skill-file, directory-set, or lockfile changes. Calls score the cached snapshot outside the Registry GenServer and break equal scores by key. Requirement/status views use current PATH, environment, and disabled-skill config rather than cached readiness. The identity check interval is 50 ms; use `refresh: true` or `LemonSkills.refresh/1` when immediate read-after-write visibility is required.

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
{:ok, entry} = LemonSkills.install("hermes:optional/research/arxiv")
```

**Options:**
- `:cwd` - Project working directory for local installation
- `:global` - Install globally (default: true)
- `:approve` - Pre-approve installation (default: false)

### Official Hermes catalog

`LemonSkills.Sources.Hermes.catalog/1` discovers the official bundled and
optional skills from the live `NousResearch/hermes-agent` repository. Catalog
IDs route through the ordinary installer, static audit, and approval gate.

```elixir
{:ok, skills} = LemonSkills.Sources.Hermes.catalog(category: "research")
{:ok, detailed} = LemonSkills.Sources.Hermes.catalog(query: "paper", details: true)
```

Use `mix lemon.skill hermes [query]` in a source checkout, or `/skills` in the
terminal client for the category browser and multi-select importer.

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

### Portable skill and automation bundles

`LemonAutomation.Blueprint` composes the existing bundle hash, manifest lint,
deterministic audit, project config, registry refresh, profile store, and cron
manager into one preview-confirm-activate workflow. It does not add a second
skill registry. Remote operators address only safe IDs below
`~/.lemon/bundles`; local service callers may validate a trusted unpacked path.
The source and packaged `lemon blueprints` CLI is the normal operator UX over
that catalog-scoped control-plane boundary; a bundle ID plus `--profile`
previews by default, and mutation requires the exact fresh digest.
See the [skills user guide](user-guide/skills.md#portable-skill-and-automation-bundles)
for the version 1 manifest, exact confirmation flow, policy boundary, and
disabled example.

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

# Relevance is turn-local; call read_skill to load the selected content
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
`skill_manage`, `remember`, and `recall`.
Each curator run writes a machine report and a human report:

| Scope | Reports |
|-------|---------|
| Global | `~/.lemon/agent/logs/curator/<run>/run.json` and `REPORT.md` |
| Project | `<cwd>/.lemon/logs/curator/<run>/run.json` and `REPORT.md` |

`run.json` records the run timestamp, duration, transition counts, state transitions, candidates, whether an agent review is required, and the submitted review run id when the background curator launches a follow-up review. `REPORT.md` mirrors the same information in a scan-friendly form. The latest `run.json` path is also stored in `skills.curator.json` as `last_report_path`.

The CLI wrapper is `mix lemon.skill curator status|run|pause|resume`. `run --prompt` also prints the curator review prompt an agent can use to consolidate narrow learned skills into broader umbrella skills via `read_skill` and `skill_manage`. The prompt prefers patching an existing class-level skill first, then updating supporting files such as `references/`, `templates/`, or `scripts/`, then creating a new class-level umbrella only when no existing skill owns the reusable lesson.

`LemonAutomation.SkillCuratorManager` provides the background path. It checks for router idleness, respects the persisted curator interval/pause gates, runs the same conservative transitions, and submits the curator review prompt to `LemonRouter` only when agent-authored candidates need an agent consolidation pass. The default target is `agent:default:main`; override it with `config :lemon_automation, :skill_curator, agent_id: "...", session_key: "..."`. Background curator reviews default to a learning-only tool policy with `read_skill`, `skill_manage`, `remember`, and `recall`.

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

The readable names above also carry a stable 16-hex identity suffix. Always use
the name returned by discovery rather than constructing one: complete names are
ASCII and at most 64 characters. The suffix distinguishes server configurations,
raw tool names that normalize identically, and remote tools from built-in MCP
resource/prompt utilities.

### Manage named MCP servers

The same commands work in installed releases (`lemon`) and source checkouts
(`./bin/lemon`). They edit `.lemon/mcp.json` in the current project by default.
Use `--cwd PATH` to select another project, or `--global` to edit
`~/.lemon/agent/mcp.json` (respecting `LEMON_AGENT_DIR` and configured agent-directory
overrides).

```bash
lemon mcp add filesystem --stdio npx -- -y @modelcontextprotocol/server-filesystem .
lemon mcp add git --stdio uvx --approval always \
  --tool-approval git_status=never -- mcp-server-git --repository .
lemon mcp add remote --http https://example.com/mcp \
  --header 'Authorization=Bearer TOKEN' --global
lemon mcp add local --stdio server --env API_KEY=value -- --server-option
lemon mcp list --json
lemon mcp list --global
lemon mcp list --all
lemon mcp disable github
lemon mcp enable github --global
lemon mcp test filesystem
lemon mcp remove filesystem
lemon mcp add git --stdio uvx --replace -- mcp-server-git --repository .
```

Names are case-sensitive, 1–64 ASCII letters/digits/underscores/dots/hyphens,
starting with a letter or digit. `add` refuses an existing name unless
`--replace` is explicit; ambiguous duplicate names are always rejected.
`remove` and `test` select an exact name in the chosen file, not another scope.
`list` shows only that file, including unnamed legacy entries. It omits commands,
arguments, URLs, credential values, and arbitrary extension fields; environment,
header, and per-tool-policy entries are reported as counts.

`list --all` instead shows the effective merged set for the project (or the
global scope with `--global`), including servers imported from other tools,
with each server's source (`provider:scope`) and whether it is enabled; its
`--json` form uses an `effective` key and the same redaction.

`enable NAME` / `disable NAME` maintain the `enabled_servers` allowlist and
`disabled_servers` denylist of the selected Lemon file (project by default,
`--global` for the agent file). They accept any discovered name, including
imported ones, and apply to every source. The project file's state for a name
overrides the global file's; within one file the denylist wins. `enable` also
overrides a source entry's own `"enabled": false` / `"disabled": true`. Lemon
never edits other tools' files.

Repeat `--env KEY=VALUE`, `--header KEY=VALUE`, and
`--tool-approval TOOL=always|never` as needed. Environment options are stdio-only,
headers are HTTP-only. Pass all stdio subprocess arguments after `--`; they are
an argument vector, never a shell command. Stdio subprocesses default to the
requesting project's working directory. Shell history may retain credential
arguments: avoid literal secrets in shared terminals and do not commit these
configuration files.

`add` writes `"approval": "always"` unless `--approval never` is explicit.
`"tool_approvals"` maps exact **remote** tool names to `"always"` or `"never"`;
an exact override wins over the server default. Existing hand-written entries
without an approval field retain their previous behavior (`never`).
`never` only disables this MCP-specific requirement: it cannot bypass a stronger
runtime approval policy. The MCP requirement and runtime `ToolPolicy` are ORed:
either can require approval, but only one approval is requested. For example:

```json
{
  "name": "git",
  "type": "stdio",
  "command": "uvx",
  "args": ["mcp-server-git", "--repository", "."],
  "approval": "always",
  "tool_approvals": {"git_status": "never"}
}
```

For Lemon's generated resource and prompt utility tools, approval override keys
are the MCP method names: `resources/list`, `resources/read`, `prompts/list`, and
`prompts/get`. For example, `--tool-approval resources/read=always` requires
approval for resource reads. Ordinary remote tools still use their exact raw
tool names, not the published `mcp_...` names.

Mutations preserve unrelated servers, top-level fields, and unknown entry
extensions. Replacement retains omitted same-transport credentials and merges
supplied environment/header/tool-policy keys; changing transport removes obsolete
transport fields. Writes use a private `0600` temporary file and atomic rename.
Cooperating commands serialize with a sibling `.lock` directory and fail rather
than overwrite an invalid, busy, or concurrently changed file. After a killed
writer, inspect the lock and remove it only when no command is writing.

No daemon restart or separate reload command is needed: configuration is read
again for new sessions. Existing sessions do not automatically gain new tools;
reload their tools or open a new session to update their inventory. Removing or
replacing a configured server retires its shared connection at the next discovery
for that project. Calls using its previous tool name then fail rather than
silently routing to the replacement. ACP-owned connections are independent.
For matching names, project entries override global entries, which override
application/environment entries, which override servers imported from other
tools; unnamed entries remain additive. The first entry for a name claims it
even when that entry is disabled.

ACP-provided MCP servers are session-owned and default to approval `always`.
Their credentials remain in memory, never in global configuration or
`RunRequest.meta`; only an opaque MCP session identifier crosses that metadata
boundary. Closing the session or losing its connection owner closes its MCP
clients and transports.

Discovery respects the server's advertised tools, resources, and prompts
capabilities. Tools-only servers do not incur unsupported resource/prompt
requests; resource-only servers still expose Lemon's resource utility tools.

`test` opens an isolated, session-owned connection, performs the MCP handshake
and tool discovery, prints the discovered tool count, and closes the connection.
It does **not** invoke remote tools. It can launch the configured program or
contact its endpoint, so run it only for servers you trust. All commands support
`--json`; success exits `0`, operation failures exit `1`, and invalid arguments
exit `2`. Errors never print raw configuration or transport error terms.

### Servers from other tools

Lemon also imports MCP servers declared for other coding tools, in omp's
provider order. Within a provider, the project entry precedes the user entry:

| Provider | Project (requesting directory) | User (`~/`, opt-in except omp) |
|---|---|---|
| omp | `.omp/mcp.json`, `.omp/.mcp.json` | `~/.omp/agent/mcp.json`, `~/.omp/agent/.mcp.json` |
| Claude Code | `.claude/.mcp.json`, else `.claude/mcp.json` | `~/.claude.json` (`projects[<cwd>]` first, then top-level `mcpServers`, else `~/.claude/mcp.json`) |
| Codex | `.codex/config.toml` | `~/.codex/config.toml` |
| Gemini CLI | `.gemini/settings.json` | `~/.gemini/settings.json` |
| OpenCode | `opencode.json[c]`, `.opencode/opencode.json[c]` | `~/.config/opencode/opencode.json[c]` |
| Cursor | `.cursor/mcp.json` | `~/.cursor/mcp.json` |
| Windsurf | `.windsurf/mcp_config.json` | `~/.codeium/windsurf/mcp_config.json` |
| VS Code | `.vscode/mcp.json` (`servers` or `mcp.servers`) | — |
| Root files | `mcp.json`, `.mcp.json` | — |

Imported entries carry the command, arguments, environment, working directory,
URL, headers, timeouts, and tool filters (Codex `enabled_tools`/`disabled_tools`,
Gemini `includeTools`/`excludeTools`). Tool-specific OAuth/auth blocks are not
imported; configure those servers in Lemon's own file. A missing `type` means
stdio with a `command` or Streamable HTTP with a `url`; Gemini `httpUrl` is
Streamable HTTP and its bare `url` is SSE; OpenCode `local`/`remote` map to
stdio/HTTP; Windsurf `serverUrl` is the URL. Entries with both a command and a
URL, or with invalid names, are skipped and do not claim a name. `${VAR}` and
`${VAR:-default}` expand in the JSON providers (unresolved placeholders stay
literal); VS Code `${workspaceFolder}` is the project directory; OpenCode files
use OpenCode's `{env:VAR}` / `{file:path}` substitution and JSONC; Codex
`env_vars`, `env_http_headers`, and `bearer_token_env_var` read the current
environment, and relative Codex `cwd`/`./command` values resolve against the
config file's directory. Imported servers keep Lemon's namespacing, validation,
and approval behavior; without an `approval` field they default to `never`, like
hand-written Lemon entries.

**Trust:** a project-level file from any of these tools starts its stdio servers
the same way `.lemon/mcp.json` does when a session opens in that directory.
Review a repository's MCP files before running Lemon in it, disable unwanted
servers by name, or turn discovery off:

```bash
export LEMON_MCP_EXTERNAL_DISCOVERY=0      # or config :lemon_skills, :mcp_external_discovery, false
export LEMON_MCP_EXTERNAL_USER_DISCOVERY=1 # or config :lemon_skills, :mcp_external_user_discovery, true
```

Project files and the omp user file are read by default. Other tools'
user-level files are opt-in, matching omp; setting `CLAUDE_CONFIG_DIR` opts in
Claude Code's user files from that directory. User-level files are read from
the home directory, or from `config :lemon_skills, :mcp_discovery_home`; when
`LEMON_AGENT_DIR` or another agent/harness directory override isolates the
runtime and no discovery home is configured, no user-level files are read.
Launching from home or inside a foreign user-config directory does not turn
those files into project sources: the user-source opt-in still applies.

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

Project configuration takes precedence over global configuration. Either file
may also list `disabled_servers` / `enabled_servers` names (see
`lemon mcp enable|disable` above), and an entry with `"enabled": false` is
skipped while still claiming its name.

### MCP Server Configuration Schema

#### Stdio Transport

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `type` | string | Yes | Must be `"stdio"` |
| `command` | string | Yes | The command to execute |
| `args` | array | No | Command arguments (default: `[]`) |
| `env` | object | No | String environment overrides passed to the subprocess |
| `cwd` | string | No | Subprocess directory; defaults to the requesting project directory. Relative values resolve against that project. |
| `timeout_ms` | integer | No | Client request timeout (default: `10000`); tool invocation waits are capped at `300000` |
| `ready_timeout_ms` | integer | No | Client readiness wait in milliseconds (default: `5000`) |
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
| `ready_timeout_ms` | integer | No | Client startup/readiness wait in milliseconds (default: `5000`; PKCE authorization can extend this through `oauth.authorization_timeout_ms`) |
| `timeout_ms` | integer | No | HTTP request timeout (default: `10000`); tool invocation waits are capped at `300000` |
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
| `ready_timeout_ms` | integer | No | Client startup/readiness wait in milliseconds (default: `5000`) |
| `timeout_ms` | integer | No | SSE stream and POST request timeout in milliseconds (default: `10000` when configured through `LemonSkills.McpSource`) |
| `allow_tools` / `block_tools` | array | No | Exact MCP tool names to allow or block |
| `allow_resources` / `block_resources` | array | No | Exact MCP resource URIs to allow or block |
| `allow_prompts` / `block_prompts` | array | No | Exact MCP prompt names to allow or block |

Legacy HTTP+SSE entries use supervised `LemonMCP.Client.SSE` startup, open the SSE stream, consume the server `endpoint` event, POST JSON-RPC messages to that endpoint, and receive JSON-RPC responses from SSE `message` events. They expose the same tool/resource/prompt utility path and exact filters as stdio and Streamable HTTP entries.

### Tool Discovery and Caching

MCP tools are discovered through `LemonSkills.McpSource`, cached for performance, and surfaced through `CodingAgent.ToolRegistry`:

- **Cache TTL**: 5 minutes (configurable via `:cache_ttl_ms`)
- **Refresh Interval**: 1 minute (configurable via `:refresh_interval_ms`)
- **Graceful Degradation**: If an MCP server is unavailable, tools from that server are skipped
- **Model-facing names**: `mcp_<server>_<tool>_<identity>` names use a bounded readable prefix and a stable hash; different configurations of the same executable or URL remain distinct.
- **Resource/prompt utilities**: capable stdio, Streamable HTTP, and legacy HTTP+SSE servers also expose `resources/list`, `resources/read`, `prompts/list`, and `prompts/get` through model-facing utility tools
- **Exact filters**: stdio, Streamable HTTP, and legacy HTTP+SSE configs can constrain model-facing tools, resources, and prompts with exact allow/block lists before they enter the registry
- **Project isolation**: discovery returns only the requesting project's configured inventory. Discovering another project or refreshing global configuration does not retarget previously returned tool closures.
- **Live lists**: tools/resources/prompts `list_changed` notifications refresh the owning server's cached inventory through the same capability and exact-filter path. Notifications from retired connections are ignored.
- **Recovery**: the host reconnects lost clients after 500/1000/2000/4000 ms and refreshes inventory on success. Exhausting the ladder or more than five client crashes within 30 seconds marks only that server unavailable with a fixed, redacted status reason. Discovery and periodic refresh cannot bypass the breaker; explicit `LemonSkills.McpSource.refresh/0` (or `refresh(source_pid)`) resets it. Failed startup and retired clients are closed.
- **Bounded calls**: tool execution does not occupy the discovery/status GenServer. Timeouts and disconnects return errors without replaying an in-flight invocation; a timed-out remote mutation may already have taken effect.
- **External data**: MCP results remain untrusted. Stdio protocol buffering is limited to 8 MiB.
- **Optional manual smoke**: `MIX_ENV=test mix run scripts/live_mcp_stdio_smoke.exs` exercises the stdio server path against configured services; Lemon does not consume the result file.

### Disabling MCP

To disable MCP integration:

```elixir
config :lemon_skills, :mcp_disabled, true
```

Or via environment variable:

```bash
export LEMON_MCP_DISABLED=1
```

The external-tool import alone is controlled by `LEMON_MCP_EXTERNAL_DISCOVERY` /
`:mcp_external_discovery` (see [Servers from other tools](#servers-from-other-tools)).

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

# MCP names include a stable identity suffix; use tool.name verbatim.
# Labels retain "MCP <tool_name>" (or a resource/prompt utility name).
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
#     "abc123..." => %{connected: true, tool_count: 5, resource_count: 2, prompt_count: 1, capabilities: %{tools: true, resources: true, prompts: true}, last_error: nil},
#     "def456..." => %{connected: false, tool_count: 0, resource_count: 0, prompt_count: 0, capabilities: %{}, last_error: "connection failed"}
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

The shared configuration validator applies the same rules as
`LemonSkills.McpSource.validate_config/1`, including requiring
`persist_oauth_tokens` to be a boolean and `oauth_token_secret` to be a
non-empty string when either option is present on an HTTP or SSE source.

### Supported MCP Servers

Popular MCP servers you can integrate:

- **Filesystem**: `@modelcontextprotocol/server-filesystem` - File operations
- **Git**: `mcp-server-git` - Git repository operations
- **SQLite**: `@modelcontextprotocol/server-sqlite` - Database operations
- **Brave Search**: `@modelcontextprotocol/server-brave-search` - Web search

For reference implementations and server examples, see the
[Model Context Protocol servers repository](https://github.com/modelcontextprotocol/servers).
