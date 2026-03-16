import time
from lemon_cli.state.store import AppState
from lemon_cli.theme import get_current_theme, ansi256


def render_status_bar(state: AppState, terminal_width: int = 80) -> str:
    """Render adaptive status bar string."""
    parts = []
    theme = get_current_theme()

    # Busy indicator
    if state.busy:
        parts.append(f"{ansi256(theme.primary)}●\033[0m")

    # Elapsed timer
    if state.busy and state.agent_start_time:
        elapsed = time.monotonic() - state.agent_start_time
        parts.append(f"{ansi256(theme.muted)}Working... {format_duration(elapsed)}\033[0m")
    elif state.tool_working_message:
        parts.append(f"{ansi256(theme.muted)}{state.tool_working_message}\033[0m")

    # Model name
    if state.model:
        model_short = state.model.id.split("/")[-1].split("-")[0:3]
        model_name = "-".join(model_short)
        parts.append(f"{ansi256(theme.secondary)}{model_name}\033[0m")

    # Session indicator (if multi-session)
    session_count = len(state.sessions)
    if session_count > 1 and state.active_session_id:
        sid_short = state.active_session_id[:6]
        parts.append(f"{ansi256(theme.muted)}{sid_short} ({session_count})\033[0m")

    # Compact mode flag
    if state.compact_mode:
        parts.append(f"{ansi256(theme.accent)}[compact]\033[0m")

    # Token usage (if wide enough)
    usage = state.cumulative_usage
    if usage.total_tokens > 0 and terminal_width >= 76:
        token_str = (f"{ansi256(theme.muted)}"
                     f"⬇{format_tokens(usage.input_tokens)} "
                     f"⬆{format_tokens(usage.output_tokens)}\033[0m")
        parts.append(token_str)
        if usage.total_cost > 0:
            parts.append(f"{ansi256(theme.muted)}${usage.total_cost:.2f}\033[0m")

    # Stats (turns, messages)
    if state.stats:
        turns = state.stats.get("turn_count", 0)
        msgs = state.stats.get("message_count", 0)
        parts.append(f"{ansi256(theme.muted)}turns:{turns} msgs:{msgs}\033[0m")

    return " │ ".join(parts)


def format_duration(seconds: float) -> str:
    if seconds < 1:
        return f"{int(seconds * 1000)}ms"
    if seconds < 60:
        return f"{seconds:.1f}s"
    mins = int(seconds // 60)
    secs = int(seconds % 60)
    return f"{mins}m {secs}s"


def format_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)
