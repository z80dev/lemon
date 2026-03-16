"""Task #9 — extra-python-ws-config-shape-bug: ws_scopes shape.

ws_scopes may arrive as a list (from TOML) or string (from env/CLI).
The code must handle both without crashing.
"""
import argparse
import pytest


def _make_namespace(**kwargs) -> argparse.Namespace:
    ns = argparse.Namespace(**kwargs)
    # Set defaults for required attributes
    for attr in ["model", "provider", "base_url", "system_prompt", "session_file",
                 "debug", "lemon_path", "ws_url", "ws_token", "ws_role",
                 "ws_scopes", "ws_client_id", "cwd"]:
        if not hasattr(ns, attr):
            setattr(ns, attr, None)
    return ns


def test_ws_scopes_as_list_does_not_crash():
    """resolve_config must not crash when control_plane.scopes is a list."""
    from unittest.mock import patch
    from lemon_cli.config import resolve_config, LemonConfig, ControlPlaneConfig

    cfg = LemonConfig()
    cfg.control_plane = ControlPlaneConfig(scopes=["operator.read", "operator.write"])

    with patch("lemon_cli.config.load_config", return_value=cfg):
        result = resolve_config()

    assert result.ws_scopes == ["operator.read", "operator.write"], (
        f"Expected list, got: {result.ws_scopes}"
    )


def test_ws_scopes_as_string_splits_to_list():
    """resolve_config must split a comma-separated string into a list."""
    from unittest.mock import patch
    from lemon_cli.config import resolve_config, LemonConfig, ControlPlaneConfig

    cfg = LemonConfig()
    cfg.control_plane = ControlPlaneConfig(scopes="operator.read,operator.write")

    with patch("lemon_cli.config.load_config", return_value=cfg):
        result = resolve_config()

    assert result.ws_scopes == ["operator.read", "operator.write"], (
        f"Expected split list, got: {result.ws_scopes}"
    )


def test_ws_scopes_none_stays_none():
    """When scopes not configured, ws_scopes should be None."""
    from unittest.mock import patch
    from lemon_cli.config import resolve_config, LemonConfig

    cfg = LemonConfig()

    with patch("lemon_cli.config.load_config", return_value=cfg):
        result = resolve_config()

    assert result.ws_scopes is None


def test_cli_scopes_string_splits_to_list():
    """CLI --ws-scopes 'a,b' must yield list ['a', 'b'] in resolved config."""
    from unittest.mock import patch
    from lemon_cli.config import resolve_config, LemonConfig

    cfg = LemonConfig()
    args = _make_namespace(ws_scopes="a.read,b.write")

    with patch("lemon_cli.config.load_config", return_value=cfg):
        result = resolve_config(cli_args=args)

    assert result.ws_scopes == ["a.read", "b.write"], (
        f"Expected ['a.read', 'b.write'], got: {result.ws_scopes}"
    )


def test_cli_into_websocket_connection_no_crash():
    """The path through cli.py that creates WebSocketConnection must not crash."""
    from unittest.mock import patch
    from lemon_cli.config import resolve_config, LemonConfig, ControlPlaneConfig

    cfg = LemonConfig()
    cfg.control_plane = ControlPlaneConfig(
        ws_url="ws://localhost:4040/ws",
        scopes=["operator.read"],
    )

    with patch("lemon_cli.config.load_config", return_value=cfg):
        result = resolve_config()

    from lemon_cli.connection.websocket import WebSocketConnection
    conn = WebSocketConnection(
        ws_url=result.ws_url,
        token=result.ws_token,
        role=result.ws_role,
        scopes=result.ws_scopes,  # must be list or None, not string
        client_id=result.ws_client_id,
    )
    # scopes should be stored as a list
    assert conn._scopes == ["operator.read"], f"Expected list scopes, got: {conn._scopes}"
