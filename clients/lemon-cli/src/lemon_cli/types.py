"""Wire protocol dataclasses for the Lemon agent backend."""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Union


# ---------------------------------------------------------------------------
# Primitive / shared types
# ---------------------------------------------------------------------------

@dataclass
class ModelInfo:
    provider: str
    id: str

    @classmethod
    def from_dict(cls, data: dict) -> "ModelInfo":
        return cls(
            provider=data.get("provider", ""),
            id=data.get("id", ""),
        )


# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

@dataclass
class UsageCost:
    input: float = 0.0
    output: float = 0.0
    cache_read: float = 0.0
    cache_write: float = 0.0
    total: float = 0.0

    @classmethod
    def from_dict(cls, data: dict) -> "UsageCost":
        return cls(
            input=float(data.get("input", 0.0)),
            output=float(data.get("output", 0.0)),
            cache_read=float(data.get("cache_read", 0.0)),
            cache_write=float(data.get("cache_write", 0.0)),
            total=float(data.get("total", 0.0)),
        )


@dataclass
class Usage:
    input: int = 0
    output: int = 0
    cache_read: int = 0
    cache_write: int = 0
    total_tokens: int = 0
    cost: UsageCost | None = None

    @classmethod
    def from_dict(cls, data: dict) -> "Usage":
        cost_data = data.get("cost")
        return cls(
            input=int(data.get("input", 0)),
            output=int(data.get("output", 0)),
            cache_read=int(data.get("cache_read", 0)),
            cache_write=int(data.get("cache_write", 0)),
            total_tokens=int(data.get("total_tokens", 0)),
            cost=UsageCost.from_dict(cost_data) if cost_data else None,
        )


# ---------------------------------------------------------------------------
# Content blocks
# ---------------------------------------------------------------------------

@dataclass
class TextContent:
    type: str  # "text"
    text: str
    text_signature: str | None = None

    @classmethod
    def from_dict(cls, data: dict) -> "TextContent":
        return cls(
            type=data.get("type", "text"),
            text=data.get("text", ""),
            text_signature=data.get("text_signature"),
        )


@dataclass
class ThinkingContent:
    type: str  # "thinking"
    thinking: str
    thinking_signature: str | None = None

    @classmethod
    def from_dict(cls, data: dict) -> "ThinkingContent":
        return cls(
            type=data.get("type", "thinking"),
            thinking=data.get("thinking", ""),
            thinking_signature=data.get("thinking_signature"),
        )


@dataclass
class ToolCall:
    type: str  # "tool_call"
    id: str
    name: str
    arguments: dict = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: dict) -> "ToolCall":
        return cls(
            type=data.get("type", "tool_call"),
            id=data.get("id", ""),
            name=data.get("name", ""),
            arguments=data.get("arguments") or {},
        )


@dataclass
class ImageContent:
    type: str  # "image"
    data: str
    mime_type: str

    @classmethod
    def from_dict(cls, data: dict) -> "ImageContent":
        return cls(
            type=data.get("type", "image"),
            data=data.get("data", ""),
            mime_type=data.get("mime_type", "image/png"),
        )


ContentBlock = Union[TextContent, ThinkingContent, ToolCall, ImageContent]


def parse_content_block(data: dict) -> ContentBlock:
    """Dispatch on type field to construct the right content block."""
    block_type = data.get("type") or data.get("__struct__", "")
    if "ThinkingContent" in block_type or block_type == "thinking":
        return ThinkingContent.from_dict(data)
    elif "ToolCall" in block_type or block_type == "tool_call":
        return ToolCall.from_dict(data)
    elif "ImageContent" in block_type or block_type == "image":
        return ImageContent.from_dict(data)
    else:
        return TextContent.from_dict(data)


# ---------------------------------------------------------------------------
# Message types (from AgentCore)
# ---------------------------------------------------------------------------

@dataclass
class UserMessage:
    role: str  # "user"
    content: str | list[ContentBlock]
    timestamp: int = 0

    @classmethod
    def from_dict(cls, data: dict) -> "UserMessage":
        content = data.get("content", "")
        if isinstance(content, list):
            content = [parse_content_block(b) for b in content]
        return cls(
            role=data.get("role", "user"),
            content=content,
            timestamp=int(data.get("timestamp", 0)),
        )


