# Is Lemon right for you?

Lemon is a local-first assistant runtime for people who want control over their
models, tools, and working context. Start in a terminal or browser, keep durable
conversations, and add messaging channels or remote execution when your workflow
calls for them.

## A good fit when you want to…

| Your priority | What Lemon gives you | Explore |
| --- | --- | --- |
| Work where your files live | Local tools, project context, approvals, and persistent sessions | [Quickstart](getting-started/quickstart.md) |
| Choose your models | Provider configuration, model selection, and documented routing controls | [Configuration](config.md) |
| Separate different kinds of work | Profiles with their own workspaces and canonical conversations | [Profiles](user-guide/profiles.md) |
| Keep useful context | Searchable memory, reusable skills, and reviewable learning from sources | [Memory](user-guide/memory.md), [Skills](user-guide/skills.md), [Learning](user-guide/learn-from-sources.md) |
| Reach your assistant from chat | Telegram and Discord adapters connected to the native runtime | [Setup](user-guide/setup.md#optional-telegram-or-discord), [Channel support](support.md#channel-support) |
| Run work on another machine | Authenticated named execution nodes using destination-local workspaces and credentials | [Architecture](architecture/overview.md) |
| Operate your own assistant | Diagnostics, backups, update plans, and receipt-bound rollback | [Support](support.md), [Backups](user-guide/backups.md), [Updates](user-guide/updates.md) |
| Study how agents behave | LemonSim event-sourced worlds and deterministic replay verification | [Benchmark quickstart](benchmarks/quickstart.md) |

## What you take on

Lemon runs on infrastructure you manage. You configure provider access, maintain
your installation, and decide which tools and channels to enable. Model requests
use your chosen provider; running Lemon locally does not mean every model or
service runs offline.

In return, your sessions, configuration, and operational controls belong to your
runtime. The [safety guide](security/safety.md) explains tool policy, approvals,
and the boundaries around untrusted content.

## How the pieces fit

Lemon combines an assistant with a supervised runtime. Terminal, browser, and
channel interfaces connect to shared routing and agent execution. Native
subagents reuse the same model and tool stack. Durable sessions let you return
to previous work, while the control plane exposes runtime operations to clients.

Underneath, Elixir/OTP supplies process isolation and supervision. LemonSim uses
the stack for a separate purpose: repeatable model-vs-model simulations. See the
[architecture overview](architecture/overview.md) for the technical map.

## Check these boundaries before choosing

- **Platforms:** prebuilt releases target macOS Apple Silicon and documented
  Linux architectures. Native Windows is outside the current support boundary.
  See [installation requirements](install.md).
- **User experience:** Lemon provides a terminal UI and local browser interface.
  It does not provide a managed hosted assistant service or a native desktop app.
- **Advanced tools:** browser automation, generated media, LSP, checkpoints, API
  compatibility, ACP, MCP, and WASM have documented preview boundaries. Check the
  [support guide](support.md) for the feature you need.
- **Automation:** cron, heartbeats, goals, and related runtime controls exist;
  production scheduling guarantees are outside the current stable boundary.
- **Credentials:** encrypted storage and configured secret sources do not amount
  to a general credential broker that keeps real credentials out of every tool
  or remote execution environment.

These distinctions matter when evaluating a workflow. A successful local demo
shows that path working on your machine; it does not establish every integration
or production guarantee.

## Moving from another assistant?

If you use Hermes, start with the [migration guide](user-guide/migrate-from-hermes.md).
It explains the preview-first import path for existing context and configuration.
Review the proposed import before changing Lemon state, then verify your daily
workflow with a real conversation.

## Try one real task

1. Follow the [quickstart](getting-started/quickstart.md).
2. Run a small repository task from [Try Lemon](demo.md).
3. Reopen the session and test the interface or integration you care about.
4. Use [diagnostics](support.md) if anything needs attention.

That gives you a practical basis for deciding whether Lemon fits your work.
