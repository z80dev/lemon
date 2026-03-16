import threading
import time
from lemon_cli.constants import SPINNER_FRAMES, TOOL_EMOJIS, TOOL_VERBS


class Spinner:
    """Animated spinner for tool execution progress."""

    def __init__(self):
        self._frame_idx = 0
        self._message = ""
        self._tool_name = ""
        self._start_time = 0.0
        self._lock = threading.Lock()
        self._above_lines: list[str] = []

    def advance(self):
        with self._lock:
            self._frame_idx = (self._frame_idx + 1) % len(SPINNER_FRAMES)

    def set_tool(self, name: str, preview: str = ""):
        with self._lock:
            self._tool_name = name
            self._message = preview
            self._start_time = time.monotonic()

    def clear(self):
        with self._lock:
            self._tool_name = ""
            self._message = ""

    def print_above(self, text: str):
        """Queue a line to print above spinner (for tool completion messages)."""
        with self._lock:
            self._above_lines.append(text)

    def drain_above(self) -> list[str]:
        with self._lock:
            lines = self._above_lines[:]
            self._above_lines.clear()
            return lines

    def render(self) -> str:
        with self._lock:
            frame = SPINNER_FRAMES[self._frame_idx]
            elapsed = time.monotonic() - self._start_time if self._start_time else 0
            if self._tool_name:
                return f" {frame} {self._tool_name} {self._message} ({elapsed:.1f}s)"
            return f" {frame} Working... ({elapsed:.1f}s)"

    @staticmethod
    def format_tool_completion(name: str, args: dict, elapsed: float,
                                is_error: bool = False) -> str:
        """Format a tool completion line: | emoji verb detail duration"""
        emoji = TOOL_EMOJIS.get(name, "⚡")
        verb = TOOL_VERBS.get(name, "ran")
        detail = _build_tool_preview(name, args)
        duration = f"{elapsed:.1f}s"
        prefix = "│"
        return f" {prefix} {emoji} {verb:9} {detail}  {duration}"


def _build_tool_preview(name: str, args: dict) -> str:
    """Context-aware one-liner from tool args."""
    if name in ("bash", "terminal"):
        return _truncate(args.get("command", ""), 60)
    if name in ("read", "read_file"):
        return _truncate(args.get("file_path", args.get("path", "")), 60)
    if name in ("write", "write_file"):
        return _truncate(args.get("file_path", args.get("path", "")), 60)
    if name in ("edit", "edit_file"):
        return _truncate(args.get("file_path", args.get("path", "")), 60)
    if name in ("grep", "search"):
        return _truncate(args.get("pattern", args.get("query", "")), 60)
    if name in ("glob", "find"):
        return _truncate(args.get("pattern", args.get("path", "")), 60)
    if name in ("web_search", "websearch"):
        return _truncate(args.get("query", ""), 60)
    if name in ("web_fetch", "webfetch"):
        return _truncate(args.get("url", ""), 60)
    # Generic: first string value
    for v in args.values():
        if isinstance(v, str) and v:
            return _truncate(v, 60)
    return ""


def _truncate(text: str, max_len: int) -> str:
    if len(text) <= max_len:
        return text
    return text[:max_len - 3] + "..."
