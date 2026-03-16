from lemon_cli.commands.registry import SlashCommand


def register_session_commands(registry, app):
    registry.register(SlashCommand("/sessions", [], "List saved sessions",
                                    lambda args: cmd_sessions(app, args)))
    registry.register(SlashCommand("/running", [], "List running sessions",
                                    lambda args: cmd_running(app, args)))
    registry.register(SlashCommand("/switch", [], "Switch active session (usage: /switch <id>)",
                                    lambda args: cmd_switch(app, args)))
    registry.register(SlashCommand("/close", [], "Close current or specified session",
                                    lambda args: cmd_close(app, args)))
    registry.register(SlashCommand("/resume", [], "Resume a saved session (usage: /resume <id>)",
                                    lambda args: cmd_resume(app, args)))


def cmd_sessions(app, args):
    app._connection.list_sessions()
    return True


def cmd_running(app, args):
    app._connection.list_running_sessions()
    return True


def cmd_switch(app, args):
    from lemon_cli.display.console import cprint
    if args:
        app._connection.set_active_session(args[0])
    else:
        cprint("  Usage: /switch <session_id>")
    return True


def cmd_close(app, args):
    if args:
        session_id = args[0]
    else:
        session_id = app._store.state.active_session_id
    if session_id:
        app._connection.close_session(session_id)
    else:
        from lemon_cli.display.console import cprint
        cprint("  No active session to close")
    return True


def cmd_resume(app, args):
    from lemon_cli.display.console import cprint
    if args:
        app._connection.start_session(session_file=args[0])
    else:
        cprint("  Usage: /resume <session_file>")
    return True