@dataclass
class AssistantMessage:
    role: str  # "assistant"
    content: list[ContentBlock]
    provider: str = ""
    model: str = ""
    api: str = ""
    usage: Usage | None = None
    stop_reason: str | None = None
    error_message: str | None = None
    timestamp: int = 0

    @classmethod
    def from_dict(cls, data: dict) -> "AssistantMessage":
        content = data.get("content") or []
        if isinstance(content, list):
            content = [parse_content_block(b) for b in content]
        usage_data = data.get("usage")
        return cls(
            role=data.get("role", "assistant"),
            content=content,
            provider=data.get("provider", ""),
            model=data.get("model", ""),
            api=data.get("api", ""),
            usage=Usage.from_dict(usage_data) if usage_data else None,
            stop_reason=data.get("stop_reason"),
            error_message=data.get("error_message"),
            timestamp=int(data.get("timestamp", 0)),
        )


@dataclass
class ToolResultMessage:
    role: str  # "tool_result"
    tool_call_id: str
    tool_name: str
    content: list[ContentBlock]
    details: dict = field(default_factory=dict)
    trust: str = "trusted"
    trust_metadata: dict = field(default_factory=dict)
    is_error: bool = False
    timestamp: int = 0

    @classmethod
    def from_dict(cls, data: dict) -> "ToolResultMessage":
        content = data.get("content") or []
        if isinstance(content, list):
            content = [parse_content_block(b) for b in content]
        return cls(
            role=data.get("role", "tool_result"),
            tool_call_id=data.get("tool_call_id", ""),
            tool_name=data.get("tool_name", ""),
            content=content,
            details=data.get("details") or {},
            trust=data.get("trust", "trusted"),
            trust_metadata=data.get("trust_metadata") or {},
            is_error=bool(data.get("is_error", False)),
            timestamp=int(data.get("timestamp", 0)),
        )


Message = Union[UserMessage, AssistantMessage, ToolResultMessage]


def parse_message(data: dict) -> Message:
    """Dispatch on role/__struct__ to construct the right message type."""
    struct = data.get("__struct__", "")
    role = data.get("role", "")
    if "AssistantMessage" in struct or role == "assistant":
        return AssistantMessage.from_dict(data)
    elif "ToolResultMessage" in struct or role == "tool_result":
        return ToolResultMessage.from_dict(data)
    else:
        return UserMessage.from_dict(data)


# ---------------------------------------------------------------------------
# UI request params
# ---------------------------------------------------------------------------

@dataclass
class SelectOption:
    label: str
    value: str
    description: str | None = None

    @classmethod
    def from_dict(cls, data: dict) -> "SelectOption":
        return cls(
            label=data.get("label", ""),
            value=data.get("value", ""),
            description=data.get("description"),
        )


@dataclass
class SelectParams:
    title: str
    options: list[SelectOption]
    opts: dict = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: dict) -> "SelectParams":
        return cls(
            title=data.get("title", ""),
            options=[SelectOption.from_dict(o) for o in data.get("options", [])],
            opts=data.get("opts") or {},
        )


@dataclass
class ConfirmParams:
    title: str
    message: str
    opts: dict = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: dict) -> "ConfirmParams":
        return cls(
            title=data.get("title", ""),
            message=data.get("message", ""),
            opts=data.get("opts") or {},
        )


@dataclass
class InputParams:
    title: str
    placeholder: str | None = None
    opts: dict = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: dict) -> "InputParams":
        return cls(
            title=data.get("title", ""),
            placeholder=data.get("placeholder"),
            opts=data.get("opts") or {},
        )


@dataclass
class EditorParams:
    title: str
    prefill: str | None = None
    opts: dict = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: dict) -> "EditorParams":
        return cls(
            title=data.get("title", ""),
            prefill=data.get("prefill"),
            opts=data.get("opts") or {},
        )


UIParams = Union[SelectParams, ConfirmParams, InputParams, EditorParams]


def parse_ui_params(method: str, params: dict) -> UIParams:
    if method == "select":
        return SelectParams.from_dict(params)
    elif method == "confirm":
        return ConfirmParams.from_dict(params)
    elif method == "input":
        return InputParams.from_dict(params)
    elif method == "editor":
        return EditorParams.from_dict(params)
    else:
        return InputParams.from_dict(params)


# ---------------------------------------------------------------------------
# Session info
# ---------------------------------------------------------------------------

@dataclass
class SessionInfo:
    path: str
    id: str
    timestamp: int
    cwd: str
    model: ModelInfo

    @classmethod
    def from_dict(cls, data: dict) -> "SessionInfo":
        return cls(
            path=data.get("path", ""),
            id=data.get("id", ""),
            timestamp=int(data.get("timestamp", 0)),
            cwd=data.get("cwd", ""),
            model=ModelInfo.from_dict(data.get("model") or {}),
        )


@dataclass
class RunningSessionInfo:
    session_id: str
    cwd: str
    is_streaming: bool
    model: ModelInfo

    @classmethod
    def from_dict(cls, data: dict) -> "RunningSessionInfo":
        return cls(
            session_id=data.get("session_id", ""),
            cwd=data.get("cwd", ""),
            is_streaming=bool(data.get("is_streaming", False)),
            model=ModelInfo.from_dict(data.get("model") or {}),
        )


