# Support

Last reviewed: 2026-05-12

Lemon support is designed around reproducible local diagnostics. Before opening
an issue, run doctor and include the install path, version or commit, operating
system, interface, and redacted support bundle when relevant.

## Supported for 1.0

Initial stable 1.0 support targets:

- source installs on machines with supported Elixir and Erlang/OTP versions
- Linux `x86_64` release tarballs published by the Lemon release workflow
- provider setup through documented configuration and secrets commands
- runtime startup through `./bin/lemon`, `./bin/lemon-dev`, and release scripts
- Web health and operations pages
- first-party text web tools such as web search/fetch when used from supported
  agent runs
- doctor diagnostics and redacted support bundles
- bugs with reproduction steps on supported source or release-runtime paths

## Channel Support

Telegram and Discord are stable 1.0 remote chat channels for text-first agent
runs. The TUI, Web UI, and control plane are stable first-party local
interfaces.

Discord support is bounded to the live-proven path: mention-triggered text
prompts in the configured Lemonade Stand channel, markdown/code rendering,
long-output chunking, tool success/failure status rendering, and text-file
attachment delivery. X/Twitter, XMTP, SMS, voice, and other channel adapters are
preview or experimental unless a release note explicitly promotes a narrower
path. Bugs in preview channels can be filed with reproduction steps and support
bundles, but they do not carry the same release-blocking support promise as
Telegram, Discord, TUI, Web, and the control plane.

## Web, Browser, and Media Tools

Stable 1.0 support covers first-party text web search/fetch behavior when the
run is reproducible on a supported source or release-runtime install. Browser
automation, visual page interaction, generated media, image analysis, and voice
or TTS behavior are preview or out of scope unless a release note explicitly
promotes a narrower path.

Lemon 1.0 does not claim OpenAI-compatible Chat Completions/Responses API
support, ACP editor integration, or third-party frontend compatibility unless a
release note explicitly promotes a narrower path. The stable API surface is the
documented Lemon control plane and first-party Web/TUI interfaces.

For web-tool bugs, include the prompt, tool name, target URL when shareable,
interface, runtime mode, and whether the issue is plain text fetch/search or
browser/media behavior.

## Automation and Cron

Cron and scheduled automation are preview surfaces for stable 1.0. The supported
boundary is operator-controlled scheduling from the Web operations UI or
first-party control-plane/runtime paths, with reproducible failures covered as
setup or runtime bugs.

Stable 1.0 does not support presenting cron as an unrestricted model-facing
tool. Scheduled agent runs are expected to run in isolated forked sessions, carry
their prior-run memory context, and block recursive cron management through model
tool policy. Treat advanced automation workflows, external scheduler
integrations, and production SLA-style scheduling guarantees as post-1.0 work.

## Telegram Rendering and Media

Telegram is supported as a remote chat interface for text-first agent runs.
Stable 1.0 behavior includes:

- plain text delivery with Telegram entities for headings, bold, italic,
  inline code, fenced code blocks, links, lists, blockquotes, and simple
  markdown tables rendered as pipe-delimited text
- progress/status messages, cancellation controls, approval buttons, and
  concise run-failure messages
- `/file put` and `/file get` when Telegram file transfer is enabled
- document upload auto-save when enabled by config
- `telegram_send_image` for image files that already exist inside the active
  project or workspace roots
- optional generated-image auto-send, bounded by configured file count and size
  limits
- image batches through Telegram media groups when the Bot API accepts them,
  with sequential image/document fallback

Not stable for 1.0:

- arbitrary rich media generation as a product feature
- image analysis as a Telegram interface feature
- TTS or voice reply generation
- guarantees that every markdown extension renders visually identical to GitHub
  Markdown
- sending files from outside the active project or workspace roots

For Telegram media bugs, include the interface, command or tool used, file type,
file size, relevant `[gateway.telegram.files]` config, and whether the issue was
manual `/file`, generated-image auto-send, or `telegram_send_image`.

The detailed support matrix lives in
[Release Checklist and Support Policy](release/release_checklist_and_support_policy.md).

## Not Supported for 1.0

These are outside the initial stable support boundary:

- native Windows installs outside WSL experimentation
- hosted Lemon service operation
- Discord behavior outside the text-first and file-delivery boundary, including
  voice, broad slash-command parity, and unproven DM/thread workflows
- stable support guarantees for X/Twitter, XMTP, SMS, voice, or other preview
  channel adapters unless explicitly promoted in release notes
- production-grade scheduling guarantees for cron or scheduled automation
- first-class browser automation, generated media, image analysis, or TTS/voice
  behavior unless explicitly promoted in release notes
- OpenAI-compatible API server behavior, ACP editor integration, or drop-in
  support for third-party OpenAI-compatible frontends
- automatic filesystem checkpointing or rollback for agent file mutations
- production support for third-party plugins or unofficial MCP servers
- arbitrary local shell, provider, or OS customization issues
- old commits that are not the current stable release, preview build, or a
  requested diagnostic commit
- user-provided secrets, private prompts, memory contents, or tool outputs
  shared as part of an issue

## Before Opening a Bug

Run:

```bash
mix lemon.doctor
```

For source-dev installs, generate a reviewed redacted bundle:

```bash
mix lemon.doctor --bundle
```

From the Web operations UI, use:

```text
http://127.0.0.1:4080/ops/support-bundle
```

For release-runtime installs, generate:

```bash
bin/lemon_runtime_full eval 'LemonCore.Doctor.CLI.bundle!()'
```

Review the zip before sharing it. The bundle is designed to exclude secrets and
private data, but users remain responsible for checking attachments before
posting them publicly.

The bundle manifest includes the Lemon app version, release name/version,
release channel when available, source/release runtime mode, git commit/branch
state, Elixir/OTP versions, OS, and CPU architecture.

## Logs

By default, source-dev runs write logs to stdout/stderr. Increase verbosity with:

```bash
LEMON_LOG_LEVEL=debug ./bin/lemon
```

File logging is opt-in through `~/.lemon/config.toml`:

```toml
[logging]
file = "~/.lemon/log/lemon.log"
level = "debug"
```

For release-runtime installs, stdout/stderr depends on how the runtime is
started. CI release-smoke failures upload release logs from
`_build/prod/rel/<profile>/tmp/log/`. When filing issues, include only relevant
log excerpts and remove secrets, tokens, private prompts, memory contents, and
tool outputs.

## What to Include

Use the bug report template and include:

- install path: source-dev or release-runtime
- operating system and architecture
- Lemon commit, tag, or release artifact name
- interface: TUI, Web, Telegram, Discord, CLI, release runtime, or control plane
- command that failed
- expected behavior
- actual behavior
- relevant logs with secrets removed
- support bundle command output or attached reviewed bundle

## Security Reports

Do not open public issues for suspected vulnerabilities or secret leaks. Use the
security reporting path in the repository
[SECURITY.md](https://github.com/z80dev/lemon/blob/main/SECURITY.md) and the
safety guidance in [Lemon Safety](security/safety.md).

## Useful Pages

| Need | Page |
| --- | --- |
| Install path | [Install Lemon](install.md) |
| Full setup guide | [Setup Guide](user-guide/setup.md) |
| Run a local proof | [Demo Lemon](demo.md) |
| Safety and redaction model | [Safety](security/safety.md) |
| Release support matrix | [Release Checklist](release/release_checklist_and_support_policy.md) |
| Current launch gaps | [Mainstream Readiness Plan](plans/lemon-1.0-mainstream-readiness.md) |
