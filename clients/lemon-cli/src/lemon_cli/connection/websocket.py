import asyncio
import json
import uuid
from dataclasses import dataclass, field
from typing import Any
import websockets
from lemon_cli.connection.base import AgentConnection
from lemon_cli.connection.protocol import parse_server_message
from lemon_cli.types import (
    ErrorMessage,
    EventMessage,
    SessionEvent,
    SessionStartedMessage,
    SessionClosedMessage,
    ActiveSessionMessage,
    SessionsListMessage,
    RunningSessionsMessage,
    ModelsListMessage,
    StatsMessage,
    SaveResultMessage,
    ModelInfo,
)

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
        try:
            self._ws = await websockets.connect(self._ws_url, extra_headers=headers)
            self._reconnect_delay = WS_RECONNECT_BASE_DELAY
            await self._send_connect_handshake()
            asyncio.create_task(self._read_loop())
        except Exception as e:
            self._emit("error", f"WebSocket connect failed: {e}")
            if self._running:
                await self._reconnect()

    async def _send_connect_handshake(self) -> None:
        """Send the OpenClaw connect handshake frame immediately after socket open."""
        params: dict = {
            "role": self._role or "operator",
            "client": {"id": self._client_id or "lemon-cli"},
        }
        if self._scopes is not None:
            params["scopes"] = self._scopes
        if self._token:
            params["auth"] = {"token": self._token}
        req_id = str(uuid.uuid4())
        frame = {"type": "req", "id": req_id, "method": "connect", "params": params}
        self._pending[req_id] = PendingRequest(method="connect")
        if self._ws:
            await self._ws.send(json.dumps(frame))

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
                type="error", message=error.get("message", "Unknown error"),
                session_id=None))
            return

        payload = frame.get("payload", {})
        # Map OpenClaw response to normalized message based on pending.method
        normalized = self._map_response(pending.method, payload, pending.session_id)
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

    def _map_response(self, method: str, payload: dict,
                      session_id: str | None = None) -> list:
        """Map OpenClaw response payload to normalized ServerMessage list."""
        match method:
            case "sessions.start":
                model_data = payload.get("model") or {}
                model = ModelInfo(
                    provider=model_data.get("provider", "unknown"),
                    id=model_data.get("id", "unknown"),
                )
                return [SessionStartedMessage(
                    type="session_started",
                    session_id=payload.get("sessionKey", session_id or ""),
                    cwd=payload.get("cwd", ""),
                    model=model,
                )]
            case "sessions.list":
                return [SessionsListMessage(
                    type="sessions_list",
                    sessions=payload.get("sessions", []),
                    error=payload.get("error"),
                )]
            case "sessions.delete":
                return [SessionClosedMessage(
                    type="session_closed",
                    session_id=session_id or payload.get("sessionKey", ""),
                    reason=payload.get("reason", "normal"),
                )]
            case "sessions.active.list.running":
                return [RunningSessionsMessage(
                    type="running_sessions",
                    sessions=payload.get("sessions", []),
                    error=payload.get("error"),
                )]
            case "sessions.active.set":
                return [ActiveSessionMessage(
                    type="active_session",
                    session_id=payload.get("sessionKey"),
                )]
            case "models.list":
                return [ModelsListMessage(
                    type="models_list",
                    providers=payload.get("providers", []),
                    error=payload.get("error"),
                )]
            case _:
                # For commands with no meaningful response (abort, reset, health, connect, etc.)
                return []

    def _map_event(self, event_name: str, payload: dict) -> SessionEvent | None:
        """Map OpenClaw event name to SessionEvent."""
        # OpenClaw events use dot notation: "agent.message_start" -> "message_start"
        # Strip any prefix like "agent." or "chat."
        parts = event_name.split(".")
        event_type = parts[-1] if parts else event_name

        # Build data array based on event type
        data: list[Any] = []

        match event_type:
            case "agent_start" | "turn_start":
                data = []
            case "agent_end":
                data = [payload.get("messages", [])]
            case "turn_end":
                data = [payload.get("message"), payload.get("tool_results", [])]
            case "message_start" | "message_end":
                data = [payload.get("message")]
            case "message_update":
                data = [payload.get("message"), payload.get("deltas", [])]
            case "tool_execution_start":
                data = [
                    payload.get("id", ""),
                    payload.get("name", ""),
                    payload.get("args", {}),
                ]
            case "tool_execution_update":
                data = [
                    payload.get("id", ""),
                    payload.get("name", ""),
                    payload.get("args", {}),
                    payload.get("partial_result"),
                ]
            case "tool_execution_end":
                data = [
                    payload.get("id", ""),
                    payload.get("name", ""),
                    payload.get("result"),
                    payload.get("is_error", False),
                ]
            case "error":
                data = [payload.get("reason", ""), payload.get("partial_state", {})]
            case _:
                return None

        return SessionEvent(type=event_type, data=data)

    def _send_request(self, method: str, params: dict,
                      session_id: str | None = None,
                      pending_method: str | None = None) -> str:
        """Send OpenClaw req frame.

        pending_method: if set, used as the key in _pending instead of method,
        allowing the response handler to map by the logical operation name.
        """
        req_id = str(uuid.uuid4())
        if len(self._pending) >= WS_COMMAND_QUEUE_LIMIT:
            self._emit("error", "Command queue full")
            return req_id
        effective_method = pending_method or method
        self._pending[req_id] = PendingRequest(method=effective_method, session_id=session_id)
        frame = {"type": "req", "id": req_id, "method": method, "params": params}
        if self._ws:
            asyncio.create_task(self._ws.send(json.dumps(frame)))
        return req_id

    def send_command(self, cmd: dict) -> None:
        """Translate normalized command to OpenClaw req."""
        session_id = cmd.get("session_id")
        match cmd.get("type"):
            case "prompt":
                self._send_request("chat.send", {
                    "sessionKey": session_id,
                    "prompt": cmd["text"],
                }, session_id)
            case "start_session":
                self._send_request("sessions.active", {
                    "sessionKey": session_id,
                    "cwd": cmd.get("cwd"),
                    "model": cmd.get("model"),
                }, session_id, pending_method="sessions.start")
            case "abort":
                self._send_request("chat.abort", {
                    "sessionKey": session_id,
                }, session_id)
            case "reset":
                self._send_request("sessions.reset", {
                    "sessionKey": session_id,
                }, session_id)
            case "save":
                self._emit("message", {"type": "error",
                    "message": "Save is not supported over control-plane WebSocket."})
            case "stats":
                self._emit("message", {"type": "error",
                    "message": "Stats is not supported over control-plane WebSocket.",
                    "session_id": session_id})
            case "close_session":
                self._send_request("sessions.delete", {
                    "sessionKey": session_id,
                }, session_id)
            case "set_active_session":
                self._send_request("sessions.active", {
                    "sessionKey": session_id,
                }, session_id, pending_method="sessions.active.set")
            case "list_sessions":
                self._send_request("sessions.list", {"limit": 100, "offset": 0})
            case "list_running_sessions":
                self._send_request("sessions.active.list", {"limit": 100},
                                   pending_method="sessions.active.list.running")
            case "list_models":
                self._send_request("models.list", {})
            case "ping":
                self._send_request("health", {})
            case "ui_response" | "quit":
                pass  # Not supported over control-plane WebSocket

    async def stop(self) -> None:
        self._running = False
        if self._ws:
            await self._ws.close()
