# Compare Lemon

Last reviewed: 2026-05-11

Lemon is a local-first AI agent runtime. It is not trying to be only a chat UI,
only a coding CLI, or only an eval harness. The 1.0 goal is to make the whole
system coherent enough that a technical user can install it, run useful agents,
inspect what happened, recover from failures, and get support without already
knowing the repository.

## Positioning

| Category | What users usually get | Where Lemon is aiming |
| --- | --- | --- |
| Hosted assistants | Fast onboarding, managed infrastructure, limited local control | Local runtime ownership, local files and secrets, configurable engines, supportable self-hosting |
| Single-engine coding CLIs | Strong terminal workflows tied to one engine | Multi-engine execution through Lemon, Codex, Claude, OpenCode, Pi, Kimi, and native Lemon engines |
| Agent harnesses | Repeatable tool loops, transcripts, and eval focus | Hermes-class harness behavior combined with durable memory, skills, channels, and operator interfaces |
| Chat bridges | Messaging access to an assistant | Channel adapters connected to the same runtime, runs, approvals, sessions, and diagnostics |
| Internal automation scripts | Local control but limited product surface | Supervised BEAM runtime, JSON-RPC control plane, Web/TUI/Telegram surfaces, doctor checks, release profiles |

## Main Differentiators

| Area | Lemon direction | Current launch evidence |
| --- | --- | --- |
| Runtime model | Supervised local-first runtime with explicit control-plane APIs | [Architecture Overview](architecture/overview.md), [BEAM Agents](beam_agents.md) |
| Engine model | Multi-engine architecture rather than one model-provider path | [Model Selection](model-selection-decoupling.md), [Configuration](config.md) |
| Harness behavior | Tool execution, approval, transcript, eval, and long-running run support | [Hermes Parity Scorecard](plans/lemon-hermes-agent-harness-parity-scorecard.md), [Testing](testing.md) |
| Memory and skills | Durable context plus reusable task packs | [Memory Guide](user-guide/memory.md), [Skills Overview](skills.md) |
| Interfaces | Terminal, Web, control plane, Telegram, Discord, and gateway/channel adapters | [Interface Supportability Audit](plans/lemon-1.0-interface-supportability-audit-2026-05-11.md) |
| Operations | Doctor checks, support bundles, release profiles, smoke tests, and quality gates | [Release Checklist](release/release_checklist_and_support_policy.md), [Safety](security/safety.md) |

## 1.0 Reality Check

Lemon is pre-1.0. The source install path, release profiles, product smoke, docs
site, support bundle, and Web operations views are being hardened toward the
stable launch goal.

What is ready enough to evaluate:

- source install on a developer machine
- provider configuration through setup docs and secrets commands
- local runtime startup through `./bin/lemon-dev` or `./bin/lemon`
- doctor diagnostics and redacted support bundles
- Hermes-class parity tracking through the launch scorecard
- first-party text web search/fetch behavior in supported agent runs
- Web operations pages for runtime health, recent runs, run detail, and approvals
- preview operator-controlled cron and scheduled automation through first-party
  runtime/Web paths
- release artifact profiles verified locally

What is not yet a stable public promise:

- downloaded public GitHub Release artifact proof
- final launch screenshots and videos
- a claim of drop-in Hermes compatibility beyond the published scorecard and
  supported 1.0 feature boundary
- production-grade cron scheduling guarantees or unrestricted model-facing cron
  management
- first-class browser automation, media generation, image analysis, or voice/TTS
  behavior
- full Web operations coverage for skills, logs, channels, and deeper config
- broad clean-container or clean-VM install matrix
- hosted service support
- Windows-native support outside WSL experimentation

## When Lemon Is the Right Fit

Use Lemon when you want:

- a local-first assistant runtime that can work inside real repositories
- a multi-engine setup instead of committing to one coding CLI
- durable project memory and reusable skills
- channel access without losing runtime observability
- a supportable self-hosted agent system with quality gates

Do not pick Lemon yet if you need:

- a fully managed hosted assistant
- one-click public binary installation across all operating systems
- a stable plugin ecosystem with third-party production support
- a non-technical end-user product

## Evaluation Path

1. Install from [Install Lemon](install.md).
2. Run `mix lemon.doctor`.
3. Start the runtime with `./bin/lemon-dev /path/to/project`.
4. Exercise a deterministic flow from [Demo Lemon](demo.md).
5. Check current gaps in the [Mainstream Readiness Plan](plans/lemon-1.0-mainstream-readiness.md).
6. Use [Support](support.md) if you hit setup or runtime issues.
