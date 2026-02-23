---
id: IDEA-20260223-openclaw-markup-sanitization
title: [OpenClaw] Sanitize Untrusted Wrapper Markup in Chat Payloads
source: openclaw
source_commit: a10ec2607
discovered: 2026-02-23
status: proposed
---

# Description
OpenClaw added security hardening to sanitize untrusted wrapper markup in chat payloads (commit a10ec2607). This feature:
- Prevents XSS-style attacks through malicious markup in payloads
- Sanitizes wrapper markup before final payload delivery
- Adds 60 lines of tests for security coverage

Key changes in upstream:
- Modified `src/gateway/server-methods/chat.ts`
- Added sanitization logic for wrapper markup
- Security-focused fix

# Lemon Status
- Current state: **Unknown** - Need to verify Lemon's payload sanitization
- Gap analysis:
  - Lemon has gateway in `apps/lemon_gateway/`
  - Has chat UI in `clients/lemon-web/`
  - Unclear if markup sanitization is implemented
  - Important for security when displaying user-generated content

# Investigation Notes
- Complexity estimate: **M**
- Value estimate: **H** - Security-critical for web UI
- Open questions:
  1. Does Lemon's web UI sanitize incoming markup?
  2. How does Lemon handle user-generated content in chat?
  3. Are there XSS vulnerabilities in current implementation?
  4. What sanitization library should be used?

# Recommendation
**Investigate** - Security audit needed:
1. Review `clients/lemon-web/` for XSS vulnerabilities
2. Check if user content is properly escaped/sanitized
3. Implement sanitization if missing
4. Add security tests

# References
- OpenClaw commit: a10ec2607
- Lemon files to investigate:
  - `clients/lemon-web/web/src/components/`
  - `apps/lemon_gateway/lib/lemon_gateway/`
