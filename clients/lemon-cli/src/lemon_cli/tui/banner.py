from lemon_cli.theme import get_lemon_art, ansi256, ThemeColors


def print_banner(state, theme: ThemeColors | None = None):
    """Print the welcome banner with lemon ASCII art, version, and model info."""
    from lemon_cli.theme import get_current_theme
    from lemon_cli.display.console import cprint

    t = theme or get_current_theme()

    art = get_lemon_art(t)
    cprint(art)

    version_line = f"{ansi256(t.primary)}lemon-cli v0.1.0\033[0m"
    cprint(f"  {version_line}")

    if state and state.model:
        model_str = f"{state.model.provider}:{state.model.id}"
        cprint(f"  {ansi256(t.muted)}Model: {ansi256(t.secondary)}{model_str}\033[0m")

    cprint(f"  {ansi256(t.muted)}Type /help for available commands\033[0m")
    cprint("")
