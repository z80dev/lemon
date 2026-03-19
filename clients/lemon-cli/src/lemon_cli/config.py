"""Config loading & resolution for lemon-cli.

Port of clients/lemon-tui/src/config.ts.
Loads ~/.lemon/config.toml and ./.lemon/config.toml, deep-merges them,
then resolves final values using env vars and CLI args.

Relevant `[tui]` keys for the Python client:
- `theme`
- `debug`
- `compact`
- `timestamps`
- `bell`
- `thinking` (show assistant reasoning blocks when available)
"""
from __future__ import annotations

import argparse
import os
from dataclasses import dataclass, field
from pathlib import Path


# ---------------------------------------------------------------------------
# Config dataclasses
# ---------------------------------------------------------------------------

@dataclass
class ProviderConfig:
    api_key: str | None = None
    base_url: str | None = None

    @classmethod
    def from_dict(cls, data: dict) -> "ProviderConfig":
        return cls(
            api_key=data.get("api_key"),
            base_url=data.get("base_url"),
        )


@dataclass
class AgentConfig:
    default_provider: str = "anthropic"
    default_model: str = "claude-sonnet-4-20250514"

    @classmethod
    def from_dict(cls, data: dict) -> "AgentConfig":
        return cls(
            default_provider=data.get("default_provider", "anthropic"),
            default_model=data.get("default_model", "claude-sonnet-4-20250514"),
        )


@dataclass
class TUIConfig:
    theme: str = "lemon"
    debug: bool = False
    bell: bool = True
    compact: bool = False
    timestamps: bool = False
    thinking: bool = False

    @classmethod
    def from_dict(cls, data: dict) -> "TUIConfig":
        return cls(
            theme=data.get("theme", "lemon"),
            debug=bool(data.get("debug", False)),
            bell=bool(data.get("bell", True)),
            compact=bool(data.get("compact", False)),
            timestamps=bool(data.get("timestamps", False)),
            thinking=bool(data.get("thinking", False)),
        )


@dataclass
class ControlPlaneConfig:
    ws_url: str | None = None
    token: str | None = None
    role: str | None = None
    scopes: list[str] | None = None
    client_id: str | None = None

    @classmethod
    def from_dict(cls, data: dict) -> "ControlPlaneConfig":
        return cls(
            ws_url=data.get("ws_url"),
            token=data.get("token"),
            role=data.get("role"),
            scopes=data.get("scopes"),
            client_id=data.get("client_id"),
        )


@dataclass
class LemonConfig:
    providers: dict[str, ProviderConfig] = field(default_factory=dict)
    agent: AgentConfig = field(default_factory=AgentConfig)
    tui: TUIConfig = field(default_factory=TUIConfig)
    control_plane: ControlPlaneConfig = field(default_factory=ControlPlaneConfig)

    @classmethod
    def from_dict(cls, data: dict) -> "LemonConfig":
        providers_raw = data.get("providers") or {}
        providers = {k: ProviderConfig.from_dict(v) for k, v in providers_raw.items()}
        # Support both [agent] (legacy) and [defaults] (current) sections
        agent_raw = data.get("agent") or {}
        defaults_raw = data.get("defaults") or {}
        agent_merged = {
            "default_provider": defaults_raw.get("provider") or agent_raw.get("default_provider"),
            "default_model": defaults_raw.get("model") or agent_raw.get("default_model"),
        }
        return cls(
            providers=providers,
            agent=AgentConfig.from_dict(agent_merged),
            tui=TUIConfig.from_dict(data.get("tui") or {}),
            control_plane=ControlPlaneConfig.from_dict(data.get("control_plane") or {}),
        )


@dataclass
class ResolvedConfig:
    provider: str
    model: str
    api_key: str | None
    base_url: str | None
    cwd: str
    theme: str
    debug: bool
    compact: bool
    bell: bool
    timestamps: bool
    show_thinking: bool
    system_prompt: str | None
    session_file: str | None
    lemon_path: str | None
    ws_url: str | None
    ws_token: str | None
    ws_role: str | None
    ws_scopes: list[str] | None
    ws_client_id: str | None


# ---------------------------------------------------------------------------
# TOML loading helpers
# ---------------------------------------------------------------------------

def _load_toml(path: Path) -> dict:
    """Load a TOML file, returning empty dict if not found."""
    if not path.exists():
        return {}
    import tomllib  # stdlib in Python 3.11+
    try:
        with open(path, "rb") as f:
            return tomllib.load(f)
    except Exception:
        return {}


def _deep_merge(base: dict, override: dict) -> dict:
    """Recursively merge override into base. override values take precedence."""
    result = dict(base)
    for key, value in override.items():
        if key in result and isinstance(result[key], dict) and isinstance(value, dict):
            result[key] = _deep_merge(result[key], value)
        else:
            result[key] = value
    return result


# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

def load_config(cwd: str | None = None) -> LemonConfig:
    """Load and merge global + project config files."""
    global_path = Path.home() / ".lemon" / "config.toml"
    project_path = Path(cwd or ".") / ".lemon" / "config.toml"

    global_config = _load_toml(global_path)
    project_config = _load_toml(project_path)
    merged = _deep_merge(global_config, project_config)
    return LemonConfig.from_dict(merged)


# ---------------------------------------------------------------------------
# Provider env prefix mapping
# ---------------------------------------------------------------------------

_PROVIDER_ENV_PREFIXES: dict[str, str] = {
    "anthropic": "ANTHROPIC",
    "openai": "OPENAI",
    "google": "GOOGLE",
    "groq": "GROQ",
    "mistral": "MISTRAL",
    "cohere": "COHERE",
    "together": "TOGETHER",
    "deepseek": "DEEPSEEK",
    "xai": "XAI",
}


