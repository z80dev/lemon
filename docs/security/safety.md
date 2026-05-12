# Lemon Safety

Last reviewed: 2026-05-11

Lemon is a local-first AI agent runtime. It can read files, run tools, call model
providers, store memory, load skills, and operate through chat interfaces. Those
capabilities are useful because they are powerful, and they need explicit safety
boundaries.

## Safety Model

Lemon's safety model is based on five layers:

1. **Local control:** Lemon runs on your machine or server. You choose the
   provider credentials, runtime profile, working directory, and channel
   adapters.
2. **Tool policy:** Agent tools can be allowed, denied, or configured to require
   approval before use.
3. **Secrets isolation:** Provider keys should live in Lemon's encrypted secrets
   store and be referenced by name from config.
4. **Memory and skill boundaries:** Memory and skills are treated as reusable
   context, not as trusted instructions that can override operator policy.
5. **Diagnostics redaction:** Doctor support bundles are designed to exclude
   provider keys, tokens, passwords, private prompts, memory contents, and tool
   outputs.

## What Users Should Expect

Lemon can be configured to:

- require approval before file writes, shell commands, or other high-impact
  tools
- keep provider API keys out of plaintext `config.toml`
- produce redacted support bundles for maintainers
- run deterministic test and quality gates before releases
- keep local runtime and release artifacts observable through health checks and
  diagnostics

Lemon cannot make arbitrary model output safe by itself. Treat responses,
tool-use suggestions, web content, email content, chat messages, and third-party
skill or MCP content as untrusted until policy and operator review allow action.

## Recommended Defaults

For normal use:

- Store provider keys with `mix lemon.secrets.set`.
- Keep `require_approval = ["bash", "write", "edit"]` or a stricter equivalent
  for assistant profiles that work in real repositories.
- Bind sessions to the intended project directory instead of broad home
  directories.
- Enable only the channel adapters you actually use.
- Review generated support bundles before sharing them.
- Keep public issue reports free of raw prompts, private repo content, provider
  tokens, cookies, OAuth payloads, and wallet keys.

## High-Risk Operations

Use extra caution before allowing the agent to:

- run shell commands that install packages, modify global config, or touch
  credentials
- write to deployment, CI, release, or infrastructure files
- operate on private repositories with sensitive customer or production data
- call third-party tools, MCP servers, browser automation, email, or messaging
  integrations
- execute instructions copied from websites, issues, pull requests, emails, or
  chat channels

## Support Bundles

Generate a support bundle from a source checkout:

```bash
mix lemon.doctor --bundle
```

Generate a support bundle from a release artifact:

```bash
./bin/lemon_runtime_full eval 'LemonCore.Doctor.CLI.bundle!()'
```

Support bundles are redacted by design, but review them before attaching them to
issues. If a bundle contains sensitive data, do not share it publicly; open a
minimal issue with reproduction steps instead.

## Security Issues

Report vulnerabilities using `SECURITY.md`, not a public issue. Include the
minimum reproduction details needed to investigate. Do not include live secrets,
private keys, OAuth tokens, session cookies, production data, or private prompts.

## Launch Status

The deeper engineering safety contract lives in
[Agent Safety Contract](agent-safety-contract.md). The 1.0 readiness plan now
tracks deterministic prompt-injection coverage for web fetch output, inbound
email prompts, skill prompt rendering, and generic untrusted extension-style
tool results. Broader adversarial variant depth remains a post-1.0 hardening
stream.
