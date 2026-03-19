"""Task #10 — extra-python-ws-flags-ignored: WS CLI flags.

--ws-token, --ws-role, --ws-scopes, --ws-client-id must win over config defaults.
"""
import argparse
import pytest
from unittest.mock import patch


def _make_namespace(**kwargs) -> argparse.Namespace:
    ns = argparse.Namespace(**kwargs)
    for attr in ["model", "provider", "base_url", "system_prompt", "session_file",
                 "debug", "lemon_path", "ws_url", "ws_token", "ws_role",
                 "ws_scopes", "ws_client_id", "cwd"]:
        if not hasattr(ns, attr):
            setattr(ns, attr, None)
    return ns


def test_ws_token_cli_wins_over_config():
    """--ws-token CLI flag must override config value."""
    from lemon_cli.config import resolve_config, LemonConfig, ControlPlaneConfig

    cfg = LemonConfig()
    cfg.control_plane = ControlPlaneConfig(token="config-token")

    args = _make_namespace(ws_token="cli-token")

    with patch("lemon_cli.config.load_config", return_value=cfg):
        result = resolve_config(cli_args=args)

    assert result.ws_token == "cli-token", (
        f"Expected 'cli-token', got: {result.ws_token!r}"
    )


def test_ws_role_cli_wins_over_config():
    """--ws-role CLI flag must override config value."""
    from lemon_cli.config import resolve_config, LemonConfig, ControlPlaneConfig

    cfg = LemonConfig()
    cfg.control_plane = ControlPlaneConfig(role="config-role")

    args = _make_namespace(ws_role="cli-role")

    with patch("lemon_cli.config.load_config", return_value=cfg):
        result = resolve_config(cli_args=args)

    assert result.ws_role == "cli-role", (
        f"Expected 'cli-role', got: {result.ws_role!r}"
    )


def test_ws_scopes_cli_wins_over_config():
    """--ws-scopes CLI flag must override config value."""
    from lemon_cli.config import resolve_config, LemonConfig, ControlPlaneConfig

    cfg = LemonConfig()
    cfg.control_plane = ControlPlaneConfig(scopes=["config.read"])

    args = _make_namespace(ws_scopes="cli.read,cli.write")

    with patch("lemon_cli.config.load_config", return_value=cfg):
        result = resolve_config(cli_args=args)

    assert result.ws_scopes == ["cli.read", "cli.write"], (
        f"Expected ['cli.read', 'cli.write'], got: {result.ws_scopes!r}"
    )


def test_ws_client_id_cli_wins_over_config():
    """--ws-client-id CLI flag must override config value."""
    from lemon_cli.config import resolve_config, LemonConfig, ControlPlaneConfig

    cfg = LemonConfig()
    cfg.control_plane = ControlPlaneConfig(client_id="config-client")

    args = _make_namespace(ws_client_id="cli-client")

    with patch("lemon_cli.config.load_config", return_value=cfg):
        result = resolve_config(cli_args=args)

    assert result.ws_client_id == "cli-client", (
        f"Expected 'cli-client', got: {result.ws_client_id!r}"
    )


def test_all_ws_flags_together():
    """All four WS flags together must all win over empty config."""
    from lemon_cli.config import resolve_config, LemonConfig

    cfg = LemonConfig()
    args = _make_namespace(
        ws_token="t",
        ws_role="r",
        ws_scopes="s1,s2",
        ws_client_id="c",
    )

    with patch("lemon_cli.config.load_config", return_value=cfg):
        result = resolve_config(cli_args=args)

    assert result.ws_token == "t"
    assert result.ws_role == "r"
    assert result.ws_scopes == ["s1", "s2"]
    assert result.ws_client_id == "c"


def test_tui_thinking_flag_is_loaded_from_config():
    """[tui].thinking must control initial reasoning visibility."""
    from lemon_cli.config import resolve_config, LemonConfig, TUIConfig

    cfg = LemonConfig()
    cfg.tui = TUIConfig(thinking=True)
    args = _make_namespace()

    with patch("lemon_cli.config.load_config", return_value=cfg):
        result = resolve_config(cli_args=args)

    assert result.show_thinking is True