@dataclass
class SessionStats:
    session_id: str
    message_count: int
    turn_count: int
    is_streaming: bool
    cwd: str
    model: ModelInfo
    thinking_level: str | None

    @classmethod
    def from_dict(cls, data: dict) -> "SessionStats":
        return cls(
            session_id=data.get("session_id", ""),
            message_count=int(data.get("message_count", 0)),
            turn_count=int(data.get("turn_count", 0)),
            is_streaming=bool(data.get("is_streaming", False)),
            cwd=data.get("cwd", ""),
            model=ModelInfo.from_dict(data.get("model") or {}),
            thinking_level=data.get("thinking_level"),
        )


@dataclass
class ProviderModel:
    id: str
    name: str

    @classmethod
    def from_dict(cls, data: dict) -> "ProviderModel":
        return cls(
            id=data.get("id", ""),
            name=data.get("name", ""),
        )


@dataclass
class ProviderInfo:
    id: str
    models: list[ProviderModel]

    @classmethod
    def from_dict(cls, data: dict) -> "ProviderInfo":
        return cls(
            id=data.get("id", ""),
            models=[ProviderModel.from_dict(m) for m in data.get("models", [])],
        )


# ---------------------------------------------------------------------------
# Session event
# ---------------------------------------------------------------------------

@dataclass
class SessionEvent:
    type: str
    data: list[Any] | None = None

    @classmethod
    def from_dict(cls, data: dict) -> "SessionEvent":
        return cls(
            type=data.get("type", ""),
            data=data.get("data"),
        )


# ---------------------------------------------------------------------------
# Server messages
# ---------------------------------------------------------------------------

@dataclass
class ReadyMessage:
    type: str  # "ready"
    cwd: str
    model: ModelInfo
    debug: bool
    ui: bool
    primary_session_id: str | None
    active_session_id: str | None

    @classmethod
    def from_dict(cls, data: dict) -> "ReadyMessage":
        return cls(
            type=data.get("type", "ready"),
            cwd=data.get("cwd", ""),
            model=ModelInfo.from_dict(data.get("model") or {}),
            debug=bool(data.get("debug", False)),
            ui=bool(data.get("ui", True)),
            primary_session_id=data.get("primary_session_id"),
            active_session_id=data.get("active_session_id"),
        )


@dataclass
class EventMessage:
    type: str  # "event"
    session_id: str
    event_seq: int
    event: SessionEvent

    @classmethod
    def from_dict(cls, data: dict) -> "EventMessage":
        return cls(
            type=data.get("type", "event"),
            session_id=data.get("session_id", ""),
            event_seq=int(data.get("event_seq", 0)),
            event=SessionEvent.from_dict(data.get("event") or {}),
        )


@dataclass
class SessionStartedMessage:
    type: str  # "session_started"
    session_id: str
    cwd: str
    model: ModelInfo

    @classmethod
    def from_dict(cls, data: dict) -> "SessionStartedMessage":
        return cls(
            type=data.get("type", "session_started"),
            session_id=data.get("session_id", ""),
            cwd=data.get("cwd", ""),
            model=ModelInfo.from_dict(data.get("model") or {}),
        )


@dataclass
class SessionClosedMessage:
    type: str  # "session_closed"
    session_id: str
    reason: str

    @classmethod
    def from_dict(cls, data: dict) -> "SessionClosedMessage":
        return cls(
            type=data.get("type", "session_closed"),
            session_id=data.get("session_id", ""),
            reason=data.get("reason", "normal"),
        )


@dataclass
class ActiveSessionMessage:
    type: str  # "active_session"
    session_id: str | None

    @classmethod
    def from_dict(cls, data: dict) -> "ActiveSessionMessage":
        return cls(
            type=data.get("type", "active_session"),
            session_id=data.get("session_id"),
        )


@dataclass
class StatsMessage:
    type: str  # "stats"
    session_id: str
    stats: SessionStats

    @classmethod
    def from_dict(cls, data: dict) -> "StatsMessage":
        return cls(
            type=data.get("type", "stats"),
            session_id=data.get("session_id", ""),
            stats=SessionStats.from_dict(data.get("stats") or {}),
        )


@dataclass
class SessionsListMessage:
    type: str  # "sessions_list"
    sessions: list[SessionInfo]
    error: str | None

    @classmethod
    def from_dict(cls, data: dict) -> "SessionsListMessage":
        return cls(
            type=data.get("type", "sessions_list"),
            sessions=[SessionInfo.from_dict(s) for s in data.get("sessions", [])],
            error=data.get("error"),
        )


