"""Standalone, shadow-default factory complexity recommendations.

No import-time network, credential lookup, factory hooks or mode activation.
"""
from .adapter import DecisionAdapter, parse_response, select_model
from .config import ConfigError, DecisionConfig

__all__ = ["ConfigError", "DecisionAdapter", "DecisionConfig", "parse_response", "select_model"]
