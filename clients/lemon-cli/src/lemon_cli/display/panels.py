from rich.panel import Panel
from rich.markdown import Markdown
from rich.text import Text
from lemon_cli.theme import get_current_theme, rich_color
from lemon_cli.display.console import render_to_ansi


def render_user_message(msg) -> str:
    """Render user message as Rich Panel ANSI string."""
    theme = get_current_theme()
    panel = Panel(
        Text(msg.content),
        title="You",
        title_align="left",
        border_style=f"{rich_color(theme.muted)}",
        padding=(0, 1),
    )
    return render_to_ansi(panel)


def render_assistant_message(msg, compact: bool = False) -> str:
    """Render assistant message as Rich Panel with markdown."""
    theme = get_current_theme()

    # Main content as markdown
    content = Markdown(msg.text_content) if msg.text_content else Text("")

    # Usage footer
    footer = ""
    if msg.usage and not msg.is_streaming:
        u = msg.usage
        footer = (f" \u2b07{_fmt_tokens(u.get('input_tokens', 0))} "
                  f"\u2b06{_fmt_tokens(u.get('output_tokens', 0))}")
        cost = u.get("total_cost", 0)
        if cost > 0:
            footer += f" ${cost:.4f}"

    # Model subtitle
    model_name = msg.model.split("/")[-1] if msg.model else ""
    subtitle = f"{model_name}{footer}" if model_name or footer else None

    panel = Panel(
        content,
        title="Lemon",
        title_align="left",
        subtitle=subtitle,
        subtitle_align="right",
        border_style=f"{rich_color(theme.primary)}",
        padding=(0, 1),
    )
    return render_to_ansi(panel)


def render_thinking_panel(thinking_content: str, expanded: bool = False) -> str:
    """Render thinking/reasoning in a dimmed panel."""
    theme = get_current_theme()
    if not expanded:
        preview = thinking_content[:100] + "..." if len(thinking_content) > 100 else thinking_content
        text = Text(f"\U0001f4ad {preview}", style=f"{rich_color(theme.dim)}")
    else:
        text = Text(thinking_content, style=f"{rich_color(theme.dim)}")

    panel = Panel(
        text,
        title="Thinking",
        title_align="left",
        border_style=f"{rich_color(theme.dim)}",
        padding=(0, 1),
    )
    return render_to_ansi(panel)


def render_tool_result(msg, formatter_registry=None) -> str:
    """Render tool result message."""
    theme = get_current_theme()
    style = f"{rich_color(theme.error)}" if msg.is_error else f"{rich_color(theme.muted)}"

    if formatter_registry:
        formatted = formatter_registry.format_result(msg.tool_name, msg.content)
        text = Text(formatted.summary)
    else:
        text = Text(msg.content[:200])

    return render_to_ansi(Panel(
        text,
        title=f"Tool: {msg.tool_name}",
        title_align="left",
        border_style=style,
        padding=(0, 1),
    ))


def _fmt_tokens(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M"
    if n >= 1_000:
        return f"{n / 1_000:.1f}k"
    return str(n)
