# Security Policy

## Supported Versions

Only the latest release on the `main` branch receives security fixes.

## Reporting a Vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Email: `security@lemon` (replace with actual contact when available)

Include:
- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Any suggested fixes (optional)

You will receive an acknowledgement within 72 hours.

## Scope

### In scope

- Authentication and authorization bypass in the control plane or gateway
- Secret leakage via memory documents, skill synthesis output, or logs
- Remote code execution via tool policy bypass
- Privilege escalation via the approval gate system

### Out of scope

- Issues requiring physical access to the machine
- Vulnerabilities in upstream dependencies (report to the dependency maintainer)
- Issues in CLI backends (Codex, Claude CLI, etc.) — report to their maintainers

## Security Design Notes

### Secrets

API keys and secrets are stored in an encrypted keychain, not in `config.toml`
in plaintext. Skills and memory documents are scanned for common secret patterns
before storage. See [`docs/security/secrets-keychain-audit-matrix.md`](docs/security/secrets-keychain-audit-matrix.md).

### Skill synthesis

Synthesized skill drafts are scanned for:
- API key patterns (`sk-...`, `AKIA...`)
- Password values (`password=...`)
- PEM private key headers
- JWT-like tokens

Drafts containing these patterns are discarded before writing to disk.

### Tool policy

The tool policy system (`require_approval`, `deny`) enforces approval gates
for sensitive operations like `bash`, `write`, and `edit`. Policy is enforced
in `LemonRouter.PolicyEngine` before any tool executes.

### Skills from untrusted sources

Third-party skill sources require explicit trust approval before installation.
Official registry skills are signed and verified. See the trust policy in
`LemonSkills.TrustPolicy`.

## Security Contacts

| Role | Contact |
|---|---|
| Maintainer | @z80 |

*Last reviewed: 2026-03-16*
