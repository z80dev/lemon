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
