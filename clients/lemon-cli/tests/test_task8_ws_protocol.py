"""Task #8 — codex-4: Python WS protocol incompatibility tests.

1. First outbound frame after connect must be a 'req' with method='connect'.
2. Method names must align with control-plane schemas.
"""
import asyncio
import json
import pytest

from unittest.mock import AsyncMock, MagicMock, patch, call


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
