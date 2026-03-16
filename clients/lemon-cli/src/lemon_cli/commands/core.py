from lemon_cli.commands.registry import SlashCommand


def register_core_commands(registry, app):
    registry.register(SlashCommand("/help", [], "Show available commands",
                                    lambda args: cmd_help(app, args)))
    registry.register(SlashCommand("/quit", ["/exit", "/q"], "Exit lemon-cli",
                                    lambda args: False))
    registry.register(SlashCommand("/new", [], "Start a new session",
                                    lambda args: cmd_new(app, args)))
    registry.register(SlashCommand("/model", [], "Show or switch model (usage: /model [provider:model])",
                                    lambda args: cmd_model(app, args)))
    registry.register(SlashCommand("/clear", [], "Clear display and reset session",
                                    lambda args: cmd_clear(app, args)))
    registry.register(SlashCommand("/reset", [], "Reset the current session",
                                    lambda args: cmd_reset(app, args)))
    registry.register(SlashCommand("/save", [], "Save the current session",
                                    lambda args: cmd_save(app, args)))
    registry.register(SlashCommand("/usage", [], "Show token usage and cost",
                                    lambda args: cmd_usage(app, args)))
    registry.register(SlashCommand("/config", [], "Show or edit configuration",
                                    lambda args: cmd_config(app, args)))
    registry.register(SlashCommand("/skin", [], "Show or switch theme (usage: /skin [name])",
                                    lambda args: cmd_skin(app, args)))
    registry.register(SlashCommand("/stop", ["/abort"], "Abort the running agent",
                                    lambda args: cmd_stop(app, args)))
    registry.register(SlashCommand("/history", [], "List saved sessions",
                                    lambda args: cmd_history(app, args)))


def cmd_help(app, args):
    """Print all available commands grouped by category."""
    from lemon_cli.display.console import cprint
    cprint("\n  Available Commands:\n")
    for name, desc in app._command_registry.get_commands_with_descriptions():
        cprint(f"    {name:16} {desc}")
    cprint("")
    return True


def cmd_usage(app, args):
    usage = app._store.state.cumulative_usage
    from lemon_cli.display.console import cprint
    cprint(f"\n  {usage.format_summary()}\n")
    return True


def cmd_skin(app, args):
    from lemon_cli.theme import set_theme, get_current_theme, get_available_themes
    from lemon_cli.display.console import cprint
    if not args:
        current = get_current_theme()
        available = get_available_themes()
        cprint(f"  Current: {current.name}  Available: {', '.join(available)}")
        return True
    if set_theme(args[0]):
        cprint(f"  Switched to {args[0]} theme")
    else:
        cprint(f"  Unknown theme: {args[0]}")
    return True


def cmd_stop(app, args):
    app._connection.abort(app._store.state.active_session_id)
    return True


def cmd_model(app, args):
    from lemon_cli.display.console import cprint
    if not args:
        model = app._store.state.model
        if model:
            cprint(f"  Current model: {model.provider}:{model.id}")
        else:
            cprint("  No model set")
        return True
    # Request model list or switch
    app._connection.list_models()
    return True


def cmd_new(app, args):
    app._connection.start_session(cwd=app._store.state.cwd)
    return True


def cmd_reset(app, args):
    app._connection.reset(app._store.state.active_session_id)
    return True


def cmd_save(app, args):
    app._connection.save(app._store.state.active_session_id)
    return True


def cmd_clear(app, args):
    import os
    os.system("clear")
    return True


def cmd_history(app, args):
    app._connection.list_sessions()
    return True


def cmd_config(app, args):
    from lemon_cli.display.console import cprint
    from lemon_cli.config import load_config
    config = load_config(app._store.state.cwd)
    cprint(f"  Provider: {config.agent.default_provider}")
    cprint(f"  Model: {config.agent.default_model}")
    cprint(f"  Theme: {config.tui.theme}")
    return True
