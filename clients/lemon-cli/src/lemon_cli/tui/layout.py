from prompt_toolkit.layout import (
    HSplit, Window, ConditionalContainer, FormattedTextControl,
    FloatContainer, Float, Layout, ScrollablePane,
)
from prompt_toolkit.layout.dimension import Dimension
from prompt_toolkit.widgets import TextArea
from prompt_toolkit.layout.menus import CompletionsMenu
from prompt_toolkit.layout.controls import BufferControl
from prompt_toolkit.buffer import Buffer
from prompt_toolkit.filters import Condition
from prompt_toolkit.formatted_text import ANSI
from prompt_toolkit.document import Document

# Module-level output buffer shared with console.py
_output_buffer = Buffer(name="output", read_only=True)


def get_output_buffer() -> Buffer:
    return _output_buffer


def append_output(text: str):
    """Append text to the output buffer and scroll to bottom."""
    buf = _output_buffer
    existing = buf.text
    new_text = existing + text + "\n" if existing else text + "\n"
    buf.set_document(Document(new_text, len(new_text)), bypass_readonly=True)


def render_activity_line(state, spinner, terminal_width: int = 80) -> str:
    """Render the live activity line shown while the agent is busy."""
    spinner_text = spinner.render() if spinner else " ..."

    streaming = state.streaming_message
    thinking = streaming.thinking_content if streaming else ""
    if not state.show_thinking or not thinking:
        return spinner_text

    preview = " ".join(thinking.split())
    if not preview:
        return spinner_text

    max_len = max(16, terminal_width - 6)
    if len(preview) > max_len:
        preview = preview[: max_len - 3] + "..."

    return f" 💭 {preview}"


def build_layout(store, spinner, input_area: TextArea | None = None) -> Layout:
    """Build the HSplit layout and return a Layout object."""

    # Condition helpers
    is_busy = Condition(lambda: store.state.busy)
    has_overlay = Condition(lambda: bool(store.state.pending_ui_requests))

    def render_status_bar():
        from lemon_cli.tui.status_bar import render_status_bar as _render
        import shutil
        width = shutil.get_terminal_size().columns
        text = _render(store.state, terminal_width=width)
        return ANSI(text)

    def render_spinner():
        import shutil

        width = shutil.get_terminal_size().columns
        return ANSI(render_activity_line(store.state, spinner, terminal_width=width))

    def render_overlay():
        request = (store.state.pending_ui_requests[0]
                   if store.state.pending_ui_requests else None)
        if not request:
            return ""
        params = request.params if hasattr(request, "params") else request.get("params", {})
        title = params.get("title", "") if isinstance(params, dict) else getattr(params, "title", "")
        return ANSI(f"  {title}")

    # Scrollable output pane replaces the spacer
    output_window = Window(
        content=BufferControl(buffer=_output_buffer, focusable=False),
        height=Dimension(min=3, weight=10),
        wrap_lines=True,
    )

    body_components = [
        # 1. Scrollable output area
        output_window,

        # 2. Overlay container (conditional)
        ConditionalContainer(
            content=Window(
                FormattedTextControl(render_overlay),
                height=Dimension(min=3, max=15),
            ),
            filter=has_overlay,
        ),

        # 3. Spinner/thinking widget (conditional)
        ConditionalContainer(
            content=Window(
                FormattedTextControl(render_spinner),
                height=1,
            ),
            filter=is_busy,
        ),

        # 4. Status bar
        Window(
            FormattedTextControl(render_status_bar),
            height=1,
            style="class:status-bar",
        ),

        # 5. Input rule (separator)
        Window(height=1, char="─", style="class:input-rule"),
    ]

    # 6. Input area (if provided)
    if input_area is not None:
        body_components.append(input_area)

    # 7. Input rule bottom
    body_components.append(Window(height=1, char="─", style="class:input-rule"))

    root = FloatContainer(
        content=HSplit(body_components),
        floats=[
            Float(
                xcursor=True,
                ycursor=True,
                content=CompletionsMenu(max_height=12, scroll_offset=2),
            ),
        ],
    )

    return Layout(root, focused_element=input_area)
