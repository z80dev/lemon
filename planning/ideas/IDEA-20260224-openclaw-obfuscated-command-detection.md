---
id: IDEA-20260224-openclaw-obfuscated-command-detection
title: Detect obfuscated commands that bypass allowlist filters
source: openclaw
source_commit: 0e28e50b4
discovered: 2026-02-24
status: proposed
---

# Description
OpenClaw added security hardening to detect obfuscated commands that attempt to bypass allowlist filters. This prevents malicious actors from using shell tricks to execute commands that would otherwise be blocked by the exec approval system.

Key features:
- Obfuscated command detector for security-sensitive bash/exec operations
- Pattern detection for common obfuscation techniques (backticks, variable substitution, encoding)
- Enforcement of obfuscation approval on both gateway and node hosts
- Test coverage for obfuscation detector patterns
- Prevents timeout bypass attempts

# Lemon Status
- Current state: No obfuscated command detection found
- Gap: Exec/bash tool security doesn't include obfuscation detection

# Investigation Notes
- Complexity estimate: M
- Value estimate: H (security hardening)
- Open questions:
  - Does Lemon's bash tool have allowlist-based filtering?
  - Where would obfuscation detection fit in the tool policy system?
  - Should this be part of tool policy validation or a separate security layer?

# Recommendation
proceed - Security hardening feature that protects against command injection bypasses. Should be integrated with the existing tool policy/authorization system.

# References
- OpenClaw commit: 0e28e50b4
- Files affected: bash-tools.exec-host-gateway.ts, bash-tools.exec-host-node.ts, exec-obfuscation-detect.ts
