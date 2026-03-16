"""Task #8 — codex-4: Python WS protocol compatibility tests.

1. First outbound frame after connect must be a 'req' with method='connect'.
2. Method names must align with control-plane schemas.
3. hello-ok must produce a ready message.
4. Current control-plane agent/chat frames must map to normalized TUI events.
"""
import asyncio
import json
import pytest

from unittest.mock import MagicMock, patch


# ---------------------------------------------------------------------------
# Helpers to capture sent frames
# ---------------------------------------------------------------------------

class FakeWS:
    """Fake websocket that records sent messages."""

    def __init__(self):
        self.sent: list[dict] = []
        self.closed = False

    async def send(self, data: str) -> None:
        self.sent.append(json.loads(data))

    async def close(self) -> None:
        self.closed = True

    def __aiter__(self):
        return self

    async def __anext__(self):
        raise StopAsyncIteration


async def _start_and_capture(ws_instance):
    """Call WebSocketConnection._connect() using a fake websocket and return sent frames."""
    from lemon_cli.connection.websocket import WebSocketConnection
    from unittest.mock import AsyncMock as _AsyncMock

    conn = WebSocketConnection(
        ws_url="ws://localhost:4040/ws",
        token="test-token",
        role="operator",
        scopes=["operator.read"],
        client_id="lemon-cli",
    )

    # websockets.connect must be an async mock so `await websockets.connect(...)` works
    async_connect = _AsyncMock(return_value=ws_instance)

    with patch("lemon_cli.connection.websocket.websockets.connect", async_connect):
        # Override _read_loop to avoid blocking on the socket
        async def noop_read_loop():
            pass
        conn._read_loop = noop_read_loop

        await conn._connect()

    return ws_instance.sent


# ---------------------------------------------------------------------------
# Test: first outbound frame is the connect handshake
# ---------------------------------------------------------------------------

def test_first_frame_is_connect():
    """After connecting, the first message sent must be method='connect'."""
    ws = FakeWS()
    sent = asyncio.run(_start_and_capture(ws))

    assert len(sent) >= 1, "Expected at least one outbound frame (the connect handshake)"
    first = sent[0]
    assert first.get("type") == "req", f"First frame type must be 'req', got: {first.get('type')}"
    assert first.get("method") == "connect", (
        f"First frame method must be 'connect', got: {first.get('method')}"
    )


def test_connect_frame_has_auth():
    """connect frame must carry auth.token when a token is provided."""
    ws = FakeWS()
    sent = asyncio.run(_start_and_capture(ws))

    first = sent[0]
    params = first.get("params", {})
    assert "auth" in params, "connect params must have 'auth' key"
    assert params["auth"].get("token") == "test-token", (
        f"Expected token='test-token', got: {params['auth']}"
    )


def test_connect_frame_has_role_and_scopes():
    """connect frame must carry role and scopes."""
    ws = FakeWS()
    sent = asyncio.run(_start_and_capture(ws))

    params = sent[0].get("params", {})
    assert params.get("role") == "operator"
    assert params.get("scopes") == ["operator.read"]


# ---------------------------------------------------------------------------
# Test: method name alignment with control-plane schemas
# ---------------------------------------------------------------------------

def _get_sent_method(cmd: dict) -> str:
    """Send a command and return the method used in the outbound req frame."""
    from lemon_cli.connection.websocket import WebSocketConnection

    conn = WebSocketConnection(ws_url="ws://localhost:4040/ws")
    conn._ws = MagicMock()
    conn._ws.__bool__ = lambda self: True

    sent_frames = []

    async def fake_send(data):
        sent_frames.append(json.loads(data))

    conn._ws.send = fake_send

    # Manually run the async send in a task
    async def run():
        conn.send_command(cmd)
        # Allow any tasks to run
        await asyncio.sleep(0)

    asyncio.run(run())
    return sent_frames[0]["method"] if sent_frames else None


@pytest.mark.parametrize("cmd,expected_method", [
    ({"type": "prompt", "text": "hello", "session_id": "s1"}, "chat.send"),
    ({"type": "close_session", "session_id": "s1"}, "sessions.delete"),
    ({"type": "set_active_session", "session_id": "s1"}, "sessions.active"),
    ({"type": "list_running_sessions"}, "sessions.active.list"),
    ({"type": "reset", "session_id": "s1"}, "sessions.reset"),
    ({"type": "ping"}, "health"),
])
def test_method_names(cmd, expected_method):
    """send_command must use the correct control-plane method name."""
    method = _get_sent_method(cmd)
    assert method == expected_method, (
        f"cmd type={cmd['type']!r}: expected method={expected_method!r}, got={method!r}"
    )


def test_hello_ok_emits_ready_message():
    from lemon_cli.connection.websocket import WebSocketConnection

    conn = WebSocketConnection(ws_url="ws://localhost:4040/ws")
    ready_messages = []
    conn.on_ready = ready_messages.append
    conn._pending["connect-1"] = MagicMock(method="connect")

    conn._handle_hello_ok({
        "type": "hello-ok",
        "snapshot": {"activeSessionId": "session-1"},
        "auth": {"role": "operator", "scopes": ["operator.read"]},
    })

    assert len(ready_messages) == 1
    ready = ready_messages[0]
    assert ready.type == "ready"
    assert ready.active_session_id == "session-1"
    assert conn._pending == {}


def test_current_agent_and_chat_frames_map_to_normalized_events():
    from lemon_cli.connection.websocket import WebSocketConnection

    conn = WebSocketConnection(ws_url="ws://localhost:4040/ws")
    messages = []
    conn.on_message = messages.append

    session_key = "agent:test:main"

    conn._handle_event({
        "type": "event",
        "event": "agent",
        "seq": 1,
        "payload": {"type": "started", "sessionKey": session_key, "runId": "run-1"},
    })
    conn._handle_event({
        "type": "event",
        "event": "chat",
        "seq": 2,
        "payload": {"type": "delta", "sessionKey": session_key, "runId": "run-1", "text": "Hello"},
    })
    conn._handle_event({
        "type": "event",
        "event": "chat",
        "seq": 3,
        "payload": {"type": "delta", "sessionKey": session_key, "runId": "run-1", "text": " world"},
    })
    conn._handle_event({
        "type": "event",
        "event": "agent",
        "seq": 4,
        "payload": {
            "type": "tool_use",
            "phase": "started",
            "sessionKey": session_key,
            "action": {"id": "tool-1", "kind": "bash", "title": "bash", "detail": "echo hi"},
        },
    })
    conn._handle_event({
        "type": "event",
        "event": "agent",
        "seq": 5,
        "payload": {
            "type": "tool_use",
            "phase": "completed",
            "sessionKey": session_key,
            "ok": True,
            "message": "done",
            "action": {"id": "tool-1", "kind": "bash", "title": "bash", "detail": "echo hi"},
        },
    })
    conn._handle_event({
        "type": "event",
        "event": "agent",
        "seq": 6,
        "payload": {"type": "completed", "sessionKey": session_key, "runId": "run-1", "answer": "Hello world"},
    })

    event_types = [msg.event.type for msg in messages if msg.type == "event"]

    assert "agent_start" in event_types
    assert "message_start" in event_types
    assert "message_update" in event_types
    assert "tool_execution_start" in event_types
    assert "tool_execution_end" in event_types
    assert "message_end" in event_types
    assert "agent_end" in event_types

    message_end = next(msg for msg in messages if msg.event.type == "message_end")
    assistant_message = message_end.event.data[0]
    assert assistant_message["content"][0]["text"] == "Hello world"
