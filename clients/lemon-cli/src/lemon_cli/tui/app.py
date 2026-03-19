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
        self._spinner = None
        self._command_registry = None

        # Wire connection callbacks
        self._connection.on_ready = self._on_ready
        self._connection.on_message = self._on_message
        self._connection.on_error = self._on_error
        self._connection.on_close = self._on_close

    def run(self):
        """Main entry point. Starts connection, threads, and prompt_toolkit app."""
        from lemon_cli.tui.layout import build_layout
        from lemon_cli.tui.input_area import build_input_area, build_keybindings
        from lemon_cli.tui.banner import print_banner
        from lemon_cli.tui.spinner import Spinner
        from lemon_cli.commands.registry import build_command_registry
        from lemon_cli.theme import get_current_theme, build_pt_style

        self._spinner = Spinner()
        self._command_registry = build_command_registry(self)

        cwd = getattr(self._config, "cwd", None) or self._store.state.cwd
        from lemon_cli.autocomplete.combined import CombinedCompleter
        completer = CombinedCompleter(cwd=cwd)

        input_area = build_input_area(completer=completer)
        kb = build_keybindings(self)
        layout = build_layout(self._store, self._spinner, input_area)
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
        # Auto-start a session if none exists
        if not msg.active_session_id and not msg.primary_session_id:
            model_spec = None
            if self._config and hasattr(self._config, 'model') and hasattr(self._config, 'provider'):
                m = self._config.model
                p = self._config.provider
                model_spec = m if ':' in m else f"{p}:{m}" if p and m else None
            cwd = getattr(self._config, 'cwd', None) or self._store.state.cwd
            self._connection.start_session(cwd=cwd, model=model_spec)
        self._invalidate()

    def _on_message(self, msg):
        match msg.type:
            case "event":
                self._render_event(msg)
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
                if hasattr(self._store, "set_stats"):
                    self._store.set_stats(msg.stats, msg.session_id)
            case "error":
                self._store.set_error(msg.message)
            case _:
                pass
        self._invalidate()

    def _render_event(self, msg):
        """Render event content to the output buffer as it arrives."""
        event = msg.event
        if not event or not hasattr(event, 'type'):
            return
        match event.type:
            case "message_start":
                if event.data and len(event.data) >= 1:
                    data = event.data[0]
                    if isinstance(data, dict) and data.get("role") == "user":
                        content = data.get("content", "")
                        if isinstance(content, list):
                            content = " ".join(
                                b.get("text", "") for b in content if b.get("type") == "text"
                            )
                        self.print(f"\n  > {content}")
            case "message_end":
                if event.data and len(event.data) >= 1:
                    data = event.data[0]
                    if isinstance(data, dict) and data.get("role") == "assistant":
                        blocks = data.get("content", [])
                        text_parts = []
                        thinking_parts = []
                        for b in (blocks if isinstance(blocks, list) else []):
                            if b.get("type") == "text":
                                text_parts.append(b.get("text", ""))
                            elif b.get("type") == "thinking":
                                thinking_parts.append(b.get("thinking", ""))
                        if thinking_parts and self._store.state.show_thinking:
                            from lemon_cli.display.panels import render_thinking_panel
                            self.print("\n" + render_thinking_panel("\n".join(thinking_parts), expanded=True))
                        if text_parts:
                            self.print("\n" + "\n".join(text_parts))
            case "tool_execution_start":
                if event.data and len(event.data) >= 2:
                    name = event.data[1]
                    self.print(f"  [tool] {name}...")
            case "tool_execution_end":
                if event.data and len(event.data) >= 3:
                    name = event.data[1]
                    is_error = event.data[3] if len(event.data) >= 4 else False
                    status = "error" if is_error else "done"
                    self.print(f"  [tool] {name} ({status})")

    def _on_error(self, error_msg):
        self._store.set_error(error_msg)
        self.print(f"\n  Error: {error_msg}\n")
        self._invalidate()

    def _on_close(self):
        self.print("\n  Connection closed. Type /quit to exit or /new to reconnect.\n")
        self._invalidate()

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
        from lemon_cli.tui.overlays import handle_ui_request
        result = handle_ui_request(request, self._app)
        if result is not None:
            req_id = request.id if hasattr(request, "id") else request.get("id")
            self._connection.respond_to_ui_request(
                req_id, result.get("result"), result.get("error"))

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
