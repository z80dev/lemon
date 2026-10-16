"""Factory-local decision configuration; no credentials or execution authority."""
from __future__ import annotations

import math
from dataclasses import dataclass, field
from types import MappingProxyType
from typing import Mapping

MODEL = "cloudflare/clef-flash"
ENDPOINT = "https://openrouter.ai/api/v1/systemone"
TIERS = ("simple", "standard", "complex", "insufficient_information")


class ConfigError(ValueError):
    """Only constant messages are used: configuration can contain private data."""


@dataclass(frozen=True)
class DecisionConfig:
    enabled: bool = True
    mode: str = "shadow"
    provider: str = "openrouter"
    model: str = MODEL
    endpoint: str = ENDPOINT
    deadline_s: float = 20.0
    max_retries: int = 0
    max_input_bytes: int = 12000
    uncertainty_threshold: float = 0.25
    min_probability: float = 0.75
    tier_models: Mapping[str, str] = field(default_factory=dict)
    prompt_version: str = "factory-complexity-1"
    schema_version: str = "1"
    cache_entries: int = 256

    def __post_init__(self) -> None:
        if type(self.enabled) is not bool or self.mode not in ("off", "shadow", "advisory", "automatic"):
            raise ConfigError("invalid_mode")
        if self.provider != "openrouter" or self.model != MODEL or self.endpoint != ENDPOINT:
            raise ConfigError("unsupported_protocol")
        for name, lower, upper in (("deadline_s", 0.1, 60), ("uncertainty_threshold", 0, 1),
                                   ("min_probability", 0, 1)):
            value = getattr(self, name)
            if type(value) not in (int, float) or not lower <= value <= upper or not math.isfinite(value):
                raise ConfigError("invalid_threshold_or_deadline")
        for name, lower, upper in (("max_retries", 0, 1), ("max_input_bytes", 512, 32000),
                                   ("cache_entries", 1, 4096)):
            value = getattr(self, name)
            if type(value) is not int or not lower <= value <= upper:
                raise ConfigError("invalid_bound")
        # Versions name implemented protocols, not arbitrary user prompt text.
        if self.prompt_version != "factory-complexity-1" or self.schema_version != "1":
            raise ConfigError("unsupported_version")
        if not isinstance(self.tier_models, Mapping) or any(
            key not in TIERS[:3] or not isinstance(value, str) or not 1 <= len(value) <= 200
            or any(c.isspace() for c in value) or not all(value.partition("/")[::2])
            for key, value in self.tier_models.items()
        ):
            raise ConfigError("invalid_tier_mapping")
        object.__setattr__(self, "tier_models", MappingProxyType(dict(self.tier_models)))

    @classmethod
    def from_mapping(cls, value: dict) -> "DecisionConfig":
        if not isinstance(value, dict) or set(value) - set(cls.__dataclass_fields__):
            raise ConfigError("unknown_config_field")
        try:
            return cls(**value)
        except (TypeError, ValueError) as exc:
            if isinstance(exc, ConfigError):
                raise
            raise ConfigError("invalid_config") from None