def _provider_env_prefix(provider: str) -> str:
    """Map provider name to env var prefix."""
    return _PROVIDER_ENV_PREFIXES.get(provider.lower(), provider.upper())


# ---------------------------------------------------------------------------
# Model spec parsing
# ---------------------------------------------------------------------------

def parse_model_spec(spec: str) -> tuple[str, str]:
    """Parse 'provider:model_id' -> (provider, model_id).

    If no colon, assumes anthropic as default provider.
    """
    if ":" in spec:
        provider, model_id = spec.split(":", 1)
        return provider.strip(), model_id.strip()
    return "anthropic", spec.strip()


# ---------------------------------------------------------------------------
# Config resolution
# ---------------------------------------------------------------------------

def resolve_config(
    cli_args: argparse.Namespace | None = None,
    cwd: str | None = None,
) -> ResolvedConfig:
    """Resolve final config from config file + env vars + CLI args.

    Precedence (highest to lowest):
      CLI args > env vars > project config > global config > defaults
    """
    resolved_cwd = cwd or (getattr(cli_args, "cwd", None) if cli_args else None) or os.getcwd()
    config = load_config(resolved_cwd)

    # Provider + model
    model_spec = getattr(cli_args, "model", None) if cli_args else None
    if model_spec and ":" in model_spec:
        cli_provider, cli_model = parse_model_spec(model_spec)
    else:
        cli_provider = getattr(cli_args, "provider", None) if cli_args else None
        cli_model = model_spec

    provider = (
        cli_provider
        or os.environ.get("LEMON_DEFAULT_PROVIDER")
        or config.agent.default_provider
        or "anthropic"
    )

    model = (
        cli_model
        or os.environ.get("LEMON_DEFAULT_MODEL")
        or config.agent.default_model
        or "claude-sonnet-4-20250514"
    )

    # API key + base URL (provider-specific env prefix)
    env_prefix = _provider_env_prefix(provider)
    provider_cfg = config.providers.get(provider, ProviderConfig())

    cli_base_url = getattr(cli_args, "base_url", None) if cli_args else None
    api_key = (
        os.environ.get(f"{env_prefix}_API_KEY")
        or provider_cfg.api_key
    )
    base_url = (
        cli_base_url
        or os.environ.get(f"{env_prefix}_BASE_URL")
        or provider_cfg.base_url
    )

    # Theme
    theme = (
        os.environ.get("LEMON_THEME")
        or config.tui.theme
        or "lemon"
    )

    # Debug
    cli_debug = getattr(cli_args, "debug", False) if cli_args else False
    debug = cli_debug or config.tui.debug or bool(os.environ.get("LEMON_DEBUG"))

    compact = config.tui.compact
    bell = config.tui.bell
    timestamps = config.tui.timestamps
    show_thinking = config.tui.thinking

    # System prompt
    system_prompt = getattr(cli_args, "system_prompt", None) if cli_args else None
    if system_prompt is None:
        sp_file = os.environ.get("LEMON_SYSTEM_PROMPT_FILE")
        if sp_file and Path(sp_file).exists():
            system_prompt = Path(sp_file).read_text()

    # Session file
    session_file = getattr(cli_args, "session_file", None) if cli_args else None

    # Lemon path
    lemon_path = (
        (getattr(cli_args, "lemon_path", None) if cli_args else None)
        or os.environ.get("LEMON_PATH")
    )

    # WebSocket / control plane
    cli_ws_url = getattr(cli_args, "ws_url", None) if cli_args else None
    ws_url = (
        cli_ws_url
        or os.environ.get("LEMON_WS_URL")
        or config.control_plane.ws_url
    )
    cli_ws_token = getattr(cli_args, "ws_token", None) if cli_args else None
    ws_token = (
        cli_ws_token
        or os.environ.get("LEMON_WS_TOKEN")
        or config.control_plane.token
    )
    cli_ws_role = getattr(cli_args, "ws_role", None) if cli_args else None
    ws_role = (
        cli_ws_role
        or os.environ.get("LEMON_WS_ROLE")
        or config.control_plane.role
    )

    # Normalize ws_scopes to list[str] | None regardless of source shape
    cli_ws_scopes = getattr(cli_args, "ws_scopes", None) if cli_args else None
    _raw_scopes = (
        cli_ws_scopes
        or config.control_plane.scopes
    )
    if _raw_scopes is None:
        ws_scopes: list[str] | None = None
    elif isinstance(_raw_scopes, list):
        ws_scopes = _raw_scopes
    else:
        ws_scopes = [s.strip() for s in str(_raw_scopes).split(",") if s.strip()]

    cli_ws_client_id = getattr(cli_args, "ws_client_id", None) if cli_args else None
    ws_client_id = (
        cli_ws_client_id
        or os.environ.get("LEMON_WS_CLIENT_ID")
        or config.control_plane.client_id
    )

    return ResolvedConfig(
        provider=provider,
        model=model,
        api_key=api_key,
        base_url=base_url,
        cwd=resolved_cwd,
        theme=theme,
        debug=debug,
        compact=compact,
        bell=bell,
        timestamps=timestamps,
        show_thinking=show_thinking,
        system_prompt=system_prompt,
        session_file=session_file,
        lemon_path=lemon_path,
        ws_url=ws_url,
        ws_token=ws_token,
        ws_role=ws_role,
        ws_scopes=ws_scopes,
        ws_client_id=ws_client_id,
    )
