"""Thinking visibility configuration and slash-toggle tests."""
from types import SimpleNamespace


def test_thinking_command_toggles_store_state_and_reports_mode():
    from lemon_cli.commands.ui import cmd_thinking
    from lemon_cli.state.store import StateStore

    printed: list[str] = []
    app = SimpleNamespace(_store=StateStore(), print=printed.append)

    assert app._store.state.show_thinking is False

    assert cmd_thinking(app, []) is True
    assert app._store.state.show_thinking is True
    assert printed[-1] == "  Thinking display: on"

    assert cmd_thinking(app, []) is True
    assert app._store.state.show_thinking is False
    assert printed[-1] == "  Thinking display: off"


def test_message_end_renders_thinking_only_when_enabled():
    from lemon_cli.state.store import StateStore
    from lemon_cli.tui.app import LemonApp

    event = SimpleNamespace(
        type="message_end",
        data=[{
            "role": "assistant",
            "content": [
                {"type": "thinking", "thinking": "Inspect the diff first."},
                {"type": "text", "text": "Visible answer"},
            ],
        }],
    )
    msg = SimpleNamespace(event=event)

    hidden_store = StateStore(show_thinking=False)
    hidden_app = LemonApp(connection=SimpleNamespace(), config=None, store=hidden_store)
    hidden_output: list[str] = []
    hidden_app.print = hidden_output.append
    hidden_app._render_event(msg)

    assert hidden_output == ["\nVisible answer"]

    shown_store = StateStore(show_thinking=True)
    shown_app = LemonApp(connection=SimpleNamespace(), config=None, store=shown_store)
    shown_output: list[str] = []
    shown_app.print = shown_output.append
    shown_app._render_event(msg)

    assert len(shown_output) == 2
    assert "Thinking" in shown_output[0]
    assert "Inspect the diff first." in shown_output[0]
    assert shown_output[1] == "\nVisible answer"


def test_activity_line_shows_live_thinking_when_enabled():
    from lemon_cli.state.store import StateStore, NormalizedAssistantMessage
    from lemon_cli.tui.layout import render_activity_line

    class FakeSpinner:
        def render(self) -> str:
            return " spinner "

    store = StateStore(show_thinking=True)
    store.state.busy = True
    store.state.streaming_message = NormalizedAssistantMessage(
        id="assistant_1",
        thinking_content="Inspect the diff before deciding on the fix.",
        is_streaming=True,
    )

    line = render_activity_line(store.state, FakeSpinner(), terminal_width=80)

    assert line.startswith(" 💭 ")
    assert "Inspect the diff before deciding on the fix." in line


def test_activity_line_falls_back_to_spinner_when_thinking_hidden():
    from lemon_cli.state.store import StateStore, NormalizedAssistantMessage
    from lemon_cli.tui.layout import render_activity_line

    class FakeSpinner:
        def render(self) -> str:
            return " spinner "

    store = StateStore(show_thinking=False)
    store.state.busy = True
    store.state.streaming_message = NormalizedAssistantMessage(
        id="assistant_1",
        thinking_content="Inspect the diff before deciding on the fix.",
        is_streaming=True,
    )

    assert render_activity_line(store.state, FakeSpinner(), terminal_width=80) == " spinner "
