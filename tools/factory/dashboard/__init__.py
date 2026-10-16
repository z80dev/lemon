"""Read-only, loopback-only live dashboard for the factory (`factory dashboard`).

Reads the ledger only through `store.Ledger` and `supervisor.health`; serves GET routes only.
"""

from .server import DEFAULT_PORT, LOOPBACK_HOST, make_server, serve

__all__ = ["DEFAULT_PORT", "LOOPBACK_HOST", "make_server", "serve"]
