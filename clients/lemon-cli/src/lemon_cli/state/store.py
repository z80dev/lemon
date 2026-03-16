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
