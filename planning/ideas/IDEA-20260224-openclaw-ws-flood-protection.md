---
id: IDEA-20260224-openclaw-ws-flood-protection
title: Gateway WebSocket unauthorized request flood protection
source: openclaw
source_commit: 7fb69b7cd
discovered: 2026-02-24
status: proposed
---

# Description

OpenClaw added flood protection to the Gateway WebSocket connection handler to stop repeated unauthorized request floods per connection.

Key features:
- Unauthorized flood guard primitive
- Closes repeated unauthorized post-handshake request floods
- Test coverage for unauthorized flood guard behavior
- Security hardening for WebSocket connections

# Lemon Status

- Current state: Lemon has WebSocket support in gateway
- Gap: No flood protection for unauthorized WebSocket requests
- Location: `apps/lemon_gateway/lib/lemon_gateway/` (WebSocket handling)

# Investigation Notes

- Complexity estimate: M
- Value estimate: H (security hardening)
- Open questions:
  - Where does Lemon handle WebSocket connections?
  - Is there existing rate limiting infrastructure to build on?
  - What constitutes a "flood" threshold?

# Recommendation

**proceed** - Security hardening feature that prevents DoS attacks via WebSocket connections. Important for production deployments.

# References

- OpenClaw PR: #24294
- Commit: 7fb69b7cd26a0981931544a556fb67bed8a31e6c
