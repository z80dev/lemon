import argparse
import os
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Lemon Agent CLI/TUI")

    parser.add_argument("--cwd", "-d", default=os.getcwd(), help="Working directory")
    parser.add_argument("--model", "-m", help="Model spec (provider:model_id)")
    parser.add_argument("--provider", "-p", help="Default LLM provider")
    parser.add_argument("--base-url", dest="base_url", help="Custom API base URL")
    parser.add_argument("--system-prompt", dest="system_prompt", help="Custom system prompt")
    parser.add_argument("--session-file", dest="session_file", help="Resume specific session file")
    parser.add_argument("--debug", action="store_true", help="Debug mode")
    parser.add_argument("--no-ui", dest="no_ui", action="store_true", help="Headless mode")
    parser.add_argument("--skin", help="Theme name")

    # WebSocket options
    parser.add_argument("--ws-url", dest="ws_url", help="WebSocket URL for control plane")
    parser.add_argument("--ws-token", dest="ws_token", help="WebSocket auth token")
    parser.add_argument("--ws-role", dest="ws_role", help="WebSocket role")
    parser.add_argument("--ws-scopes", dest="ws_scopes", help="WebSocket scopes (comma-separated)")
    parser.add_argument("--ws-client-id", dest="ws_client_id", help="WebSocket client ID")

    # Path
    parser.add_argument("--lemon-path", dest="lemon_path", help="Path to lemon repo root")

    return parser.parse_args()


def main():
    args = parse_args()

    from lemon_cli.config import resolve_config
    config = resolve_config(args)

    # Apply theme
    from lemon_cli.theme import set_theme
    if args.skin:
        set_theme(args.skin)
    elif config.theme:
        set_theme(config.theme)

    # Select connection mode
    if config.ws_url:
        from lemon_cli.connection.websocket import WebSocketConnection
        connection = WebSocketConnection(
            ws_url=config.ws_url,
            token=config.ws_token,
            role=config.ws_role,
            scopes=config.ws_scopes,
            client_id=config.ws_client_id,
        )
    else:
        from lemon_cli.connection.rpc import RPCConnection
        # Model may already be "provider:model" format; avoid double-prefixing
        model_spec = config.model if ":" in config.model else f"{config.provider}:{config.model}"
        connection = RPCConnection(
            cwd=config.cwd,
            model=model_spec,
            lemon_path=config.lemon_path,
            system_prompt=config.system_prompt,
            session_file=config.session_file,
            debug=config.debug,
            ui=not args.no_ui,
        )

    # Create state store
    from lemon_cli.state.store import StateStore
    store = StateStore(cwd=config.cwd)

    # Create and run app
    from lemon_cli.tui.app import LemonApp
    app = LemonApp(connection=connection, config=config, store=store)

    try:
        app.run()
    except KeyboardInterrupt:
        pass
    finally:
        # Cleanup
        import asyncio
        try:
            loop = asyncio.new_event_loop()
            loop.run_until_complete(connection.stop())
            loop.close()
        except Exception:
            pass


if __name__ == "__main__":
    main()
