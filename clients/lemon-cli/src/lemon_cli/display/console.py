from io import StringIO
from rich.console import Console
from rich.theme import Theme as RichTheme
from lemon_cli.theme import get_current_theme, rich_color


def get_rich_console(width: int | None = None) -> Console:
    """Create a Rich Console configured for the current theme."""
    theme = get_current_theme()
    rich_theme = RichTheme({
        "info": f"{rich_color(theme.primary)}",
        "success": f"{rich_color(theme.success)}",
        "warning": f"{rich_color(theme.warning)}",
        "error": f"{rich_color(theme.error)} bold",
        "muted": f"{rich_color(theme.muted)}",
        "accent": f"{rich_color(theme.accent)}",
    })
    return Console(theme=rich_theme, width=width, force_terminal=True)


def render_to_ansi(renderable) -> str:
    """Render a Rich object to an ANSI string."""
    sio = StringIO()
    console = Console(file=sio, force_terminal=True, no_color=False)
    console.print(renderable, highlight=False)
    return sio.getvalue()


def cprint(text: str):
    """Append text to the output buffer (visible in the TUI output pane)."""
    from lemon_cli.tui.layout import append_output
    # Strip ANSI for buffer (BufferControl doesn't render ANSI escapes)
    import re
    clean = re.sub(r'\033\[[0-9;]*m', '', text)
    append_output(clean)


def cprint_rich(renderable):
    """Print a Rich renderable to the output buffer."""
    ansi_str = render_to_ansi(renderable)
    cprint(ansi_str)
