from lemon_cli.commands.registry import SlashCommand


def register_ui_commands(registry, app):
    registry.register(SlashCommand("/retry", [], "Re-send last user message",
                                    lambda args: cmd_retry(app, args)))
    registry.register(SlashCommand("/undo", [], "Remove last user/assistant exchange",
                                    lambda args: cmd_undo(app, args)))
    registry.register(SlashCommand("/rollback", [], "Rollback to a previous point",
                                    lambda args: cmd_rollback(app, args)))
    registry.register(SlashCommand("/compact", [], "Toggle compact display mode",
                                    lambda args: cmd_compact(app, args)))
    registry.register(SlashCommand("/thinking", [], "Toggle thinking/reasoning panel",
                                    lambda args: cmd_thinking(app, args)))


def cmd_retry(app, args):
    """Re-send last user message."""
    for msg in reversed(app._store.state.messages):
        if msg.type == "user":
            app._connection.prompt(msg.content, app._store.state.active_session_id)
            return True
    app.print("  No user message to retry")
    return True


def cmd_undo(app, args):
    """Remove last exchange (reset + replay all but last user msg)."""
    messages = app._store.state.messages
    # Find last user message index
    last_user_idx = None
    for i in range(len(messages) - 1, -1, -1):
        if messages[i].type == "user":
            last_user_idx = i
            break
    if last_user_idx is None:
        app.print("  Nothing to undo")
        return True
    app._connection.reset(app._store.state.active_session_id)
    # Replay all user messages up to (not including) the last one
    for msg in messages[:last_user_idx]:
        if msg.type == "user":
            app._connection.prompt(msg.content, app._store.state.active_session_id)
    return True


def cmd_rollback(app, args):
    """Rollback to a previous point in the conversation."""
    from lemon_cli.display.console import cprint
    cprint("  Rollback: use /undo to remove the last exchange")
    return True


def cmd_compact(app, args):
    app._store.toggle_compact_mode()
    mode = "on" if app._store.state.compact_mode else "off"
    app.print(f"  Compact mode: {mode}")
    return True


def cmd_thinking(app, args):
    """Toggle thinking panel visibility."""
    app._store.toggle_thinking_visibility()
    mode = "on" if app._store.state.show_thinking else "off"
    app.print(f"  Thinking display: {mode}")
    return True
