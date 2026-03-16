from prompt_toolkit.widgets import TextArea
from prompt_toolkit.key_binding import KeyBindings
from prompt_toolkit.filters import has_completions, is_done
from prompt_toolkit.keys import Keys


def build_input_area(completer=None) -> TextArea:
    """Build and return the main input TextArea widget."""
    return TextArea(
        prompt="❯ ",
        multiline=True,
        wrap_lines=True,
        completer=completer,
        complete_while_typing=True,
        accept_handler=None,  # handled by keybindings
        history=None,
        focusable=True,
        style="class:input-area",
    )


def build_keybindings(app) -> KeyBindings:
    """Build and return key bindings for the input area."""
    kb = KeyBindings()

    @kb.add("enter", filter=~has_completions)
    def handle_enter(event):
        """Submit on Enter (not Shift+Enter)."""
        buf = event.app.current_buffer
        text = buf.text.strip()
        if text:
            buf.reset()
            app.submit_input(text)

    @kb.add("escape", "enter")
    def handle_escape_enter(event):
        """Insert newline on Escape+Enter (or Alt+Enter) for multiline input."""
        event.app.current_buffer.insert_text("\n")

    @kb.add("c-c")
    def handle_ctrl_c(event):
        """Ctrl+C: interrupt (abort agent or quit)."""
        buf = event.app.current_buffer
        if buf.text:
            buf.reset()
        else:
            app.interrupt()

    @kb.add("c-d")
    def handle_ctrl_d(event):
        """Ctrl+D: exit."""
        app._should_exit = True
        event.app.exit()

    @kb.add("up")
    def handle_up(event):
        """Navigate history or move cursor up."""
        buf = event.app.current_buffer
        if "\n" in buf.text:
            # Multi-line: move cursor up
            buf.cursor_up()
        else:
            buf.history_backward()

    @kb.add("down")
    def handle_down(event):
        """Navigate history or move cursor down."""
        buf = event.app.current_buffer
        if "\n" in buf.text:
            buf.cursor_down()
        else:
            buf.history_forward()

    @kb.add("tab")
    def handle_tab(event):
        """Trigger completion."""
        buf = event.app.current_buffer
        if buf.completer:
            buf.start_completion(select_first=False)

    return kb
