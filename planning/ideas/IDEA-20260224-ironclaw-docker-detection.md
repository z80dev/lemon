---
id: IDEA-20260224-ironclaw-docker-detection
title: Docker sandbox detection and platform guidance
source: ironclaw
source_commit: 4e2dd76
discovered: 2026-02-24
status: proposed
---

# Description
IronClaw added comprehensive Docker detection with platform-specific guidance for sandboxed execution. This enables safer execution of LLM-generated code by detecting Docker availability and providing helpful guidance when it's not available.

Key features:
- Docker detection module with platform-specific guidance (macOS/Linux/Windows)
- Docker sandbox step in setup wizard explaining why Docker matters
- Docker status shown in boot screen
- Proactive Docker availability check at startup
- Graceful fallback when Docker is unavailable (logs warning, disables sandbox)
- Multiple Docker socket path probing for different container runtimes:
  - `~/.docker/run/docker.sock` - Docker Desktop 4.13+
  - `~/.colima/default/docker.sock` - Colima
  - `~/.rd/docker.sock` - Rancher Desktop
  - `/var/run/docker.sock` - Traditional Docker
- Rootless Linux and Windows fallback support

# Lemon Status
- Current state: Lemon has WASM sandboxing but no Docker container sandbox
- Gap: No Docker detection or containerized execution environment

# Investigation Notes
- Complexity estimate: L
- Value estimate: H (security/safety improvement)
- Open questions:
  - Does Lemon need Docker sandboxing given it already has WASM sandboxing?
  - Would this be for the bash/exec tools specifically?
  - How would this integrate with the existing tool policy system?
  - Should this be a new sandbox provider alongside WASM?

# Recommendation
defer - While valuable for security, Lemon already has WASM sandboxing which provides similar isolation guarantees. This would be a significant addition that needs careful consideration of how it complements (or replaces) existing sandboxing.

# References
- IronClaw commit: 4e2dd76
- Files affected: sandbox/detect.rs, sandbox/container.rs, setup/wizard.rs, boot_screen.rs