@dataclass
class RunningSessionsMessage:
    type: str  # "running_sessions"
    sessions: list[RunningSessionInfo]
    error: str | None

    @classmethod
    def from_dict(cls, data: dict) -> "RunningSessionsMessage":
        return cls(
            type=data.get("type", "running_sessions"),
            sessions=[RunningSessionInfo.from_dict(s) for s in data.get("sessions", [])],
            error=data.get("error"),
        )


@dataclass
class ModelsListMessage:
    type: str  # "models_list"
    providers: list[ProviderInfo]
    error: str | None

    @classmethod
    def from_dict(cls, data: dict) -> "ModelsListMessage":
        return cls(
            type=data.get("type", "models_list"),
            providers=[ProviderInfo.from_dict(p) for p in data.get("providers", [])],
            error=data.get("error"),
        )


@dataclass
class UIRequestMessage:
    type: str  # "ui_request"
    id: str
    method: str
    params: UIParams

    @classmethod
    def from_dict(cls, data: dict) -> "UIRequestMessage":
        method = data.get("method", "input")
        params_raw = data.get("params") or {}
        return cls(
            type=data.get("type", "ui_request"),
            id=data.get("id", ""),
            method=method,
            params=parse_ui_params(method, params_raw),
        )


@dataclass
class UISignalMessage:
    type: str  # "ui_notify", "ui_status", etc.
    params: dict = field(default_factory=dict)

    @classmethod
    def from_dict(cls, data: dict) -> "UISignalMessage":
        return cls(
            type=data.get("type", ""),
            params=data.get("params") or {},
        )


@dataclass
class SaveResultMessage:
    type: str  # "save_result"
    ok: bool
    path: str | None
    error: str | None

    @classmethod
    def from_dict(cls, data: dict) -> "SaveResultMessage":
        return cls(
            type=data.get("type", "save_result"),
            ok=bool(data.get("ok", False)),
            path=data.get("path"),
            error=data.get("error"),
        )


@dataclass
class PongMessage:
    type: str = "pong"


@dataclass
class DebugMessage:
    type: str  # "debug"
    message: str
    argv: list[str] = field(default_factory=list)

    @classmethod
    def from_dict(cls, data: dict) -> "DebugMessage":
        return cls(
            type=data.get("type", "debug"),
            message=data.get("message", ""),
            argv=data.get("argv") or [],
        )


@dataclass
class ErrorMessage:
    type: str  # "error"
    message: str
    session_id: str | None

    @classmethod
    def from_dict(cls, data: dict) -> "ErrorMessage":
        return cls(
            type=data.get("type", "error"),
            message=data.get("message", ""),
            session_id=data.get("session_id"),
        )


@dataclass
class UnknownMessage:
    type: str
    raw: dict = field(default_factory=dict)


ServerMessage = Union[
    ReadyMessage,
    EventMessage,
    SessionStartedMessage,
    SessionClosedMessage,
    ActiveSessionMessage,
    StatsMessage,
    SessionsListMessage,
    RunningSessionsMessage,
    ModelsListMessage,
    UIRequestMessage,
    UISignalMessage,
    SaveResultMessage,
    PongMessage,
    DebugMessage,
    ErrorMessage,
    UnknownMessage,
]

_UI_SIGNAL_TYPES = {
    "ui_notify", "ui_status", "ui_widget", "ui_working",
    "ui_set_title", "ui_set_editor_text",
}


def parse_server_message(data: dict) -> ServerMessage:
    """Dispatch on data['type'] to construct the right server message dataclass."""
    msg_type = data.get("type", "unknown")
    match msg_type:
        case "ready":
            return ReadyMessage.from_dict(data)
        case "event":
            return EventMessage.from_dict(data)
        case "stats":
            return StatsMessage.from_dict(data)
        case "session_started":
            return SessionStartedMessage.from_dict(data)
        case "session_closed":
            return SessionClosedMessage.from_dict(data)
        case "active_session":
            return ActiveSessionMessage.from_dict(data)
        case "ui_request":
            return UIRequestMessage.from_dict(data)
        case "sessions_list":
            return SessionsListMessage.from_dict(data)
        case "running_sessions":
            return RunningSessionsMessage.from_dict(data)
        case "models_list":
            return ModelsListMessage.from_dict(data)
        case "save_result":
            return SaveResultMessage.from_dict(data)
        case "error":
            return ErrorMessage.from_dict(data)
        case "pong":
            return PongMessage()
        case "debug":
            return DebugMessage.from_dict(data)
        case _:
            if msg_type in _UI_SIGNAL_TYPES:
                return UISignalMessage.from_dict(data)
            return UnknownMessage(type=msg_type, raw=data)
