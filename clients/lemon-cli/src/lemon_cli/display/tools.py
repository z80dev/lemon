from lemon_cli.constants import TOOL_EMOJIS, TOOL_VERBS
from lemon_cli.theme import get_current_theme, ansi256


def render_tool_start(name: str, args: dict) -> str:
    """Return formatted tool start line."""
    theme = get_current_theme()
    emoji = TOOL_EMOJIS.get(name.lower(), "\u2699\ufe0f")
    color = ansi256(theme.muted)
    reset = "\033[0m"
    arg_preview = _args_preview(args)
    return f"{color}{emoji} {name}{arg_preview}...{reset}"


def render_tool_end(name: str, args: dict, elapsed: float, is_error: bool = False) -> str:
    """Return formatted tool completion line."""
    theme = get_current_theme()
    emoji = TOOL_EMOJIS.get(name.lower(), "\u2699\ufe0f")
    verb = TOOL_VERBS.get(name.lower(), "ran")
    color = ansi256(theme.error if is_error else theme.success)
    muted = ansi256(theme.muted)
    reset = "\033[0m"
    arg_preview = _args_preview(args)
    elapsed_str = _fmt_elapsed(elapsed)
    status = " \u2717" if is_error else " \u2713"
    return f"{color}{emoji} {verb}{arg_preview}{status}{muted} ({elapsed_str}){reset}"


def _args_preview(args: dict) -> str:
    """Extract short preview from tool args."""
    if not args:
        return ""
    # Try common arg keys for a short preview
    for key in ("file_path", "path", "pattern", "command", "query", "url"):
        val = args.get(key)
        if val and isinstance(val, str):
            short = val if len(val) <= 40 else "..." + val[-37:]
            return f" {short}"
    return ""


def _fmt_elapsed(seconds: float) -> str:
    if seconds < 1:
        return f"{int(seconds * 1000)}ms"
    return f"{seconds:.1f}s"
