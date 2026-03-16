# lemon-cli: Python TUI Client Implementation Plan

A Hermes-equivalent CLI/TUI for talking to the Lemon agent directly, built in Python with prompt_toolkit + Rich. Lives at `clients/lemon-cli/` alongside the existing TypeScript `lemon-tui`.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Project Structure](#2-project-structure)
3. [Dependencies & Packaging](#3-dependencies--packaging)
4. [Wire Protocol Specification](#4-wire-protocol-specification)
5. [Module Specifications](#5-module-specifications)
6. [Architecture Deep Dive](#6-architecture-deep-dive)
7. [Theme System](#7-theme-system)
8. [Implementation Order](#8-implementation-order)
9. [Verification Plan](#9-verification-plan)

---

## 1. Overview

### What This Is

A standalone Python TUI client that communicates with the Lemon agent backend via two protocols:
- **JSON-line RPC** -- spawns `debug_agent_rpc.exs` as a subprocess, talks via stdin/stdout JSON lines
- **WebSocket** -- connects to Lemon control plane at `ws://localhost:4040/ws` using the OpenClaw protocol

### What Already Exists (Reused As-Is)

- **AgentCore** (Elixir GenServer) -- agentic loop, event streaming, tool execution
- **CodingAgent.Session** -- session orchestration, tool registry, persistence
- **26 LLM providers** via the `Ai` library
- **debug_agent_rpc.exs** -- JSON-line RPC server (`scripts/debug_agent_rpc.exs`)
- **LemonControlPlane** -- WebSocket multiplexer (`apps/lemon_control_plane/`)
- **Config format** -- `~/.lemon/config.toml` (shared with lemon-tui)
- **Session persistence** -- JSONL session files (backend handles storage)

### Feature Scope (Tier 1 + Tier 2)

**Tier 1 -- Core Chat:**
Interactive REPL, streaming responses, tool progress display, status bar, banner, slash commands (~15 core), session management, signal handling, input history, config file support

**Tier 2 -- Rich Interaction:**
Interactive overlays (approval/clarify/confirm/input/editor), reasoning/thinking display, slash command autocomplete, file path completion, image clipboard paste, usage tracking, /retry + /undo + /rollback, theming/skin system

---

## 2. Project Structure

```
clients/lemon-cli/
  pyproject.toml
  src/
    lemon_cli/
      __init__.py
      __main__.py                 # `python -m lemon_cli` entry
      cli.py                      # argparse CLI, config resolution, bootstrap
      config.py                   # ~/.lemon/config.toml loading & merging
      types.py                    # Wire protocol dataclasses
      theme.py                    # 6 themes + skin extensibility
      constants.py                # Slash command defs, spinner frames, tool metadata

      connection/
        __init__.py
        base.py                   # Abstract AgentConnection interface
        rpc.py                    # JSON-line RPC subprocess connection
        websocket.py              # WebSocket OpenClaw connection
        protocol.py               # Shared parsing & event normalization

      state/
        __init__.py
        store.py                  # AppState + SessionState + listener pattern
        events.py                 # Event routing: session events -> state mutations
        usage.py                  # Cumulative token/cost tracking

      tui/
        __init__.py
        app.py                    # Main app: 3-thread model, lifecycle
        layout.py                 # HSplit layout assembly
        input_area.py             # TextArea + multiline + history + keybindings
        spinner.py                # Animated spinner with print_above()
        status_bar.py             # Model, tokens, cost, time, context %
        banner.py                 # Welcome screen + lemon ASCII art
        overlays/
          __init__.py
          base.py                 # Queue-based blocking overlay pattern
          select.py               # Numbered list selection
          confirm.py              # Y/n confirmation
          input_overlay.py        # Text input prompt
          editor.py               # $EDITOR launch

      display/
        __init__.py
        console.py                # Rich -> prompt_toolkit ANSI bridge
        panels.py                 # Rich Panels for messages
        markdown.py               # Rich Markdown wrapper
        thinking.py               # Thinking/reasoning panel
        tools.py                  # Tool execution progress lines

      formatters/
        __init__.py
        registry.py               # FormatterRegistry
        base.py                   # Shared utilities
        bash.py                   # Terminal/bash formatter
        read.py                   # Read file formatter
        edit.py                   # Edit file formatter
        grep.py                   # Grep/search formatter
        write.py                  # Write file formatter
        glob.py                   # Glob/find/ls formatter
        web.py                    # WebFetch/WebSearch formatter
        task.py                   # Task/todo/process formatter

      commands/
        __init__.py
        registry.py               # SlashCommand dataclass + dispatch
        core.py                   # /help /quit /new /model /clear /reset /history /save /usage /config /skin /stop
        session.py                # /sessions /running /switch /close /resume
        ui.py                     # /retry /undo /rollback /compact /thinking

      autocomplete/
        __init__.py
        slash.py                  # Slash command completer
        filepath.py               # Filesystem path completer
        combined.py               # Merged completer for TextArea

  bin/
    lemon-cli                     # Shell launcher script
```

---

## 3. Dependencies & Packaging

```toml
[project]
name = "lemon-cli"
version = "0.1.0"
description = "Python TUI client for Lemon coding agent"
requires-python = ">=3.11"
dependencies = [
    "prompt-toolkit>=3.0.47",
    "rich>=13.9",
    "websockets>=13.0",
]

[project.scripts]
lemon-cli = "lemon_cli.cli:main"

[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[tool.hatch.build.targets.wheel]
packages = ["src/lemon_cli"]

[tool.uv]
dev-dependencies = [
    "pytest>=8.0",
    "ruff>=0.8",
]
```

- `tomllib` is stdlib in Python 3.11+ (no extra TOML dep needed)
- Pure `@dataclass` with hand-written `from_dict()` classmethods (no pydantic)
- Managed via `uv` (already used in the repo for Python scripts)

---

## 4. Wire Protocol Specification

This is the authoritative reference, derived from `clients/lemon-tui/src/types.ts` and `scripts/debug_agent_rpc.exs`.

### 4.1 Transport Framing

**JSON-line RPC (local mode):**
- One JSON object per line, terminated with `\n`
- Client writes to subprocess stdin, reads from subprocess stdout
- Launch: `elixir scripts/debug_agent_rpc.exs --cwd <cwd> --model <provider:model> [--debug] [--no-ui]`
- Restart on exit code 75

**WebSocket (control plane mode):**
- Binary/text frames containing JSON
- OpenClaw protocol with frame types: `hello-ok`, `req`, `res`, `event`
- Connect to `ws://localhost:4040/ws` (or `--ws-url` override)
- Reconnect with exponential backoff: 500ms base, 10s max

### 4.2 Server Messages

All server messages have a `type` field for dispatch.

#### ReadyMessage
```json
{
  "type": "ready",
  "cwd": "/working/directory",
  "model": {"provider": "anthropic", "id": "claude-sonnet-4-20250514"},
  "debug": false,
  "ui": true,
  "primary_session_id": null,
  "active_session_id": null
}
```

#### EventMessage
```json
{
  "type": "event",
  "session_id": "uuid",
  "event_seq": 0,
  "event": {
    "type": "agent_start|agent_end|turn_start|turn_end|message_start|message_update|message_end|tool_execution_start|tool_execution_update|tool_execution_end|error",
    "data": []
  }
}
```

**Event data shapes by type:**

| Event Type | `data` Array Contents |
|---|---|
| `agent_start` | (empty) |
| `agent_end` | `[messages: Message[]]` |
| `turn_start` | (empty) |
| `turn_end` | `[message: Message, tool_results: ToolResult[]]` |
| `message_start` | `[message: Message]` |
| `message_update` | `[message: Message, deltas: AssistantEvent[]]` |
| `message_end` | `[message: Message]` |
| `tool_execution_start` | `[id: string, name: string, args: object]` |
| `tool_execution_update` | `[id: string, name: string, args: object, partial_result: object]` |
| `tool_execution_end` | `[id: string, name: string, result: object, is_error: boolean]` |
| `error` | `[reason: string, partial_state: object]` |

#### SessionStartedMessage
```json
{
  "type": "session_started",
  "session_id": "uuid",
  "cwd": "/path",
  "model": {"provider": "anthropic", "id": "claude-sonnet-4-20250514"}
}
```

#### SessionClosedMessage
```json
{
  "type": "session_closed",
  "session_id": "uuid",
  "reason": "normal|not_found|error"
}
```

#### ActiveSessionMessage
```json
{"type": "active_session", "session_id": "uuid-or-null"}
```

#### StatsMessage
```json
{
  "type": "stats",
  "session_id": "uuid",
  "stats": {
    "session_id": "uuid",
    "message_count": 0,
    "turn_count": 0,
    "is_streaming": false,
    "cwd": "/path",
    "model": {"provider": "...", "id": "..."},
    "thinking_level": null
  }
}
```

#### SessionsListMessage
```json
{
  "type": "sessions_list",
  "sessions": [{"path": "...", "id": "...", "timestamp": 1234567890, "cwd": "...", "model": {...}}],
  "error": null
}
```

#### RunningSessionsMessage
```json
{
  "type": "running_sessions",
  "sessions": [{"session_id": "...", "cwd": "...", "is_streaming": false, "model": {...}}],
  "error": null
}
```

#### ModelsListMessage
```json
{
  "type": "models_list",
  "providers": [{"id": "anthropic", "models": [{"id": "claude-sonnet-4-20250514", "name": "Claude Sonnet"}]}],
  "error": null
}
```

#### UIRequestMessage
```json
{
  "type": "ui_request",
  "id": "unique-request-id",
  "method": "select|confirm|input|editor",
  "params": {}
}
```

**UI request params by method:**

| Method | Params |
|---|---|
| `select` | `{"title": "...", "options": [{"label": "...", "value": "...", "description": null}], "opts": {}}` |
| `confirm` | `{"title": "...", "message": "...", "opts": {}}` |
| `input` | `{"title": "...", "placeholder": null, "opts": {}}` |
| `editor` | `{"title": "...", "prefill": null, "opts": {}}` |

#### UISignalMessage
```json
{"type": "ui_notify|ui_status|ui_widget|ui_working|ui_set_title|ui_set_editor_text", "params": {...}}
```

#### Other Messages
```json
{"type": "save_result", "ok": true, "path": "...", "error": null}
{"type": "pong"}
{"type": "debug", "message": "...", "argv": []}
{"type": "error", "message": "...", "session_id": null}
```

### 4.3 Client Commands

All commands are JSON objects sent as single lines.

| Command | Fields |
|---|---|
| `prompt` | `type`, `text: string`, `session_id?: string` |
| `abort` | `type`, `session_id?: string` |
| `reset` | `type`, `session_id?: string` |
| `save` | `type`, `session_id?: string` |
| `stats` | `type`, `session_id?: string` |
| `start_session` | `type`, `cwd?`, `model?` ("provider:model"), `system_prompt?`, `session_file?`, `parent_session?` |
| `close_session` | `type`, `session_id: string` |
| `set_active_session` | `type`, `session_id: string` |
| `list_sessions` | `type` |
| `list_running_sessions` | `type` |
| `list_models` | `type` |
| `ui_response` | `type`, `id: string`, `result: any`, `error: string\|null` |
| `ping` | `type` |
| `quit` | `type` |
| `get_config` | `type` |
| `set_config` | `type`, `key: string`, `value: any` |

Commands with `session_id: null` or omitted target the `active_session_id`. Error if no active session.

Plain text sent to stdin (not valid JSON) is treated as a prompt to the active session.

### 4.4 Message Content Structures

Messages from the server carry Elixir struct markers via `__struct__` fields.

#### UserMessage
```json
{
  "__struct__": "Elixir.Ai.Types.UserMessage",
  "role": "user",
  "content": "text string or array of ContentBlocks",
  "timestamp": 1234567890
}
```

#### AssistantMessage
```json
{
  "__struct__": "Elixir.Ai.Types.AssistantMessage",
  "role": "assistant",
  "content": [ContentBlock, ...],
  "provider": "anthropic",
  "model": "claude-sonnet-4-20250514",
  "api": "anthropic",
  "usage": {
    "input": 100,
    "output": 50,
    "cache_read": 0,
    "cache_write": 0,
    "total_tokens": 150,
    "cost": {
      "input": 0.001,
      "output": 0.002,
      "cache_read": 0.0,
      "cache_write": 0.0,
      "total": 0.003
    }
  },
  "stop_reason": "stop|length|tool_use|error|aborted|null",
  "error_message": null,
  "timestamp": 1234567890
}
```

#### ToolResultMessage
```json
{
  "__struct__": "Elixir.Ai.Types.ToolResultMessage",
  "role": "tool_result",
  "tool_call_id": "id",
  "tool_name": "name",
  "content": [ContentBlock, ...],
  "details": {},
  "trust": "trusted|untrusted",
  "trust_metadata": {"trusted": true},
  "is_error": false,
  "timestamp": 1234567890
}
```

#### ContentBlock Types

**TextContent:**
```json
{"__struct__": "Elixir.Ai.Types.TextContent", "type": "text", "text": "...", "text_signature": null}
```

**ThinkingContent:**
```json
{"__struct__": "Elixir.Ai.Types.ThinkingContent", "type": "thinking", "thinking": "...", "thinking_signature": null}
```

**ToolCall:**
```json
{"__struct__": "Elixir.Ai.Types.ToolCall", "type": "tool_call", "id": "...", "name": "...", "arguments": {}}
```

**ImageContent:**
```json
{"__struct__": "Elixir.Ai.Types.ImageContent", "type": "image", "data": "base64...", "mime_type": "image/png"}
```

### 4.5 OpenClaw WebSocket Framing

For control plane connections, messages are wrapped in OpenClaw frames:

**Client sends:**
```json
{"type": "req", "id": "uuid", "method": "sessions.start", "params": {"cwd": "/path", "model": "anthropic:claude-sonnet"}}
```

**Server responds:**
```json
{"type": "res", "id": "uuid", "ok": true, "payload": {"sessionKey": "abc123", "model": {...}}}
```

**Server streams events:**
```json
{"type": "event", "event": "agent.message_start", "payload": {"sessionKey": "abc123", ...}, "seq": 1}
```

**Hello handshake:**
```json
{"type": "hello-ok", "protocol": 1, "server": {}, "features": {}, "snapshot": {}, "policy": {}, "auth": null}
```

**Method mapping (OpenClaw -> JSON-line equivalent):**

| OpenClaw Method | JSON-line Equivalent | Response Type |
|---|---|---|
| `sessions.start` | `start_session` | `session_started` |
| `sessions.list` | `list_sessions` | `sessions_list` |
| `sessions.close` | `close_session` | `session_closed` |
| `sessions.running` | `list_running_sessions` | `running_sessions` |
| `session.set_active` | `set_active_session` | `active_session` |
| `chat.prompt` | `prompt` | streaming events |
| `chat.abort` | `abort` | (none) |
| `chat.reset` | `reset` | (none) |
| `chat.stats` | `stats` | `stats` |
| `chat.save` | `save` | `save_result` |
| `models.list` | `list_models` | `models_list` |

The WebSocket connection normalizes all OpenClaw frames into the same `ServerMessage` types that JSON-line RPC produces, so the rest of the app doesn't care which transport is active.

---

## 5. Module Specifications

### 5.1 types.py (~350 lines)

All wire protocol types as `@dataclass` with `@classmethod from_dict(cls, data: dict)` factories.

```python
@dataclass
class ModelInfo:
    provider: str
    id: str

@dataclass
class ReadyMessage:
    type: str  # "ready"
    cwd: str
    model: ModelInfo
    debug: bool
    ui: bool
    primary_session_id: str | None
    active_session_id: str | None

@dataclass
class SessionEvent:
    type: str  # "agent_start", "message_update", etc.
    data: list[Any] | None = None

@dataclass
class EventMessage:
    type: str  # "event"
    session_id: str
    event_seq: int
    event: SessionEvent

# ... all other server messages, client commands, content blocks
```

**Content block hierarchy:**
- `TextContent(type, text, text_signature)`
- `ThinkingContent(type, thinking, thinking_signature)`
- `ToolCall(type, id, name, arguments)`
- `ImageContent(type, data, mime_type)`
- `ContentBlock = TextContent | ThinkingContent | ToolCall | ImageContent`

**Message types:**
- `UserMessage(role, content, timestamp)` -- content is `str | list[ContentBlock]`
- `AssistantMessage(role, content, provider, model, api, usage, stop_reason, error_message, timestamp)` -- content is `list[ContentBlock]`
- `ToolResultMessage(role, tool_call_id, tool_name, content, details, trust, trust_metadata, is_error, timestamp)`

**Usage structure:**
```python
@dataclass
class UsageCost:
    input: float = 0.0
    output: float = 0.0
    cache_read: float = 0.0
    cache_write: float = 0.0
    total: float = 0.0

@dataclass
class Usage:
    input: int = 0
    output: int = 0
    cache_read: int = 0
    cache_write: int = 0
    total_tokens: int = 0
    cost: UsageCost | None = None
```

**UI request param types:**
```python
@dataclass
class SelectOption:
    label: str
    value: str
    description: str | None = None

@dataclass
class SelectParams:
    title: str
    options: list[SelectOption]
    opts: dict = field(default_factory=dict)

@dataclass
class ConfirmParams:
    title: str
    message: str
    opts: dict = field(default_factory=dict)

@dataclass
class InputParams:
    title: str
    placeholder: str | None = None
    opts: dict = field(default_factory=dict)

@dataclass
class EditorParams:
    title: str
    prefill: str | None = None
    opts: dict = field(default_factory=dict)
```

**Factory function:**
```python
def parse_server_message(data: dict) -> ServerMessage:
    """Dispatch on data['type'] to construct the right dataclass."""
    match data.get("type"):
        case "ready": return ReadyMessage.from_dict(data)
        case "event": return EventMessage.from_dict(data)
        case "stats": return StatsMessage.from_dict(data)
        case "session_started": return SessionStartedMessage.from_dict(data)
        case "session_closed": return SessionClosedMessage.from_dict(data)
        case "active_session": return ActiveSessionMessage.from_dict(data)
        case "ui_request": return UIRequestMessage.from_dict(data)
        case "sessions_list": return SessionsListMessage.from_dict(data)
        case "running_sessions": return RunningSessionsMessage.from_dict(data)
        case "models_list": return ModelsListMessage.from_dict(data)
        case "save_result": return SaveResultMessage.from_dict(data)
        case "error": return ErrorMessage.from_dict(data)
        case "pong": return PongMessage()
        case "debug": return DebugMessage.from_dict(data)
        case _: return UnknownMessage(type=data.get("type", "unknown"), raw=data)
```

### 5.2 config.py (~200 lines)

Port of `clients/lemon-tui/src/config.ts`.

```python
@dataclass
class ProviderConfig:
    api_key: str | None = None
    base_url: str | None = None

@dataclass
class AgentConfig:
    default_provider: str = "anthropic"
    default_model: str = "claude-sonnet-4-20250514"

@dataclass
class TUIConfig:
    theme: str = "lemon"
    debug: bool = False
    bell: bool = True
    compact: bool = False
    timestamps: bool = False

@dataclass
class ControlPlaneConfig:
    ws_url: str | None = None
    token: str | None = None
    role: str | None = None
    scopes: list[str] | None = None
    client_id: str | None = None

@dataclass
class LemonConfig:
    providers: dict[str, ProviderConfig] = field(default_factory=dict)
    agent: AgentConfig = field(default_factory=AgentConfig)
    tui: TUIConfig = field(default_factory=TUIConfig)
    control_plane: ControlPlaneConfig = field(default_factory=ControlPlaneConfig)

@dataclass
class ResolvedConfig:
    provider: str
    model: str
    api_key: str | None
    base_url: str | None
    cwd: str
    theme: str
    debug: bool
    system_prompt: str | None
    session_file: str | None
    lemon_path: str | None
    ws_url: str | None
    ws_token: str | None
    ws_role: str | None
    ws_scopes: list[str] | None
    ws_client_id: str | None
```

**Resolution precedence (matching config.ts exactly):**
```python
def resolve_config(cli_args: argparse.Namespace | None = None) -> ResolvedConfig:
    config = load_config(cwd)  # merges global + project configs

    provider = (cli_args.provider
                or os.environ.get("LEMON_DEFAULT_PROVIDER")
                or config.agent.default_provider
                or "anthropic")

    model = (cli_args.model
             or os.environ.get("LEMON_DEFAULT_MODEL")
             or config.agent.default_model
             or "claude-sonnet-4-20250514")

    # Provider-specific env prefix: anthropic -> ANTHROPIC_*, openai -> OPENAI_*
    env_prefix = _provider_env_prefix(provider)
    api_key = (os.environ.get(f"{env_prefix}_API_KEY")
               or config.providers.get(provider, {}).api_key)

    base_url = (cli_args.base_url
                or os.environ.get(f"{env_prefix}_BASE_URL")
                or config.providers.get(provider, {}).base_url)

    theme = (os.environ.get("LEMON_THEME")
             or config.tui.theme
             or "lemon")

    # ... etc for all fields
```

**Config file loading:**
```python
def load_config(cwd: str | None = None) -> LemonConfig:
    global_path = Path.home() / ".lemon" / "config.toml"
    project_path = Path(cwd or ".") / ".lemon" / "config.toml"

    global_config = _load_toml(global_path)
    project_config = _load_toml(project_path)
    merged = _deep_merge(global_config, project_config)
    return LemonConfig.from_dict(merged)

def _load_toml(path: Path) -> dict:
    if not path.exists():
        return {}
    import tomllib
    with open(path, "rb") as f:
        return tomllib.load(f)
```

**Model spec parsing:**
```python
def parse_model_spec(spec: str) -> tuple[str, str]:
    """Parse 'provider:model_id' -> (provider, model_id)."""
    if ":" in spec:
        provider, model_id = spec.split(":", 1)
        return provider, model_id
    return "anthropic", spec  # default provider
```

### 5.3 theme.py (~250 lines)

Port of `clients/lemon-tui/src/theme.ts` with exact ANSI 256 color values.

```python
@dataclass
class ThemeColors:
    name: str
    primary: int       # Main brand color
    secondary: int     # Supporting color
    accent: int        # Highlight/emphasis
    success: int       # Green success
    warning: int       # Orange warning
    error: int         # Red error
    muted: int         # Gray muted text
    dim: int           # Dimmer than muted (defaults to muted - 2)
    border: int        # Panel/box borders
    modeline_bg: int   # Status bar background
    overlay_bg: int    # Overlay background
```

**Exact theme definitions (from theme.ts):**

```python
THEMES: dict[str, ThemeColors] = {
    "lemon": ThemeColors(
        name="lemon",
        primary=220,      # yellow
        secondary=228,    # pale yellow
        accent=208,       # orange
        success=114,      # citrus green
        warning=214,      # orange
        error=203,        # red
        muted=243,        # gray
        dim=241,
        border=240,       # darker gray
        modeline_bg=58,   # dark olive
        overlay_bg=236,   # dark gray
    ),
    "lime": ThemeColors(
        name="lime",
        primary=118,      # bright green
        secondary=157,    # pale green
        accent=154,       # chartreuse
        success=114,      # citrus green
        warning=214,      # orange
        error=203,        # red
        muted=243,        # gray
        dim=241,
        border=240,       # darker gray
        modeline_bg=22,   # dark green
        overlay_bg=22,    # dark green
    ),
    "midnight": ThemeColors(
        name="midnight",
        primary=141,      # soft purple
        secondary=183,    # lavender
        accent=81,        # bright cyan
        success=114,      # green
        warning=221,      # gold
        error=204,        # pink-red
        muted=245,        # cool gray
        dim=243,
        border=60,        # muted purple
        modeline_bg=17,   # deep navy
        overlay_bg=17,    # deep navy
    ),
    "rose": ThemeColors(
        name="rose",
        primary=211,      # soft pink
        secondary=224,    # pale pink
        accent=205,       # hot pink
        success=150,      # soft green
        warning=222,      # warm gold
        error=196,        # bright red
        muted=244,        # warm gray
        dim=242,
        border=132,       # muted rose
        modeline_bg=52,   # dark rose
        overlay_bg=52,    # dark rose
    ),
    "ocean": ThemeColors(
        name="ocean",
        primary=38,       # deep teal
        secondary=116,    # pale aqua
        accent=51,        # bright cyan
        success=114,      # green
        warning=215,      # sandy orange
        error=203,        # coral red
        muted=245,        # blue-gray
        dim=243,
        border=30,        # muted teal
        modeline_bg=23,   # deep ocean
        overlay_bg=23,    # deep ocean
    ),
    "contrast": ThemeColors(
        name="contrast",
        primary=15,       # bright white
        secondary=14,     # bright cyan
        accent=11,        # bright yellow
        success=10,       # bright green
        warning=11,       # bright yellow
        error=9,          # bright red
        muted=250,        # light gray
        dim=248,
        border=248,       # light gray
        modeline_bg=234,  # very dark
        overlay_bg=234,   # very dark
    ),
}
```

**Lemon ASCII art (from theme.ts getLemonArt()):**
```python
LEMON_ART = """\
       {g}▄██▄{r}
      {g}▄████▄{r}
     {p}████████{r}
    {p}██{a} ◠   ◠ {p}██{r}
    {p}██{a}  ‿   {p}██{r}
     {p}████████{r}
      {p}▀████▀{r}
"""
# {g} = success color (green), {p} = primary color (yellow), {a} = accent (orange), {r} = reset
```

**Helpers:**
```python
_current_theme: ThemeColors = THEMES["lemon"]

def get_theme(name: str) -> ThemeColors | None:
    return THEMES.get(name)

def set_theme(name: str) -> bool:
    global _current_theme
    if name in THEMES:
        _current_theme = THEMES[name]
        return True
    return False

def get_current_theme() -> ThemeColors:
    return _current_theme

def get_available_themes() -> list[str]:
    return list(THEMES.keys())

def ansi256(color_num: int) -> str:
    """Return ANSI escape for 256-color."""
    return f"\033[38;5;{color_num}m"

def ansi256_bg(color_num: int) -> str:
    return f"\033[48;5;{color_num}m"

def rich_color(color_num: int) -> str:
    """Return Rich markup color string."""
    return f"color({color_num})"

def build_pt_style(theme: ThemeColors) -> dict[str, str]:
    """Build prompt_toolkit Style.from_dict() overrides."""
    return {
        "input-area": f"fg:ansi256({theme.primary})",
        "placeholder": f"fg:ansi256({theme.muted}) italic",
        "prompt": f"fg:ansi256({theme.primary})",
        "input-rule": f"fg:ansi256({theme.border})",
        "completion-menu": f"bg:#1a1a2e fg:ansi256({theme.muted})",
        "completion-menu.completion": f"bg:#1a1a2e fg:ansi256({theme.muted})",
        "completion-menu.completion.current": f"bg:#333355 fg:ansi256({theme.primary})",
        "completion-menu.meta.completion": f"bg:#1a1a2e fg:ansi256({theme.dim})",
        "completion-menu.meta.completion.current": f"bg:#333355 fg:ansi256({theme.accent})",
        "status-bar": f"bg:ansi256({theme.modeline_bg}) fg:ansi256({theme.muted})",
        "status-bar.model": f"fg:ansi256({theme.secondary})",
        "status-bar.busy": f"fg:ansi256({theme.primary})",
        "overlay": f"bg:ansi256({theme.overlay_bg})",
        "overlay.title": f"fg:ansi256({theme.primary}) bold",
        "overlay.border": f"fg:ansi256({theme.border})",
    }

def get_lemon_art(theme: ThemeColors | None = None) -> str:
    """Return themed lemon ASCII art."""
    t = theme or _current_theme
    return LEMON_ART.format(
        g=ansi256(t.success), p=ansi256(t.primary),
        a=ansi256(t.accent), r="\033[0m",
    )
```

### 5.4 constants.py (~80 lines)

```python
SLASH_COMMANDS: dict[str, str] = {
    # Session
    "/new": "Start a new session",
    "/reset": "Reset the current session",
    "/clear": "Clear display and reset session",
    "/history": "List saved sessions",
    "/save": "Save the current session",
    "/retry": "Re-send last user message",
    "/undo": "Remove last user/assistant exchange",
    "/rollback": "Rollback to a previous point",
    "/stop": "Abort the running agent",
    # Configuration
    "/model": "Show or switch model (usage: /model [provider:model])",
    "/config": "Show or edit configuration",
    "/skin": "Show or switch theme (usage: /skin [name])",
    "/compact": "Toggle compact display mode",
    "/thinking": "Toggle thinking/reasoning panel",
    # Info
    "/help": "Show available commands",
    "/usage": "Show token usage and cost",
    "/quit": "Exit (also: /exit, /q)",
    # Sessions
    "/sessions": "List saved sessions",
    "/running": "List running sessions",
    "/switch": "Switch active session (usage: /switch <id>)",
    "/close": "Close current or specified session",
    "/resume": "Resume a saved session (usage: /resume <id>)",
}

COMMAND_ALIASES: dict[str, str] = {
    "/exit": "/quit",
    "/q": "/quit",
    "/abort": "/stop",
}

SPINNER_FRAMES = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏']

TOOL_EMOJIS: dict[str, str] = {
    "bash": "💻", "terminal": "💻",
    "read": "📖", "read_file": "📖",
    "write": "✍️", "write_file": "✍️",
    "edit": "📝", "edit_file": "📝",
    "grep": "🔍", "search": "🔍",
    "glob": "📂", "find": "📂", "ls": "📂",
    "web_search": "🌐", "websearch": "🌐",
    "web_fetch": "📄", "webfetch": "📄",
    "task": "📋", "todo": "📋",
    "process": "⚙️",
}

TOOL_VERBS: dict[str, str] = {
    "bash": "ran", "terminal": "ran",
    "read": "read", "read_file": "read",
    "write": "wrote", "write_file": "wrote",
    "edit": "edited", "edit_file": "edited",
    "grep": "searched", "search": "searched",
    "glob": "found", "find": "found", "ls": "listed",
    "web_search": "searched", "websearch": "searched",
    "web_fetch": "fetched", "webfetch": "fetched",
    "task": "tasked", "todo": "planned",
    "process": "processed",
}
```

### 5.5 connection/base.py (~80 lines)

```python
from abc import ABC, abstractmethod
from typing import Any, Callable
from lemon_cli.types import ServerMessage

class AgentConnection(ABC):
    """Abstract interface for connecting to the Lemon agent backend."""

    def __init__(self):
        self.on_ready: Callable | None = None
        self.on_message: Callable[[ServerMessage], None] | None = None
        self.on_error: Callable[[str], None] | None = None
        self.on_close: Callable[[], None] | None = None

    @abstractmethod
    async def start(self) -> None: ...

    @abstractmethod
    async def stop(self) -> None: ...

    @abstractmethod
    def send_command(self, cmd: dict) -> None: ...

    def prompt(self, text: str, session_id: str | None = None) -> None:
        self.send_command({"type": "prompt", "text": text, "session_id": session_id})

    def abort(self, session_id: str | None = None) -> None:
        self.send_command({"type": "abort", "session_id": session_id})

    def reset(self, session_id: str | None = None) -> None:
        self.send_command({"type": "reset", "session_id": session_id})

    def save(self, session_id: str | None = None) -> None:
        self.send_command({"type": "save", "session_id": session_id})

    def start_session(self, **opts) -> None:
        self.send_command({"type": "start_session", **opts})

    def close_session(self, session_id: str) -> None:
        self.send_command({"type": "close_session", "session_id": session_id})

    def set_active_session(self, session_id: str) -> None:
        self.send_command({"type": "set_active_session", "session_id": session_id})

    def list_sessions(self) -> None:
        self.send_command({"type": "list_sessions"})

    def list_running_sessions(self) -> None:
        self.send_command({"type": "list_running_sessions"})

    def list_models(self) -> None:
        self.send_command({"type": "list_models"})

    def respond_to_ui_request(self, id: str, result: Any, error: str | None = None) -> None:
        self.send_command({"type": "ui_response", "id": id, "result": result, "error": error})

    def ping(self) -> None:
        self.send_command({"type": "ping"})

    def quit(self) -> None:
        self.send_command({"type": "quit"})

    def _emit(self, event: str, data: Any = None):
        cb = getattr(self, f"on_{event}", None)
        if cb:
            cb(data) if data is not None else cb()
```

### 5.6 connection/rpc.py (~300 lines)

```python
import asyncio
import json
import os
import subprocess
from pathlib import Path
from lemon_cli.connection.base import AgentConnection
from lemon_cli.connection.protocol import parse_server_message

RESTART_EXIT_CODE = 75

class RPCConnection(AgentConnection):
    """JSON-line RPC connection via subprocess."""

    def __init__(self, cwd: str, model: str, lemon_path: str | None = None,
                 system_prompt: str | None = None, session_file: str | None = None,
                 debug: bool = False, ui: bool = True):
        super().__init__()
        self._cwd = cwd
        self._model = model
        self._lemon_path = lemon_path or self._discover_lemon_path()
        self._system_prompt = system_prompt
        self._session_file = session_file
        self._debug = debug
        self._ui = ui
        self._process: asyncio.subprocess.Process | None = None
        self._running = False
        self._loop: asyncio.AbstractEventLoop | None = None

    def _discover_lemon_path(self) -> str:
        """Walk up from CWD looking for lemon mix.exs, or check LEMON_PATH env."""
        env_path = os.environ.get("LEMON_PATH")
        if env_path and Path(env_path).exists():
            return env_path

        current = Path(self._cwd).resolve()
        while current != current.parent:
            mix = current / "mix.exs"
            if mix.exists():
                content = mix.read_text(errors="ignore")
                if "lemon" in content.lower():
                    return str(current)
            current = current.parent

        raise RuntimeError("Cannot find lemon project root. Set LEMON_PATH or use --lemon-path.")

    def _build_command(self) -> list[str]:
        """Build the elixir subprocess command."""
        cmd = ["elixir", "scripts/debug_agent_rpc.exs",
               "--cwd", self._cwd, "--model", self._model]
        if self._debug:
            cmd.append("--debug")
        if not self._ui:
            cmd.append("--no-ui")
        if self._system_prompt:
            cmd.extend(["--system-prompt", self._system_prompt])
        if self._session_file:
            cmd.extend(["--session-file", self._session_file])
        return cmd

    async def start(self) -> None:
        self._running = True
        await self._spawn_process()

    async def _spawn_process(self) -> None:
        cmd = self._build_command()
        self._process = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=self._lemon_path,
        )
        asyncio.create_task(self._read_stdout())
        asyncio.create_task(self._read_stderr())
        asyncio.create_task(self._watch_exit())

    async def _read_stdout(self) -> None:
        """Read JSON lines from stdout."""
        while self._running and self._process and self._process.stdout:
            try:
                line = await self._process.stdout.readline()
                if not line:
                    break
                text = line.decode("utf-8", errors="replace").strip()
                if not text:
                    continue
                try:
                    data = json.loads(text)
                    msg = parse_server_message(data)
                    if msg.type == "ready":
                        self._emit("ready", msg)
                    else:
                        self._emit("message", msg)
                except json.JSONDecodeError:
                    pass  # ignore non-JSON lines (e.g. Elixir Logger output)
            except Exception as e:
                self._emit("error", str(e))
                break

    async def _read_stderr(self) -> None:
        """Read stderr for debug output."""
        while self._running and self._process and self._process.stderr:
            line = await self._process.stderr.readline()
            if not line:
                break
            # Optionally pipe to debug output

    async def _watch_exit(self) -> None:
        """Watch for process exit and optionally restart."""
        if not self._process:
            return
        exit_code = await self._process.wait()
        if exit_code == RESTART_EXIT_CODE and self._running:
            await self._spawn_process()  # Auto-restart
        elif self._running:
            self._emit("close")

    def send_command(self, cmd: dict) -> None:
        if self._process and self._process.stdin:
            line = json.dumps(cmd) + "\n"
            self._process.stdin.write(line.encode("utf-8"))
            # Note: drain is async, but we fire-and-forget here
            if self._loop:
                asyncio.run_coroutine_threadsafe(
                    self._process.stdin.drain(), self._loop
                )

    async def stop(self) -> None:
        self._running = False
        if self._process:
            self.send_command({"type": "quit"})
            try:
                await asyncio.wait_for(self._process.wait(), timeout=5.0)
            except asyncio.TimeoutError:
                self._process.kill()
```

### 5.7 connection/websocket.py (~300 lines)

```python
import asyncio
import json
import uuid
from dataclasses import dataclass, field
from typing import Any
import websockets
from lemon_cli.connection.base import AgentConnection
from lemon_cli.connection.protocol import parse_server_message

WS_RECONNECT_BASE_DELAY = 0.5
WS_RECONNECT_MAX_DELAY = 10.0
WS_COMMAND_QUEUE_LIMIT = 200

@dataclass
class PendingRequest:
    method: str
    session_id: str | None = None
    meta: dict = field(default_factory=dict)

class WebSocketConnection(AgentConnection):
    """WebSocket connection using OpenClaw protocol."""

    def __init__(self, ws_url: str, token: str | None = None,
                 role: str | None = None, scopes: list[str] | None = None,
                 client_id: str | None = None, session_key: str | None = None):
        super().__init__()
        self._ws_url = ws_url
        self._token = token
        self._role = role
        self._scopes = scopes
        self._client_id = client_id
        self._session_key = session_key
        self._ws: websockets.WebSocketClientProtocol | None = None
        self._pending: dict[str, PendingRequest] = {}
        self._reconnect_delay = WS_RECONNECT_BASE_DELAY
        self._running = False

    async def start(self) -> None:
        self._running = True
        await self._connect()

    async def _connect(self) -> None:
        headers = {}
        if self._token:
            headers["Authorization"] = f"Bearer {self._token}"
        # Add role, scopes, client_id as query params or headers
        try:
            self._ws = await websockets.connect(self._ws_url, extra_headers=headers)
            self._reconnect_delay = WS_RECONNECT_BASE_DELAY
            asyncio.create_task(self._read_loop())
        except Exception as e:
            self._emit("error", f"WebSocket connect failed: {e}")
            if self._running:
                await self._reconnect()

    async def _reconnect(self) -> None:
        await asyncio.sleep(self._reconnect_delay)
        self._reconnect_delay = min(self._reconnect_delay * 2, WS_RECONNECT_MAX_DELAY)
        if self._running:
            await self._connect()

    async def _read_loop(self) -> None:
        try:
            async for raw in self._ws:
                frame = json.loads(raw)
                match frame.get("type"):
                    case "hello-ok":
                        self._handle_hello_ok(frame)
                    case "res":
                        self._handle_response(frame)
                    case "event":
                        self._handle_event(frame)
        except websockets.ConnectionClosed:
            if self._running:
                await self._reconnect()

    def _handle_hello_ok(self, frame: dict) -> None:
        """Handle initial handshake."""
        # Extract server capabilities, policy, etc.
        pass

    def _handle_response(self, frame: dict) -> None:
        """Handle req/res response. Map to normalized ServerMessage."""
        req_id = frame.get("id")
        pending = self._pending.pop(req_id, None)
        if not pending:
            return

        if not frame.get("ok"):
            error = frame.get("error", {})
            self._emit("message", ErrorMessage(
                type="error", message=error.get("message", "Unknown error")))
            return

        payload = frame.get("payload", {})
        # Map OpenClaw response to normalized message based on pending.method
        normalized = self._map_response(pending.method, payload)
        for msg in normalized:
            if msg.type == "ready":
                self._emit("ready", msg)
            else:
                self._emit("message", msg)

    def _handle_event(self, frame: dict) -> None:
        """Handle streamed event. Map to EventMessage."""
        event_name = frame.get("event", "")
        payload = frame.get("payload", {})
        seq = frame.get("seq", 0)

        session_key = payload.get("sessionKey") or payload.get("session_key")
        # Map OpenClaw event to SessionEvent
        session_event = self._map_event(event_name, payload)
        if session_event and session_key:
            msg = EventMessage(
                type="event", session_id=session_key,
                event_seq=seq, event=session_event)
            self._emit("message", msg)

    def _send_request(self, method: str, params: dict,
                      session_id: str | None = None) -> str:
        """Send OpenClaw req frame."""
        req_id = str(uuid.uuid4())
        if len(self._pending) >= WS_COMMAND_QUEUE_LIMIT:
            self._emit("error", "Command queue full")
            return req_id
        self._pending[req_id] = PendingRequest(method=method, session_id=session_id)
        frame = {"type": "req", "id": req_id, "method": method, "params": params}
        if self._ws:
            asyncio.create_task(self._ws.send(json.dumps(frame)))
        return req_id

    def send_command(self, cmd: dict) -> None:
        """Translate normalized command to OpenClaw req."""
        match cmd.get("type"):
            case "prompt":
                self._send_request("chat.prompt", {
                    "text": cmd["text"],
                    "sessionKey": cmd.get("session_id"),
                })
            case "start_session":
                self._send_request("sessions.start", {
                    "cwd": cmd.get("cwd"),
                    "model": cmd.get("model"),
                    "systemPrompt": cmd.get("system_prompt"),
                })
            case "abort":
                self._send_request("chat.abort", {
                    "sessionKey": cmd.get("session_id"),
                })
            case "list_sessions":
                self._send_request("sessions.list", {})
            case "list_models":
                self._send_request("models.list", {})
            # ... etc for all command types

    async def stop(self) -> None:
        self._running = False
        if self._ws:
            await self._ws.close()
```

### 5.8 state/store.py (~400 lines)

Port of `clients/lemon-tui/src/state.ts`.

```python
from dataclasses import dataclass, field
from collections import deque
from typing import Any, Callable
from lemon_cli.state.usage import CumulativeUsage
from lemon_cli.types import ModelInfo

@dataclass
class ToolExecution:
    id: str
    name: str
    args: dict
    partial_result: Any = None
    result: Any = None
    is_error: bool = False
    start_time: float = 0.0
    end_time: float | None = None
    # Task-specific
    task_engine: str | None = None
    task_current_action: dict | None = None  # {title, kind, phase}

@dataclass
class NormalizedUserMessage:
    id: str
    type: str = "user"
    content: str = ""
    timestamp: float = 0.0

@dataclass
class NormalizedAssistantMessage:
    id: str
    type: str = "assistant"
    text_content: str = ""
    thinking_content: str = ""
    tool_calls: list[dict] = field(default_factory=list)  # [{id, name, arguments}]
    provider: str = ""
    model: str = ""
    usage: dict | None = None  # {input_tokens, output_tokens, ...}
    stop_reason: str | None = None
    error: str | None = None
    timestamp: float = 0.0
    is_streaming: bool = False

@dataclass
class NormalizedToolResultMessage:
    id: str
    type: str = "tool_result"
    tool_call_id: str = ""
    tool_name: str = ""
    content: str = ""
    images: list[dict] = field(default_factory=list)  # [{data, mime_type}]
    trust: str = "trusted"
    is_trusted: bool = True
    is_error: bool = False
    timestamp: float = 0.0

NormalizedMessage = NormalizedUserMessage | NormalizedAssistantMessage | NormalizedToolResultMessage

@dataclass
class SessionState:
    session_id: str
    cwd: str = ""
    model: ModelInfo | None = None
    messages: list[NormalizedMessage] = field(default_factory=list)
    streaming_message: NormalizedAssistantMessage | None = None
    tool_executions: dict[str, ToolExecution] = field(default_factory=dict)
    busy: bool = False
    stats: dict | None = None
    cumulative_usage: CumulativeUsage = field(default_factory=CumulativeUsage)
    tool_working_message: str | None = None
    agent_working_message: str | None = None
    is_streaming: bool = False

@dataclass
class AppState:
    ready: bool = False
    cwd: str = ""
    model: ModelInfo | None = None
    debug: bool = False
    ui: bool = True

    # Multi-session
    primary_session_id: str | None = None
    active_session_id: str | None = None
    sessions: dict[str, SessionState] = field(default_factory=dict)
    running_sessions: list[dict] = field(default_factory=list)

    # UI state
    pending_ui_requests: deque = field(default_factory=deque)
    error: str | None = None
    expanded_thinking_ids: set[str] = field(default_factory=set)
    agent_start_time: float | None = None
    compact_mode: bool = False
    bell_enabled: bool = True
    show_timestamps: bool = False
    notification_history: list[dict] = field(default_factory=list)
    title: str | None = None
    status: dict[str, str | None] = field(default_factory=dict)

    # Convenience accessors (mirror active session)
    messages: list[NormalizedMessage] = field(default_factory=list)
    streaming_message: NormalizedAssistantMessage | None = None
    tool_executions: dict[str, ToolExecution] = field(default_factory=dict)
    busy: bool = False
    stats: dict | None = None
    cumulative_usage: CumulativeUsage = field(default_factory=CumulativeUsage)
    tool_working_message: str | None = None
    agent_working_message: str | None = None


class StateStore:
    def __init__(self, cwd: str = ""):
        self._state = AppState(cwd=cwd)
        self._listeners: list[Callable[[AppState], None]] = []
        self._message_id_counter = 0

    @property
    def state(self) -> AppState:
        return self._state

    def subscribe(self, listener: Callable[[AppState], None]) -> Callable:
        """Subscribe to state changes. Returns unsubscribe function."""
        self._listeners.append(listener)
        def unsub():
            self._listeners.remove(listener)
        return unsub

    def _notify(self):
        for listener in self._listeners:
            listener(self._state)

    def _next_message_id(self) -> str:
        self._message_id_counter += 1
        return f"msg_{self._message_id_counter}"

    def _get_active_session(self) -> SessionState | None:
        sid = self._state.active_session_id
        return self._state.sessions.get(sid) if sid else None

    def _sync_from_active_session(self):
        """Copy active session fields to top-level AppState for convenience."""
        session = self._get_active_session()
        if session:
            self._state.messages = session.messages
            self._state.streaming_message = session.streaming_message
            self._state.tool_executions = session.tool_executions
            self._state.busy = session.busy
            self._state.stats = session.stats
            self._state.cumulative_usage = session.cumulative_usage
            self._state.tool_working_message = session.tool_working_message
            self._state.agent_working_message = session.agent_working_message
        self._notify()

    def set_ready(self, msg):
        """Handle ReadyMessage."""
        self._state.ready = True
        self._state.cwd = msg.cwd
        self._state.model = msg.model
        self._state.debug = msg.debug
        self._state.ui = msg.ui
        self._state.primary_session_id = msg.primary_session_id
        self._state.active_session_id = msg.active_session_id
        self._notify()

    def handle_session_started(self, session_id: str, cwd: str, model: ModelInfo):
        self._state.sessions[session_id] = SessionState(
            session_id=session_id, cwd=cwd, model=model)
        if not self._state.active_session_id:
            self._state.active_session_id = session_id
        self._sync_from_active_session()

    def handle_session_closed(self, session_id: str, reason: str):
        self._state.sessions.pop(session_id, None)
        if self._state.active_session_id == session_id:
            self._state.active_session_id = None
        self._sync_from_active_session()

    def set_active_session_id(self, session_id: str | None):
        self._state.active_session_id = session_id
        self._sync_from_active_session()

    def handle_event(self, event, session_id: str):
        """Route event to session. Delegates to state/events.py."""
        from lemon_cli.state.events import handle_session_event
        session = self._state.sessions.get(session_id)
        if not session:
            session = SessionState(session_id=session_id)
            self._state.sessions[session_id] = session
        handle_session_event(event, session, self)
        self._sync_from_active_session()

    def enqueue_ui_request(self, request: dict):
        self._state.pending_ui_requests.append(request)
        self._notify()

    def dequeue_ui_request(self) -> dict | None:
        if self._state.pending_ui_requests:
            return self._state.pending_ui_requests.popleft()
        return None

    def set_error(self, error: str | None):
        self._state.error = error
        self._notify()

    def toggle_thinking_expanded(self, msg_id: str):
        ids = self._state.expanded_thinking_ids
        if msg_id in ids:
            ids.discard(msg_id)
        else:
            ids.add(msg_id)
        self._notify()

    def toggle_compact_mode(self):
        self._state.compact_mode = not self._state.compact_mode
        self._notify()
```

### 5.9 state/events.py (~150 lines)

```python
import time
from lemon_cli.state.store import (
    SessionState, StateStore, NormalizedUserMessage,
    NormalizedAssistantMessage, NormalizedToolResultMessage, ToolExecution,
)
from lemon_cli.types import SessionEvent


def handle_session_event(event: SessionEvent, session: SessionState, store: StateStore):
    """Route event to handler."""
    match event.type:
        case "agent_start":
            session.busy = True
            session.is_streaming = True
            session.tool_executions.clear()
            store._state.agent_start_time = time.monotonic()

        case "agent_end":
            _finish_streaming(session)
            session.busy = False
            session.is_streaming = False
            session.tool_working_message = None
            session.agent_working_message = None
            store._state.agent_start_time = None

        case "turn_start":
            pass

        case "turn_end":
            pass

        case "message_start":
            msg_data = event.data[0] if event.data else None
            if not msg_data:
                return
            role = msg_data.get("role")
            if role == "user":
                normalized = _normalize_user_message(msg_data, store._next_message_id())
                session.messages.append(normalized)
            elif role == "assistant":
                session.streaming_message = _normalize_assistant_message(
                    msg_data, f"assistant_{msg_data.get('timestamp', 0)}", is_streaming=True)

        case "message_update":
            if session.streaming_message and event.data:
                msg_data = event.data[0]
                session.streaming_message = _normalize_assistant_message(
                    msg_data, session.streaming_message.id, is_streaming=True)

        case "message_end":
            if session.streaming_message and event.data:
                msg_data = event.data[0]
                final = _normalize_assistant_message(
                    msg_data, session.streaming_message.id, is_streaming=False)
                session.messages.append(final)
                session.streaming_message = None
                # Update cumulative usage
                if final.usage:
                    session.cumulative_usage.update_from_usage(final.usage)

        case "tool_execution_start":
            if event.data and len(event.data) >= 3:
                tool_id, name, args = event.data[0], event.data[1], event.data[2]
                session.tool_executions[tool_id] = ToolExecution(
                    id=tool_id, name=name, args=args or {}, start_time=time.monotonic())
                session.tool_working_message = f"Running {name}..."

        case "tool_execution_update":
            if event.data and len(event.data) >= 4:
                tool_id = event.data[0]
                partial = event.data[3]
                te = session.tool_executions.get(tool_id)
                if te:
                    te.partial_result = partial
                    # Extract task fields if present
                    if isinstance(partial, dict):
                        details = partial.get("details", {})
                        if details:
                            te.task_engine = details.get("engine")
                            action = details.get("current_action", {})
                            if action:
                                te.task_current_action = action

        case "tool_execution_end":
            if event.data and len(event.data) >= 4:
                tool_id, name = event.data[0], event.data[1]
                result, is_error = event.data[2], event.data[3]
                te = session.tool_executions.get(tool_id)
                if te:
                    te.result = result
                    te.is_error = is_error
                    te.end_time = time.monotonic()
                session.tool_working_message = None

        case "error":
            reason = event.data[0] if event.data else "Unknown error"
            store.set_error(reason)
            session.busy = False
            session.is_streaming = False


def _finish_streaming(session: SessionState):
    if session.streaming_message:
        session.streaming_message.is_streaming = False
        session.messages.append(session.streaming_message)
        session.streaming_message = None


def _normalize_user_message(data: dict, msg_id: str) -> NormalizedUserMessage:
    content = data.get("content", "")
    if isinstance(content, list):
        content = " ".join(
            block.get("text", "") for block in content
            if block.get("type") == "text"
        )
    return NormalizedUserMessage(id=msg_id, content=content, timestamp=data.get("timestamp", 0))


def _normalize_assistant_message(data: dict, msg_id: str,
                                  is_streaming: bool = False) -> NormalizedAssistantMessage:
    content_blocks = data.get("content", [])
    text_parts, thinking_parts, tool_calls = [], [], []

    for block in (content_blocks if isinstance(content_blocks, list) else []):
        btype = block.get("type")
        if btype == "text":
            text_parts.append(block.get("text", ""))
        elif btype == "thinking":
            thinking_parts.append(block.get("thinking", ""))
        elif btype == "tool_call":
            tool_calls.append({
                "id": block.get("id"),
                "name": block.get("name"),
                "arguments": block.get("arguments", {}),
            })

    usage_raw = data.get("usage")
    usage = None
    if usage_raw:
        cost_raw = usage_raw.get("cost", {})
        usage = {
            "input_tokens": usage_raw.get("input", 0),
            "output_tokens": usage_raw.get("output", 0),
            "cache_read_tokens": usage_raw.get("cache_read", 0),
            "cache_write_tokens": usage_raw.get("cache_write", 0),
            "total_tokens": usage_raw.get("total_tokens", 0),
            "total_cost": cost_raw.get("total", 0) if cost_raw else 0,
        }

    return NormalizedAssistantMessage(
        id=msg_id,
        text_content="\n".join(text_parts),
        thinking_content="\n".join(thinking_parts),
        tool_calls=tool_calls,
        provider=data.get("provider", ""),
        model=data.get("model", ""),
        usage=usage,
        stop_reason=data.get("stop_reason"),
        error=data.get("error_message"),
        timestamp=data.get("timestamp", 0),
        is_streaming=is_streaming,
    )
```

### 5.10 state/usage.py (~50 lines)

```python
from dataclasses import dataclass

@dataclass
class CumulativeUsage:
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    total_cost: float = 0.0

    def update_from_usage(self, usage: dict):
        self.input_tokens += usage.get("input_tokens", 0)
        self.output_tokens += usage.get("output_tokens", 0)
        self.cache_read_tokens += usage.get("cache_read_tokens", 0)
        self.cache_write_tokens += usage.get("cache_write_tokens", 0)
        self.total_cost += usage.get("total_cost", 0.0)

    @property
    def total_tokens(self) -> int:
        return self.input_tokens + self.output_tokens

    def format_summary(self) -> str:
        return (f"In: {_fmt_tokens(self.input_tokens)} | "
                f"Out: {_fmt_tokens(self.output_tokens)} | "
                f"Cost: ${self.total_cost:.4f}")


def _fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)
```

### 5.11 tui/app.py (~250 lines)

Three-thread architecture (from Hermes `cli.py`):

```python
import asyncio
import queue
import threading
import time
from prompt_toolkit import Application
from prompt_toolkit.patch_stdout import patch_stdout
from prompt_toolkit.styles import Style

class LemonApp:
    def __init__(self, connection, config, store):
        self._connection = connection
        self._config = config
        self._store = store
        self._pending_input: queue.Queue[str] = queue.Queue()
        self._interrupt_queue: queue.Queue[None] = queue.Queue()
        self._should_exit = False
        self._last_ctrl_c_time = 0.0
        self._app: Application | None = None
        self._spinner = None  # KawaiiSpinner instance
        self._command_registry = None  # CommandRegistry instance

        # Wire connection callbacks
        self._connection.on_ready = self._on_ready
        self._connection.on_message = self._on_message
        self._connection.on_error = self._on_error
        self._connection.on_close = self._on_close

    def run(self):
        """Main entry point. Starts connection, threads, and prompt_toolkit app."""
        # Build layout, keybindings, style
        from lemon_cli.tui.layout import build_layout
        from lemon_cli.tui.input_area import build_input_area, build_keybindings
        from lemon_cli.tui.banner import print_banner
        from lemon_cli.commands.registry import build_command_registry

        self._command_registry = build_command_registry(self)
        kb = build_keybindings(self)
        layout = build_layout(self._store, self._spinner)
        theme = get_current_theme()
        style = Style.from_dict(build_pt_style(theme))

        self._app = Application(
            layout=layout,
            key_bindings=kb,
            style=style,
            mouse_support=False,
            full_screen=False,
        )

        # Start connection in background thread with its own event loop
        conn_thread = threading.Thread(target=self._run_connection, daemon=True)
        conn_thread.start()

        # Start daemon threads
        threading.Thread(target=self._spinner_loop, daemon=True).start()
        threading.Thread(target=self._process_loop, daemon=True).start()

        # Print banner
        print_banner(self._store.state, theme)

        # Run prompt_toolkit event loop (blocks main thread)
        with patch_stdout():
            self._app.run()

    def _run_connection(self):
        """Run asyncio event loop for connection in background thread."""
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        self._connection._loop = loop
        loop.run_until_complete(self._connection.start())
        loop.run_forever()

    # -- Callbacks --

    def _on_ready(self, msg):
        self._store.set_ready(msg)
        self._invalidate()

    def _on_message(self, msg):
        match msg.type:
            case "event":
                self._store.handle_event(msg.event, msg.session_id)
            case "session_started":
                self._store.handle_session_started(msg.session_id, msg.cwd, msg.model)
            case "session_closed":
                self._store.handle_session_closed(msg.session_id, msg.reason)
            case "active_session":
                self._store.set_active_session_id(msg.session_id)
            case "ui_request":
                self._store.enqueue_ui_request(msg)
            case "stats":
                self._store.set_stats(msg.stats, msg.session_id)
            case "error":
                self._store.set_error(msg.message)
            # ... other message types
        self._invalidate()

    def _on_error(self, error_msg):
        self._store.set_error(error_msg)
        self._invalidate()

    def _on_close(self):
        self._should_exit = True
        if self._app and self._app.is_running:
            self._app.exit()

    # -- Thread loops --

    def _spinner_loop(self):
        """Thread 1: Animate spinner, refresh status bar."""
        while not self._should_exit:
            if self._store.state.busy:
                if self._spinner:
                    self._spinner.advance()
                self._invalidate()
                time.sleep(0.08)
            else:
                time.sleep(0.5)

    def _process_loop(self):
        """Thread 2: Dequeue input, dispatch commands or prompts."""
        while not self._should_exit:
            try:
                text = self._pending_input.get(timeout=0.1)
            except queue.Empty:
                # Check for pending UI requests
                self._process_ui_requests()
                continue

            if not text:
                continue

            if text.startswith("/"):
                self._dispatch_command(text)
            else:
                self._send_prompt(text)

    def _dispatch_command(self, text: str):
        """Route slash command to registry."""
        if self._command_registry:
            should_continue = self._command_registry.dispatch(text)
            if not should_continue:
                self._should_exit = True
                if self._app and self._app.is_running:
                    self._app.exit()

    def _send_prompt(self, text: str):
        """Send user prompt to agent."""
        session_id = self._store.state.active_session_id
        self._connection.prompt(text, session_id)

    def _process_ui_requests(self):
        """Handle pending UI requests (overlays)."""
        request = self._store.dequeue_ui_request()
        if not request:
            return
        # Dispatch to overlay handler based on request.method
        from lemon_cli.tui.overlays import handle_ui_request
        result = handle_ui_request(request, self._app)
        if result is not None:
            self._connection.respond_to_ui_request(
                request.id, result.get("result"), result.get("error"))

    def _handle_interrupt(self):
        """Ctrl+C priority chain."""
        state = self._store.state
        now = time.monotonic()

        # 1. If overlay active -> cancel
        if state.pending_ui_requests:
            self._store.dequeue_ui_request()  # discard
            return

        # 2. If agent busy -> abort
        if state.busy:
            self._connection.abort(state.active_session_id)
            return

        # 3. Double Ctrl+C within 1s -> quit
        if now - self._last_ctrl_c_time < 1.0:
            self._should_exit = True
            if self._app and self._app.is_running:
                self._app.exit()
            return

        self._last_ctrl_c_time = now

    def _invalidate(self):
        """Trigger prompt_toolkit UI refresh."""
        if self._app:
            self._app.invalidate()

    def submit_input(self, text: str):
        """Called from keybinding handler to enqueue user input."""
        self._pending_input.put(text)

    def interrupt(self):
        """Called from Ctrl+C keybinding."""
        self._interrupt_queue.put(None)
        self._handle_interrupt()

    def print(self, text: str):
        """Print text above the input area via Rich."""
        from lemon_cli.display.console import cprint
        cprint(text)
```

### 5.12 tui/layout.py (~200 lines)

```python
from prompt_toolkit.layout import (
    HSplit, Window, ConditionalContainer, FormattedTextControl,
    FloatContainer, Float,
)
from prompt_toolkit.layout.dimension import Dimension
from prompt_toolkit.widgets import TextArea
from prompt_toolkit.layout.menus import CompletionsMenu
from prompt_toolkit.filters import Condition

def build_layout(store, spinner):
    """Build the HSplit layout."""

    # Condition helpers
    is_busy = Condition(lambda: store.state.busy)
    has_overlay = Condition(lambda: bool(store.state.pending_ui_requests))

    return HSplit([
        # 1. Spacer (scrollback room)
        Window(height=Dimension(min=1, preferred=999)),

        # 2. Overlay container (conditional)
        ConditionalContainer(
            content=Window(
                FormattedTextControl(lambda: _render_overlay(store)),
                height=Dimension(min=3, max=15),
            ),
            filter=has_overlay,
        ),

        # 3. Spinner/thinking widget (conditional)
        ConditionalContainer(
            content=Window(
                FormattedTextControl(lambda: _render_spinner(spinner, store)),
                height=1,
            ),
            filter=is_busy,
        ),

        # 4. Status bar
        Window(
            FormattedTextControl(lambda: _render_status_bar(store)),
            height=1,
            style="class:status-bar",
        ),

        # 5. Input rule (separator)
        Window(height=1, char="─", style="class:input-rule"),

        # 6. TextArea input (built separately in input_area.py)
        # ... injected by app.py

        # 7. Input rule bottom
        Window(height=1, char="─", style="class:input-rule"),
    ])
```

### 5.13 tui/spinner.py (~120 lines)

```python
import threading
import time
from lemon_cli.constants import SPINNER_FRAMES, TOOL_EMOJIS, TOOL_VERBS

class Spinner:
    """Animated spinner for tool execution progress."""

    def __init__(self):
        self._frame_idx = 0
        self._message = ""
        self._tool_name = ""
        self._start_time = 0.0
        self._lock = threading.Lock()
        self._above_lines: list[str] = []

    def advance(self):
        with self._lock:
            self._frame_idx = (self._frame_idx + 1) % len(SPINNER_FRAMES)

    def set_tool(self, name: str, preview: str = ""):
        with self._lock:
            self._tool_name = name
            self._message = preview
            self._start_time = time.monotonic()

    def clear(self):
        with self._lock:
            self._tool_name = ""
            self._message = ""

    def print_above(self, text: str):
        """Queue a line to print above spinner (for tool completion messages)."""
        with self._lock:
            self._above_lines.append(text)

    def drain_above(self) -> list[str]:
        with self._lock:
            lines = self._above_lines[:]
            self._above_lines.clear()
            return lines

    def render(self) -> str:
        with self._lock:
            frame = SPINNER_FRAMES[self._frame_idx]
            elapsed = time.monotonic() - self._start_time if self._start_time else 0
            if self._tool_name:
                return f" {frame} {self._tool_name} {self._message} ({elapsed:.1f}s)"
            return f" {frame} Working... ({elapsed:.1f}s)"

    @staticmethod
    def format_tool_completion(name: str, args: dict, elapsed: float,
                                is_error: bool = False) -> str:
        """Format a tool completion line: | emoji verb detail duration"""
        emoji = TOOL_EMOJIS.get(name, "⚡")
        verb = TOOL_VERBS.get(name, "ran")
        detail = _build_tool_preview(name, args)
        duration = f"{elapsed:.1f}s"
        prefix = "│" if not is_error else "│"  # could color differently
        return f" {prefix} {emoji} {verb:9} {detail}  {duration}"


def _build_tool_preview(name: str, args: dict) -> str:
    """Context-aware one-liner from tool args."""
    if name in ("bash", "terminal"):
        return _truncate(args.get("command", ""), 60)
    if name in ("read", "read_file"):
        return _truncate(args.get("file_path", args.get("path", "")), 60)
    if name in ("write", "write_file"):
        return _truncate(args.get("file_path", args.get("path", "")), 60)
    if name in ("edit", "edit_file"):
        return _truncate(args.get("file_path", args.get("path", "")), 60)
    if name in ("grep", "search"):
        return _truncate(args.get("pattern", args.get("query", "")), 60)
    if name in ("glob", "find"):
        return _truncate(args.get("pattern", args.get("path", "")), 60)
    if name in ("web_search", "websearch"):
        return _truncate(args.get("query", ""), 60)
    if name in ("web_fetch", "webfetch"):
        return _truncate(args.get("url", ""), 60)
    # Generic: first string value
    for v in args.values():
        if isinstance(v, str) and v:
            return _truncate(v, 60)
    return ""


def _truncate(text: str, max_len: int) -> str:
    if len(text) <= max_len:
        return text
    return text[:max_len - 3] + "..."
```

### 5.14 tui/status_bar.py (~150 lines)

Port of `clients/lemon-tui/src/ink/components/StatusBar.tsx`.

```python
import time
from lemon_cli.state.store import AppState
from lemon_cli.theme import get_current_theme, ansi256

def render_status_bar(state: AppState, terminal_width: int = 80) -> str:
    """Render adaptive status bar string."""
    parts = []
    theme = get_current_theme()

    # Busy indicator
    if state.busy:
        parts.append(f"{ansi256(theme.primary)}●\033[0m")

    # Elapsed timer
    if state.busy and state.agent_start_time:
        elapsed = time.monotonic() - state.agent_start_time
        parts.append(f"{ansi256(theme.muted)}Working... {format_duration(elapsed)}\033[0m")
    elif state.tool_working_message:
        parts.append(f"{ansi256(theme.muted)}{state.tool_working_message}\033[0m")

    # Model name
    if state.model:
        model_short = state.model.id.split("/")[-1].split("-")[0:3]
        model_name = "-".join(model_short)
        parts.append(f"{ansi256(theme.secondary)}{model_name}\033[0m")

    # Session indicator (if multi-session)
    session_count = len(state.sessions)
    if session_count > 1 and state.active_session_id:
        sid_short = state.active_session_id[:6]
        parts.append(f"{ansi256(theme.muted)}{sid_short} ({session_count})\033[0m")

    # Compact mode flag
    if state.compact_mode:
        parts.append(f"{ansi256(theme.accent)}[compact]\033[0m")

    # Token usage (if wide enough)
    usage = state.cumulative_usage
    if usage.total_tokens > 0 and terminal_width >= 76:
        token_str = (f"{ansi256(theme.muted)}"
                     f"⬇{format_tokens(usage.input_tokens)} "
                     f"⬆{format_tokens(usage.output_tokens)}\033[0m")
        parts.append(token_str)
        if usage.total_cost > 0:
            parts.append(f"{ansi256(theme.muted)}${usage.total_cost:.2f}\033[0m")

    # Stats (turns, messages)
    if state.stats:
        turns = state.stats.get("turn_count", 0)
        msgs = state.stats.get("message_count", 0)
        parts.append(f"{ansi256(theme.muted)}turns:{turns} msgs:{msgs}\033[0m")

    return " │ ".join(parts)


def format_duration(seconds: float) -> str:
    if seconds < 1:
        return f"{int(seconds * 1000)}ms"
    if seconds < 60:
        return f"{seconds:.1f}s"
    mins = int(seconds // 60)
    secs = int(seconds % 60)
    return f"{mins}m {secs}s"


def format_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)
```

### 5.15 tui/overlays/ (~400 lines total)

**base.py -- Queue-based blocking pattern (from Hermes callbacks.py):**
```python
import queue
import time

class OverlayBase:
    """Base class for interactive overlays using queue-based blocking."""

    def __init__(self, timeout: float = 120.0):
        self._result_queue: queue.Queue = queue.Queue(maxsize=1)
        self._deadline = time.monotonic() + timeout
        self._cancelled = False

    def wait_for_result(self) -> dict:
        """Block until user responds or timeout. Returns {result, error}."""
        while True:
            try:
                return self._result_queue.get(timeout=1.0)
            except queue.Empty:
                if time.monotonic() > self._deadline:
                    return {"result": None, "error": "Overlay timed out"}
                if self._cancelled:
                    return {"result": None, "error": "Cancelled"}
                continue

    def submit(self, result: any):
        self._result_queue.put({"result": result, "error": None})

    def cancel(self):
        self._cancelled = True
```

**select.py:**
```python
class SelectOverlay(OverlayBase):
    """Numbered list selection for ui_request method=select."""

    def __init__(self, params: dict, timeout: float = 120.0):
        super().__init__(timeout)
        self.title = params.get("title", "Select an option")
        self.options = params.get("options", [])
        self.selected_index = 0

    def render(self) -> str:
        lines = [f"  {self.title}\n"]
        for i, opt in enumerate(self.options):
            marker = ">" if i == self.selected_index else " "
            label = opt.get("label", f"Option {i+1}")
            desc = opt.get("description", "")
            desc_str = f" - {desc}" if desc else ""
            lines.append(f"  {marker} [{i+1}] {label}{desc_str}")
        lines.append(f"\n  Enter number or use arrows, Enter to confirm")
        return "\n".join(lines)

    def move_up(self):
        self.selected_index = max(0, self.selected_index - 1)

    def move_down(self):
        self.selected_index = min(len(self.options) - 1, self.selected_index + 1)

    def confirm(self):
        if self.options:
            self.submit(self.options[self.selected_index].get("value"))
```

**confirm.py:**
```python
class ConfirmOverlay(OverlayBase):
    def __init__(self, params: dict, timeout: float = 60.0):
        super().__init__(timeout)
        self.title = params.get("title", "Confirm")
        self.message = params.get("message", "")

    def render(self) -> str:
        return f"  {self.title}\n  {self.message}\n  [Y/n] "

    def confirm(self, yes: bool = True):
        self.submit(yes)
```

**input_overlay.py:**
```python
class InputOverlay(OverlayBase):
    def __init__(self, params: dict, timeout: float = 120.0):
        super().__init__(timeout)
        self.title = params.get("title", "Enter value")
        self.placeholder = params.get("placeholder", "")
        self.value = ""

    def render(self) -> str:
        placeholder_str = f" ({self.placeholder})" if self.placeholder else ""
        return f"  {self.title}{placeholder_str}\n  > {self.value}_"

    def submit_value(self, text: str):
        self.submit(text)
```

**editor.py:**
```python
import os
import tempfile
import subprocess

class EditorOverlay(OverlayBase):
    def __init__(self, params: dict, timeout: float = 300.0):
        super().__init__(timeout)
        self.title = params.get("title", "Edit")
        self.prefill = params.get("prefill", "")

    def launch(self):
        """Launch $EDITOR with prefill content."""
        editor = os.environ.get("VISUAL") or os.environ.get("EDITOR") or "nano"
        with tempfile.NamedTemporaryFile(mode="w", suffix=".md", delete=False) as f:
            if self.prefill:
                f.write(self.prefill)
            f.flush()
            tmp_path = f.name

        try:
            subprocess.run([editor, tmp_path], check=True)
            with open(tmp_path) as f:
                result = f.read()
            self.submit(result)
        except Exception as e:
            self.submit(None)  # Error case
        finally:
            os.unlink(tmp_path)
```

### 5.16 display/console.py (~100 lines)

```python
from io import StringIO
from rich.console import Console
from rich.theme import Theme as RichTheme
from prompt_toolkit.formatted_text import ANSI
from prompt_toolkit import print_formatted_text
from lemon_cli.theme import get_current_theme, rich_color

def get_rich_console(width: int | None = None) -> Console:
    """Create a Rich Console configured for the current theme."""
    theme = get_current_theme()
    rich_theme = RichTheme({
        "info": f"{rich_color(theme.primary)}",
        "success": f"{rich_color(theme.success)}",
        "warning": f"{rich_color(theme.warning)}",
        "error": f"{rich_color(theme.error)} bold",
        "muted": f"{rich_color(theme.muted)}",
        "accent": f"{rich_color(theme.accent)}",
    })
    return Console(theme=rich_theme, width=width, force_terminal=True)

def render_to_ansi(renderable) -> str:
    """Render a Rich object to an ANSI string."""
    sio = StringIO()
    console = Console(file=sio, force_terminal=True, no_color=False)
    console.print(renderable, highlight=False)
    return sio.getvalue()

def cprint(text: str):
    """Print text (Rich markup or ANSI) through prompt_toolkit's renderer."""
    print_formatted_text(ANSI(text))

def cprint_rich(renderable):
    """Print a Rich renderable through prompt_toolkit."""
    ansi_str = render_to_ansi(renderable)
    print_formatted_text(ANSI(ansi_str))
```

### 5.17 display/panels.py (~200 lines)

```python
from rich.panel import Panel
from rich.markdown import Markdown
from rich.text import Text
from lemon_cli.theme import get_current_theme, rich_color
from lemon_cli.display.console import render_to_ansi, cprint

def render_user_message(msg) -> str:
    """Render user message as Rich Panel ANSI string."""
    theme = get_current_theme()
    panel = Panel(
        Text(msg.content),
        title="You",
        title_align="left",
        border_style=f"{rich_color(theme.muted)}",
        padding=(0, 1),
    )
    return render_to_ansi(panel)

def render_assistant_message(msg, compact: bool = False) -> str:
    """Render assistant message as Rich Panel with markdown."""
    theme = get_current_theme()

    # Main content as markdown
    content = Markdown(msg.text_content) if msg.text_content else Text("")

    # Usage footer
    footer = ""
    if msg.usage and not msg.is_streaming:
        u = msg.usage
        footer = (f" ⬇{_fmt_tokens(u.get('input_tokens', 0))} "
                  f"⬆{_fmt_tokens(u.get('output_tokens', 0))}")
        cost = u.get("total_cost", 0)
        if cost > 0:
            footer += f" ${cost:.4f}"

    # Model subtitle
    model_name = msg.model.split("/")[-1] if msg.model else ""
    subtitle = f"{model_name}{footer}" if model_name or footer else None

    panel = Panel(
        content,
        title=f"Lemon",
        title_align="left",
        subtitle=subtitle,
        subtitle_align="right",
        border_style=f"{rich_color(theme.primary)}",
        padding=(0, 1),
    )
    return render_to_ansi(panel)

def render_thinking_panel(thinking_content: str, expanded: bool = False) -> str:
    """Render thinking/reasoning in a dimmed panel."""
    theme = get_current_theme()
    if not expanded:
        preview = thinking_content[:100] + "..." if len(thinking_content) > 100 else thinking_content
        text = Text(f"💭 {preview}", style=f"{rich_color(theme.dim)}")
    else:
        text = Text(thinking_content, style=f"{rich_color(theme.dim)}")

    panel = Panel(
        text,
        title="Thinking",
        title_align="left",
        border_style=f"{rich_color(theme.dim)}",
        padding=(0, 1),
    )
    return render_to_ansi(panel)

def render_tool_result(msg, formatter_registry=None) -> str:
    """Render tool result message."""
    theme = get_current_theme()
    style = f"{rich_color(theme.error)}" if msg.is_error else f"{rich_color(theme.muted)}"

    if formatter_registry:
        formatted = formatter_registry.format_result(msg.tool_name, msg.content)
        text = Text(formatted.summary)
    else:
        text = Text(msg.content[:200])

    return render_to_ansi(Panel(
        text,
        title=f"Tool: {msg.tool_name}",
        title_align="left",
        border_style=style,
        padding=(0, 1),
    ))

def _fmt_tokens(n: int) -> str:
    if n >= 1_000_000: return f"{n/1_000_000:.1f}M"
    if n >= 1_000: return f"{n/1_000:.1f}k"
    return str(n)
```

### 5.18 commands/registry.py + core.py + session.py + ui.py (~400 lines total)

```python
# registry.py
from dataclasses import dataclass
from typing import Callable
from lemon_cli.constants import SLASH_COMMANDS, COMMAND_ALIASES

@dataclass
class SlashCommand:
    name: str
    aliases: list[str]
    description: str
    handler: Callable  # fn(app, args: list[str]) -> bool (True=continue, False=quit)

class CommandRegistry:
    def __init__(self):
        self._commands: dict[str, SlashCommand] = {}

    def register(self, cmd: SlashCommand):
        self._commands[cmd.name] = cmd
        for alias in cmd.aliases:
            self._commands[alias] = cmd

    def dispatch(self, text: str) -> bool:
        """Parse and dispatch. Returns False to quit."""
        parts = text.strip().split(maxsplit=1)
        cmd_name = parts[0].lower()
        args = parts[1].split() if len(parts) > 1 else []

        # Resolve alias
        cmd_name = COMMAND_ALIASES.get(cmd_name, cmd_name)

        cmd = self._commands.get(cmd_name)
        if cmd:
            return cmd.handler(args)

        # Prefix matching
        matches = [name for name in self._commands if name.startswith(cmd_name)]
        if len(matches) == 1:
            return self._commands[matches[0]].handler(args)
        elif len(matches) > 1:
            from lemon_cli.display.console import cprint
            cprint(f"Ambiguous command. Did you mean: {', '.join(matches)}?")
            return True

        from lemon_cli.display.console import cprint
        cprint(f"Unknown command: {cmd_name}. Type /help for available commands.")
        return True

    def get_command_names(self) -> list[str]:
        return [name for name in self._commands if name.startswith("/")]

    def get_commands_with_descriptions(self) -> list[tuple[str, str]]:
        seen = set()
        result = []
        for name, cmd in self._commands.items():
            if cmd.name not in seen and name.startswith("/"):
                seen.add(cmd.name)
                result.append((cmd.name, cmd.description))
        return sorted(result)
```

**core.py key handlers:**
```python
def register_core_commands(registry, app):
    registry.register(SlashCommand("/help", [], "Show available commands",
                                    lambda args: cmd_help(app, args)))
    registry.register(SlashCommand("/quit", ["/exit", "/q"], "Exit",
                                    lambda args: False))
    registry.register(SlashCommand("/new", [], "Start a new session",
                                    lambda args: cmd_new(app, args)))
    registry.register(SlashCommand("/model", [], "Show/switch model",
                                    lambda args: cmd_model(app, args)))
    registry.register(SlashCommand("/clear", [], "Clear display",
                                    lambda args: cmd_clear(app, args)))
    registry.register(SlashCommand("/reset", [], "Reset session",
                                    lambda args: cmd_reset(app, args)))
    registry.register(SlashCommand("/save", [], "Save session",
                                    lambda args: cmd_save(app, args)))
    registry.register(SlashCommand("/usage", [], "Show token usage",
                                    lambda args: cmd_usage(app, args)))
    registry.register(SlashCommand("/config", [], "Show/edit config",
                                    lambda args: cmd_config(app, args)))
    registry.register(SlashCommand("/skin", [], "Show/switch theme",
                                    lambda args: cmd_skin(app, args)))
    registry.register(SlashCommand("/stop", ["/abort"], "Abort agent",
                                    lambda args: cmd_stop(app, args)))
    registry.register(SlashCommand("/history", [], "List saved sessions",
                                    lambda args: cmd_history(app, args)))

def cmd_help(app, args):
    """Print all available commands grouped by category."""
    from lemon_cli.display.console import cprint
    cprint("\n  Available Commands:\n")
    for name, desc in app._command_registry.get_commands_with_descriptions():
        cprint(f"    {name:16} {desc}")
    cprint("")
    return True

def cmd_usage(app, args):
    usage = app._store.state.cumulative_usage
    from lemon_cli.display.console import cprint
    cprint(f"\n  {usage.format_summary()}\n")
    return True

def cmd_skin(app, args):
    from lemon_cli.theme import set_theme, get_current_theme, get_available_themes
    from lemon_cli.display.console import cprint
    if not args:
        current = get_current_theme()
        available = get_available_themes()
        cprint(f"  Current: {current.name}  Available: {', '.join(available)}")
        return True
    if set_theme(args[0]):
        cprint(f"  Switched to {args[0]} theme")
    else:
        cprint(f"  Unknown theme: {args[0]}")
    return True

def cmd_stop(app, args):
    app._connection.abort(app._store.state.active_session_id)
    return True

def cmd_model(app, args):
    from lemon_cli.display.console import cprint
    if not args:
        model = app._store.state.model
        cprint(f"  Current model: {model.provider}:{model.id}" if model else "  No model set")
        return True
    # Request model list or switch
    app._connection.list_models()
    return True

def cmd_new(app, args):
    app._connection.start_session(cwd=app._store.state.cwd)
    return True

def cmd_reset(app, args):
    app._connection.reset(app._store.state.active_session_id)
    return True

def cmd_save(app, args):
    app._connection.save(app._store.state.active_session_id)
    return True

def cmd_clear(app, args):
    import os
    os.system("clear")
    return True

def cmd_history(app, args):
    app._connection.list_sessions()
    return True

def cmd_config(app, args):
    from lemon_cli.display.console import cprint
    from lemon_cli.config import load_config
    config = load_config(app._store.state.cwd)
    cprint(f"  Provider: {config.agent.default_provider}")
    cprint(f"  Model: {config.agent.default_model}")
    cprint(f"  Theme: {config.tui.theme}")
    return True
```

**ui.py key handlers:**
```python
def cmd_retry(app, args):
    """Re-send last user message."""
    for msg in reversed(app._store.state.messages):
        if msg.type == "user":
            app._connection.prompt(msg.content, app._store.state.active_session_id)
            return True
    app.print("  No user message to retry")
    return True

def cmd_undo(app, args):
    """Remove last exchange (reset + replay all but last user msg)."""
    messages = app._store.state.messages
    # Find last user message index
    last_user_idx = None
    for i in range(len(messages) - 1, -1, -1):
        if messages[i].type == "user":
            last_user_idx = i
            break
    if last_user_idx is None:
        app.print("  Nothing to undo")
        return True
    app._connection.reset(app._store.state.active_session_id)
    # Replay all user messages up to (not including) the last one
    for msg in messages[:last_user_idx]:
        if msg.type == "user":
            app._connection.prompt(msg.content, app._store.state.active_session_id)
    return True

def cmd_compact(app, args):
    app._store.toggle_compact_mode()
    mode = "on" if app._store.state.compact_mode else "off"
    app.print(f"  Compact mode: {mode}")
    return True

def cmd_thinking(app, args):
    """Toggle thinking panel visibility."""
    # Toggle all expanded thinking IDs
    app.print("  Thinking display toggled")
    return True
```

### 5.19 autocomplete/ (~200 lines total)

```python
# slash.py
from prompt_toolkit.completion import Completer, Completion
from lemon_cli.constants import SLASH_COMMANDS

class SlashCommandCompleter(Completer):
    def get_completions(self, document, complete_event):
        text = document.text_before_cursor.lstrip()
        if not text.startswith("/"):
            return
        word = text.split()[0] if text.split() else text
        for name, desc in SLASH_COMMANDS.items():
            if name.startswith(word):
                yield Completion(
                    name, start_position=-len(word),
                    display=name, display_meta=desc)

# filepath.py
from prompt_toolkit.completion import Completer, Completion
from pathlib import Path

class FilePathCompleter(Completer):
    def __init__(self, cwd: str = "."):
        self._cwd = cwd

    def get_completions(self, document, complete_event):
        text = document.text_before_cursor
        # Find the last whitespace-delimited token
        tokens = text.split()
        if not tokens:
            return
        word = tokens[-1]
        if not any(word.startswith(p) for p in ("./", "../", "~/", "/")):
            return
        # Expand and list
        expanded = Path(word).expanduser()
        if not expanded.is_absolute():
            expanded = Path(self._cwd) / expanded
        parent = expanded.parent if not expanded.is_dir() else expanded
        prefix = expanded.name if not expanded.is_dir() else ""
        if not parent.exists():
            return
        count = 0
        for entry in sorted(parent.iterdir()):
            if prefix and not entry.name.startswith(prefix):
                continue
            name = entry.name + ("/" if entry.is_dir() else "")
            yield Completion(name, start_position=-len(prefix),
                           display=name)
            count += 1
            if count >= 30:
                break

# combined.py
from prompt_toolkit.completion import Completer, merge_completers

class CombinedCompleter(Completer):
    def __init__(self, cwd: str = "."):
        self._slash = SlashCommandCompleter()
        self._filepath = FilePathCompleter(cwd)

    def get_completions(self, document, complete_event):
        text = document.text_before_cursor.lstrip()
        if text.startswith("/"):
            yield from self._slash.get_completions(document, complete_event)
        else:
            yield from self._filepath.get_completions(document, complete_event)
```

### 5.20 cli.py (~120 lines)

```python
import argparse
import os
import sys

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Lemon Agent CLI/TUI")

    parser.add_argument("--cwd", "-d", default=os.getcwd(), help="Working directory")
    parser.add_argument("--model", "-m", help="Model spec (provider:model_id)")
    parser.add_argument("--provider", "-p", help="Default LLM provider")
    parser.add_argument("--base-url", help="Custom API base URL")
    parser.add_argument("--system-prompt", help="Custom system prompt")
    parser.add_argument("--session-file", help="Resume specific session file")
    parser.add_argument("--debug", action="store_true", help="Debug mode")
    parser.add_argument("--no-ui", action="store_true", help="Headless mode")
    parser.add_argument("--skin", help="Theme name")

    # WebSocket options
    parser.add_argument("--ws-url", help="WebSocket URL for control plane")
    parser.add_argument("--ws-token", help="WebSocket auth token")
    parser.add_argument("--ws-role", help="WebSocket role")
    parser.add_argument("--ws-scopes", help="WebSocket scopes (comma-separated)")
    parser.add_argument("--ws-client-id", help="WebSocket client ID")

    # Path
    parser.add_argument("--lemon-path", help="Path to lemon repo root")

    return parser.parse_args()


def main():
    args = parse_args()

    from lemon_cli.config import resolve_config
    config = resolve_config(args)

    # Apply theme
    from lemon_cli.theme import set_theme
    if args.skin:
        set_theme(args.skin)
    elif config.theme:
        set_theme(config.theme)

    # Select connection mode
    if config.ws_url:
        from lemon_cli.connection.websocket import WebSocketConnection
        connection = WebSocketConnection(
            ws_url=config.ws_url, token=config.ws_token,
            role=config.ws_role,
            scopes=config.ws_scopes.split(",") if config.ws_scopes else None,
            client_id=config.ws_client_id)
    else:
        from lemon_cli.connection.rpc import RPCConnection
        model_spec = f"{config.provider}:{config.model}"
        connection = RPCConnection(
            cwd=config.cwd, model=model_spec,
            lemon_path=config.lemon_path,
            system_prompt=config.system_prompt,
            session_file=config.session_file,
            debug=config.debug, ui=not args.no_ui)

    # Create state store
    from lemon_cli.state.store import StateStore
    store = StateStore(cwd=config.cwd)

    # Create and run app
    from lemon_cli.tui.app import LemonApp
    app = LemonApp(connection=connection, config=config, store=store)

    try:
        app.run()
    except KeyboardInterrupt:
        pass
    finally:
        # Cleanup
        import asyncio
        try:
            asyncio.get_event_loop().run_until_complete(connection.stop())
        except:
            pass


if __name__ == "__main__":
    main()
```

### 5.21 bin/lemon-cli (shell launcher)

```bash
#!/usr/bin/env bash
set -euo pipefail

# Resolve lemon root
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LEMON_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export LEMON_PATH="$LEMON_ROOT"

CLI_DIR="$LEMON_ROOT/clients/lemon-cli"

# Check if control plane is running (for auto-WS mode)
WS_URL="${LEMON_WS_URL:-}"
if [ -z "$WS_URL" ]; then
    if curl -sf http://localhost:4040/health > /dev/null 2>&1; then
        export LEMON_WS_URL="ws://localhost:4040/ws"
    fi
fi

# Ensure uv is available
if ! command -v uv &> /dev/null; then
    echo "Error: uv is required. Install with: curl -LsSf https://astral.sh/uv/install.sh | sh"
    exit 1
fi

# Run the CLI
cd "$CLI_DIR"
exec uv run lemon-cli "$@"
```

---

## 6. Architecture Deep Dive

### 6.1 Three-Thread Model

```
┌─────────────────────────────────────────────────────────┐
│                    Main Thread                           │
│  prompt_toolkit Application.run()                        │
│  - Handles keyboard input via keybindings                │
│  - Renders layout (HSplit of widgets)                    │
│  - Enqueues text to _pending_input queue                 │
│  - Calls app.invalidate() on state changes               │
└──────────────────────┬──────────────────────────────────┘
                       │ app.invalidate()
┌──────────────────────┴──────────────────────────────────┐
│              Thread 1: Spinner Loop (daemon)             │
│  while True:                                             │
│    if busy: spinner.advance(); app.invalidate()          │
│    sleep(0.08 if busy else 0.5)                          │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│              Thread 2: Process Loop (daemon)              │
│  while True:                                             │
│    text = _pending_input.get(timeout=0.1)                │
│    if text.startswith("/"): dispatch_command(text)        │
│    else: connection.prompt(text)                          │
│    also: process_ui_requests()                           │
└─────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────┐
│         Thread 3: Connection I/O (daemon)                │
│  asyncio event loop                                      │
│  - RPC: read subprocess stdout lines, parse JSON         │
│  - WS: websockets recv loop, parse frames                │
│  - Callbacks marshal to main thread via app.invalidate() │
└─────────────────────────────────────────────────────────┘
```

### 6.2 Data Flow

```
User types "hello" → Enter keybinding → _pending_input.put("hello")
  → Process loop dequeues → connection.prompt("hello", session_id)
  → RPC: writes {"type":"prompt","text":"hello"} to subprocess stdin
  → Backend processes, streams events back on stdout
  → Connection reads: {"type":"event","event":{"type":"message_start",...}}
  → on_message callback → store.handle_event(event, session_id)
  → State updates: session.streaming_message = normalized_msg
  → store._notify() → app.invalidate()
  → prompt_toolkit re-renders layout
  → Status bar shows "Working... 2.3s"
  → Eventually message_end → streaming_message finalized → panel rendered
```

### 6.3 UI Request Flow (Overlays)

```
Backend sends: {"type":"ui_request","id":"abc","method":"select","params":{...}}
  → on_message → store.enqueue_ui_request(msg)
  → Process loop: process_ui_requests()
  → Creates SelectOverlay(params)
  → Overlay renders in layout (ConditionalContainer becomes visible)
  → User interacts (arrow keys, number keys, Enter)
  → overlay.confirm() → result_queue.put(result)
  → wait_for_result() returns → connection.respond_to_ui_request(id, result)
  → Sends: {"type":"ui_response","id":"abc","result":"selected_value"}
```

### 6.4 Rich + prompt_toolkit Bridge

```
Rich Console → StringIO (capture ANSI output)
  → ANSI string with escape codes
  → prompt_toolkit ANSI() formatter
  → print_formatted_text() renders in terminal
```

This is how Hermes does it: Rich handles all content rendering (markdown, panels, syntax highlighting), prompt_toolkit handles the interactive TUI (input, keybindings, layout). The `ChatConsole` bridges them by capturing Rich output as ANSI strings.

---

## 7. Theme System

### 7.1 Color Mapping Table

| Theme | Primary | Secondary | Accent | Success | Warning | Error | Muted | Border | ModBg | OvBg |
|-------|---------|-----------|--------|---------|---------|-------|-------|--------|-------|------|
| lemon | 220 | 228 | 208 | 114 | 214 | 203 | 243 | 240 | 58 | 236 |
| lime | 118 | 157 | 154 | 114 | 214 | 203 | 243 | 240 | 22 | 22 |
| midnight | 141 | 183 | 81 | 114 | 221 | 204 | 245 | 60 | 17 | 17 |
| rose | 211 | 224 | 205 | 150 | 222 | 196 | 244 | 132 | 52 | 52 |
| ocean | 38 | 116 | 51 | 114 | 215 | 203 | 245 | 30 | 23 | 23 |
| contrast | 15 | 14 | 11 | 10 | 11 | 9 | 250 | 248 | 234 | 234 |

### 7.2 Where Colors Are Used

| Color Role | Used In |
|---|---|
| primary | Busy indicator, panel title, prompt text, completions highlight |
| secondary | Model name in status bar, response panel subtitle |
| accent | Compact mode flag, session highlights |
| success | Lemon art leaf, success indicators |
| warning | Warning messages |
| error | Error panels, failed tool results |
| muted | Status bar text, token counts, elapsed timer |
| border | Panel borders, input rules |
| modeline_bg | Status bar background |
| overlay_bg | Overlay backgrounds |

---

## 8. Implementation Order

### Phase 1: Foundation (everything depends on these)
1. `pyproject.toml` -- project metadata, deps, entry point
2. `types.py` -- wire protocol dataclasses
3. `config.py` -- config loading
4. `constants.py` -- static data
5. `theme.py` -- theme definitions

### Phase 2: Connection Layer (testable in isolation)
6. `connection/protocol.py` -- shared parsing
7. `connection/base.py` -- abstract interface
8. `connection/rpc.py` -- JSON-line RPC
9. `connection/websocket.py` -- WebSocket OpenClaw

### Phase 3: State Management
10. `state/usage.py`
11. `state/events.py`
12. `state/store.py`

### Phase 4: Display Layer
13. `display/console.py` -- Rich/PT bridge
14. `formatters/base.py` + `formatters/registry.py`
15. `formatters/*.py` -- individual formatters
16. `display/markdown.py`, `display/panels.py`, `display/thinking.py`, `display/tools.py`

### Phase 5: Commands + Autocomplete
17. `commands/registry.py`
18. `commands/core.py`, `commands/session.py`, `commands/ui.py`
19. `autocomplete/slash.py`, `autocomplete/filepath.py`, `autocomplete/combined.py`

### Phase 6: TUI Assembly
20. `tui/spinner.py`
21. `tui/status_bar.py`
22. `tui/banner.py`
23. `tui/overlays/*`
24. `tui/input_area.py`
25. `tui/layout.py`
26. `tui/app.py`

### Phase 7: Entry Points
27. `cli.py` + `__main__.py`
28. `bin/lemon-cli`

---

## 9. Verification Plan

1. **Smoke test (RPC mode):**
   ```bash
   cd clients/lemon-cli
   uv run lemon-cli --cwd /tmp/test-project --lemon-path ~/dev/lemon
   ```
   Should spawn debug_agent_rpc.exs, show banner, accept input, stream responses.

2. **Smoke test (WS mode):**
   ```bash
   ./bin/lemon --daemon
   uv run lemon-cli --ws-url ws://localhost:4040/ws
   ```
   Should connect to control plane, show banner, chat works.

3. **Slash commands:** Test `/help`, `/model`, `/sessions`, `/save`, `/skin lime`, `/usage`, `/quit`

4. **UI requests:** Trigger a tool that requires approval, verify overlay appears and response flows back to server.

5. **Ctrl+C chain:** Verify interrupt during agent run aborts; during idle clears input; double-press quits.

6. **Themes:** `/skin lemon`, `/skin lime`, `/skin midnight`, `/skin rose`, `/skin ocean`, `/skin contrast` -- colors update in status bar, panels, banner.

7. **Multi-session:** `/new` creates second session, `/sessions` lists both, `/switch` works, status bar shows session count.

8. **Launcher:** `./bin/lemon-cli` works end-to-end (discovers lemon path, detects running runtime, connects).

9. **Streaming:** Send a prompt that triggers a long response, verify real-time streaming display with spinner and progressive text.

10. **Tool execution:** Send a prompt that uses tools (e.g., "read mix.exs"), verify spinner shows tool name, completion line shows emoji + verb + path + duration.

---

## Size Estimate

| Area | Files | ~Lines |
|------|-------|--------|
| Foundation (types, config, theme, constants) | 5 | 930 |
| Connection layer | 4 | 800 |
| State management | 3 | 600 |
| Display + formatters | 14 | 1,100 |
| Commands + autocomplete | 6 | 600 |
| TUI (app, layout, input, spinner, status, banner, overlays) | 11 | 1,600 |
| Entry points | 3 | 140 |
| **Total** | **~46** | **~5,770** |
