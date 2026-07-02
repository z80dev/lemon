# Lemon Hermes-on-BEAM Readiness Plan

Status: active product goal

Last reviewed: 2026-05-17

## Summary

Lemon should become "Hermes, but better, on the BEAM": a local-first AI agent
platform that reaches Hermes-level daily-use feature parity, then uses OTP,
supervision, process isolation, PubSub, durable state, and live introspection to
make those features more reliable and operable than a monolithic harness.

The goal is not to clone Hermes internals. The goal is to match or exceed the
user-visible product capabilities while implementing them in BEAM-native ways:

- reliable multi-step agent execution
- strong tool lifecycle guarantees
- durable memory and reusable skills
- safe delegation and background jobs
- useful local and channel-based interfaces
- first-class browser, media, plugin, API/editor, terminal-backend, rollback,
  and automation surfaces where Hermes currently leads
- clear setup, packaging, support, and website story

Lemon already has many of the hard architectural primitives: supervised BEAM
runtime, router/gateway separation, multiple engines, native tools, memory,
skills, control plane, release profiles, setup and doctor tasks, CI smoke lanes,
and a long-running Hermes-class parity scorecard. The corrected priority is now
fuller feature and reliability parity for real daily agent work. Packaging,
website polish, and support process are important, but they are downstream of
product capability and proof.

The broader mission is larger than "Hermes on BEAM." Lemon should also become a
BEAM-native platform for running, watching, replaying, and benchmarking agent
simulations through `lemon_sim` and `lemon_sim_ui`. Werewolf should become a
proper social-deduction game that is fun to watch, and Vending Bench 2.0 should
become the flagship nested operator/worker business simulation. The operational
mission plan lives in `docs/plans/lemon-sim-platform-mission-2026-05-12.md`.

## Product Goal

Launch Lemon as a mainstream-ready, self-hosted AI agent platform for developers
and technical operators who want Hermes-class agent capability with local
control, durable context, multi-channel access, and BEAM-grade runtime
reliability.

At launch, a new user should be able to:

1. Understand what Lemon is and why they would use it.
2. Install or build Lemon without understanding the umbrella internals.
3. Configure one provider and one interface.
4. Run a real coding task from TUI, web, Telegram, or Discord.
5. See what the agent is doing while it works.
6. Use browser, web, terminal, memory, skills, delegation, cron, media, and
   channel tools with stable, documented behavior.
7. Recover from common setup and runtime problems.
8. Upgrade safely.
9. Report an issue with enough diagnostics for maintainers to help.

## Positioning

Lemon should be positioned as:

> A local-first AI agent runtime for serious developer workflows, with durable
> memory, reusable skills, multi-engine execution, channel integrations, and
> BEAM-grade supervision.

This should stay concrete. The product is not a generic chatbot and not a hosted
SaaS-first assistant. It is an agent runtime that users can own.

Short form:

> Hermes-class agent UX, rebuilt as a supervised BEAM system.

## Competitive Standard

Hermes-class parity is the launch bar for product capability, harness quality,
and reliability, not a nice-to-have after packaging. Lemon does not need to copy
Hermes internals, but it does need source-grounded evidence that user-visible
capabilities and failure behavior are comparable or better before a stable
launch.

Parity means Lemon should have comparable behavior for:

- tool ergonomics and enforcement
- tool-call lifecycle correctness
- provider and streaming edge cases
- memory and procedural skill usage
- delegated work and subagent joins
- scheduled/background jobs
- safe handling of untrusted tool output
- observable progress and failure metadata
- channel delivery and media behavior
- browser/web interaction
- ACP/editor and API integration where users expect external clients to talk to
  the agent runtime
- checkpoint/rollback behavior for file and command safety
- multi-backend terminal/process execution where it materially improves real
  workflows
- plugin/extension ecosystem behavior with clear safety and observability
- direct Telegram and Discord operation under real credentials, including group
  chats, Telegram forum topics, and channel/thread routing

BEAM-native parity means Lemon should prefer OTP-shaped designs:

- one supervised process tree per durable run, channel adapter, browser session,
  cron job, external process, and plugin host
- explicit state machines for run lifecycle, approvals, rollback checkpoints,
  background jobs, and channel delivery
- PubSub/event streams as the source for Web/TUI/channel progress views
- durable stores and replayable event logs rather than ad hoc in-memory session
  state
- isolated worker processes and bounded policies for browser sessions, terminal
  backends, plugin tools, and media pipelines
- first-class introspection in `/ops`, support bundles, telemetry, and eval
  artifacts

Beyond Hermes parity, Lemon should have a differentiated simulation platform:

- `lemon_sim` provides reusable contracts for domain state, events, action
  spaces, projectors, updaters, tool-loop decisions, memory, replay, and
  benchmark scoring.
- Werewolf is the watchable social-deduction showcase, with live spectator
  pacing, readable hidden-information reveals, replays, and objective
  role/model metrics.
- Vending Bench 2.0 is the nested-agent operations benchmark, with an operator,
  physical worker, suppliers, inventory, demand, pricing, maintenance,
  incidents, and a full scorecard.

The existing parity scorecard remains the detailed harness ledger:

- `docs/plans/lemon-hermes-agent-harness-parity-scorecard.md`
- `docs/plans/lemon-sim-platform-mission-2026-05-12.md`

This plan is broader. It combines parity with product readiness, packaging,
website, support, testing, and release discipline.

## Non-Goals

The product goal should not include:

- A full hosted cloud service.
- A billing system.
- Full rewrite of the web client.
- Replacing every external engine with native Lemon behavior.
- Blindly copying Hermes internals or unsupported edge behavior that does not
  matter for real user-facing parity.
- Broad non-technical consumer onboarding.

These may become later work, but the current target should stay focused on a
credible self-hosted product that advanced users can adopt and maintain. Plugin
support, browser/media tools, rollback, external API/editor integration, and
multi-backend execution are no longer non-goals; they are parity workstreams to
design and land in BEAM-native form.

## Launch Definition

Lemon is mainstream-ready when these statements are true:

1. **Install:** A fresh user can install and run Lemon from documented
   instructions or release artifacts.
2. **Configure:** The setup path handles provider credentials, secrets, runtime
   defaults, and one interface without hand-editing undocumented state.
3. **Use:** TUI, web, Telegram, and Discord each have a documented, proven
   happy path plus failure behavior for their stable support boundary.
4. **Trust:** Tool execution, approvals, memory, skills, and untrusted content
   behavior are tested and documented.
5. **Observe:** Users and maintainers can inspect runs, tool calls, subagents,
   approvals, failures, memory, skills, and cron jobs.
6. **Browse and automate:** Browser sessions, text web tools, media tools, and
   channel attachments are stable enough for real tasks or explicitly gated by
   release notes while they are being finished.
7. **Integrate:** External clients can use stable API/editor/MCP surfaces
   without depending on private implementation details.
8. **Extend:** Plugins, MCP tools, and skills run under explicit policies,
   audits, telemetry, and degradation behavior.
9. **Recover:** `doctor`, logs, support bundles, rollback/checkpoint tooling,
   and troubleshooting docs cover common failures.
10. **BEAM leverage:** Long-running work, channels, browser sessions, cron jobs,
    plugin hosts, and external processes are supervised, observable, and
    restartable.
11. **Release:** Stable, preview, and nightly release channels are real enough
    to publish and update safely.
12. **Support:** Issues can be triaged with templates, diagnostics, logs, and
    clear support boundaries.
13. **Website:** A public site explains the product, shows how to install it,
    links to docs, and gives users confidence that the project is maintained.
14. **Quality:** Local, CI, and credential-backed live channel gates exercise
    the product surfaces users will actually touch, not only unit modules.

## Mainstream User Profiles

### Developer

Wants a local coding agent that can work in repos, use tools, remember project
conventions, and be reachable from terminal or chat.

Needs:

- fast setup
- safe file and shell tool approval defaults
- repo-bound sessions
- usable TUI
- memory and skills that improve repeat tasks
- browser, web, media, MCP/plugin, and rollback behavior that works when needed
- clear error reporting when provider calls fail

### Technical Operator

Wants an agent that can monitor, schedule, and run background tasks from a
server or workstation.

Needs:

- release runtime
- health checks
- cron and background job visibility
- supervised browser, terminal, plugin, and media workers
- Telegram or web access
- logs and support bundles
- upgrade and rollback path

### Contributor

Wants to extend Lemon without learning every umbrella boundary first.

Needs:

- architecture docs
- app-specific guides
- quality gates
- extension and skill docs
- BEAM process/state-machine patterns for new runtime surfaces
- ownership map
- readable failures

### Evaluator

Wants to compare Lemon against Hermes, Claude Code, Codex, OpenCode, Pi, or a
homegrown agent stack.

Needs:

- clear feature matrix
- demos
- honest gaps
- security model
- BEAM-native architecture rationale
- performance and reliability claims backed by tests
- reproducible examples

## Workstreams

### Workstream 1: Product Truth Audit

Goal: make the repo tell the truth about what works, what is partial, and what
is missing.

Scope:

- Audit README, docs, website scaffold, release docs, setup docs, CI workflows,
  and the parity scorecard.
- Remove or repair stale references, including missing roadmap or product docs.
- Produce a current gap table with owner, priority, risk, and acceptance
  criteria.
- Separate implemented features from planned features.

Deliverables:

- This plan.
- A living readiness checklist section in this document.
- Updated docs index links.
- Follow-up issues or plan slices for each major gap.

Exit criteria:

- New contributors can find the launch goal from `docs/README.md`.
- Every product claim in the root README has a backing doc, command, workflow,
  or test.
- Missing or stale product docs are either restored, rewritten, or removed from
  navigation.

### Workstream 2: Hermes-Class Feature and Reliability Parity

Goal: make Lemon credible as "Hermes, but better, on the BEAM" by proving
feature parity and reliability on the surfaces real users will touch, then
closing every P0/P1 parity gap with an OTP-shaped implementation plan.

Current source of truth:

- `docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md`
- `docs/plans/lemon-hermes-agent-harness-parity-scorecard.md`

2026-05-15 Hermes refresh:

- Hermes upstream baseline is `/home/z80/dev/hermes-agent` `origin/main` at
  `4ad5fa702`.
- The parity matrix now treats these newer Hermes surfaces as in-scope Lemon
  workstreams: persistent goals, durable kanban boards, LSP semantic
  diagnostics, OpenAI-compatible API/Responses support, ACP/editor integration,
  Codex app-server runtime interop, provider routing/fallback/credential pools,
  plugin/provider hosts, richer browser providers, image/video generation,
  TTS/voice, and broader Telegram/Discord routing/media behavior.
- Telegram and Discord remain the only messaging platforms required for the
  near-term parity launch. Other channel adapters can remain preview until they
  meet the same deterministic and live-proof standard.

Required parity audit:

- Keep the source-grounded Hermes feature matrix current against upstream
  Hermes evidence, not memory or marketing assumptions.
- Map each Hermes capability to Lemon's current implementation, deterministic
  tests, live proof, support boundary, or missing gap.
- Classify gaps as P0 launch blockers, P1 parity work, or P2 ecosystem work
  only after the matrix is complete.
- Keep the parity scorecard as the detailed ledger and this plan as the launch
  decision record.

High-value BEAM-native parity workstreams:

- **Browser and web automation:** supervised browser sessions, CDP/Playwright
  workers, screenshots/artifacts, isolated lifetimes, tool-policy enforcement,
  and Web/TUI/channel progress events.
- **Media and multimodal tools:** image analysis, image generation, TTS/voice,
  and channel media delivery as supervised media jobs with durable artifacts and
  redacted support metadata.
- **Persistent goals:** a durable goal state machine with judge routing,
  budgeted continuation, pause/resume/clear controls, Web status, and Telegram
  / Discord status commands after the runtime exists.
- **Kanban and fleet work:** durable task boards, worker profiles, comments,
  dependency links, worktree/scratch workspaces, dispatcher supervision, and
  model-facing board tools for work that should outlive one parent session.
- **LSP semantic diagnostics:** supervised language-server workers that capture
  baseline diagnostics before writes and return only newly introduced semantic
  errors after edits.
- **Terminal and process backends:** local PTY plus optional Docker and SSH
  preview now, with remaining container-fleet backends modeled as supervised
  external process workers with resource limits, policy checks, logs, and
  restart behavior.
- **Checkpoint and rollback:** per-run checkpoint state machines for file tools
  and destructive shell commands, with diff preview, restore, and audit events.
- **ACP/API/editor integration:** stable external API surfaces that bridge into
  the existing control plane/run graph instead of bypassing Lemon supervision.
- **Cron/background automation:** durable job definitions, scheduler locks,
  recursive-scheduling guardrails, origin delivery, Web ops controls, and
  support-bundle visibility. Redacted `cron_diagnostics.json` support-bundle
  proof, active-run duplicate suppression, and timeout-bounded stale-run
  recovery are complete. Channel-origin forwarded summaries now persist to the
  base session and enqueue through `LemonChannels` via the narrow router bridge,
  without moving channel rendering or `OutboundPayload` ownership into
  `lemon_router`. Scheduled failure/timeout retry policy is now opt-in through
  `max_retries` and `retry_backoff_ms`, with separate `:retry` runs and redacted
  lineage diagnostics. `CronManager` restart recovery, explicit pause/resume
  controls, Web `/ops` retry fields, deterministic scheduled-run claims via
  `Store.put_new`, and full-runtime restart proof are complete. Remaining
  lifecycle controls remain before stable promotion.
- **Plugin/ecosystem breadth:** MCP, WASM, built-in plugins, and future
  marketplace-style plugins running behind capability-aware wrappers,
  install/update audits, health checks, and conflict reporting.
- **Provider/model breadth:** provider registry, model picker, fast/reasoning
  modes, custom endpoints, provider routing, fallback providers, credential
  pools, and live eval coverage across representative providers.
- **Messaging parity:** Telegram and Discord DM/group/thread/forum behavior,
  attachments, markdown, approvals, cancellation, restart/dedupe, and richer
  media delivery; later Slack/WhatsApp/Signal/email/XMTP surfaces promoted only
  with the same proof standard.
- **Observability and dogfood loop:** `/ops` panels and event streams for skill
  loads, memory searches, approvals, subagent tree, browser sessions, terminal
  workers, cron jobs, plugins, and media jobs.
- **Safety depth:** adversarial prompt-injection coverage across web, browser,
  email, channel attachments, skills, plugins, MCP tools, and media metadata.

Live channel reliability proof is P0. It must use the real credentials and
established test methods already used for Lemon channel work, with secrets kept
out of docs and logs.

Live channel testing is part of the core Hermes-parity goal, not a release
checklist afterthought. The launch sequence is:

1. Prove the deterministic adapter contracts in unit and integration tests.
2. Prove real inbound and outbound delivery through Telegram and Discord with
   the established credentials and target chats.
3. Promote every live failure into deterministic coverage when the bug is in
   Lemon and not in the external platform.
4. Only then classify the channel feature as stable, preview, or a later
   parity slice with a named BEAM-native implementation path.

Known live-channel targets:

- Telegram credentials: `~/.zeebot/api_keys/telegram.txt`.
- Telegram group: Lemonade Stand, chat `-1003842984060`.
- Telegram primary forum topic: Lemon Dev, topic `35`.
- Telegram secondary isolation topic: topic `16456`.
- Discord credentials: `~/.zeebot/api_keys/discord.txt` or
  `DISCORD_BOT_TOKEN`.
- Discord guild: `1475727416549969980`.
- Discord channel: `general`, id `1475727417372049419`.

These identifiers may appear in proof logs and docs. Tokens, session files,
phone numbers, user auth material, and raw credential file contents must not.

Telegram live matrix:

- Direct-message prompt round trip.
- Group-chat routing through the established Lemon test group.
- Telegram forum-topic routing, including sending into specific topics and
  preserving `topic_id` / thread context across replies.
- Concurrent group/topic isolation so a run in one topic cannot leak progress,
  tool output, approvals, or cancellation into another topic.
- `/cwd`, model selection, prompt round trip, progress rendering, long-output
  chunking, markdown/code-block rendering, bare `/cancel`, active-run
  cancellation, invalid-command/error rendering, and approval-button resolution.
- Tool status and tool-failure rendering for at least one successful tool call
  and one intentionally failing tool call.
- File and media delivery for the supported Telegram 1.0 boundary, including
  explicit proof for anything marketed as stable.
- Adapter restart/reconnect behavior, update-offset dedupe, and duplicate
  message avoidance after a runtime restart.

Discord live matrix:

- Direct-message or configured channel prompt round trip using the established
  Discord credentials and target channel.
- Channel/thread routing for the supported Discord boundary.
- Progress rendering, markdown/code-block rendering, long-output chunking,
  cancellation, invalid-command/error rendering, and approval behavior where
  supported.
- File delivery through the existing Discord send-file path.
- Tool status and tool-failure rendering for at least one successful tool call
  and one intentionally failing tool call.
- Adapter restart/reconnect behavior and duplicate message avoidance after a
  runtime restart.

Discord evidence standard:

- A Lemon runtime log showing the Discord adapter connected is not a pass.
- A bot-token REST message from the responder bot is only a diagnostic for
  token/channel permissions; it is not a Lemon inbound proof because Discord
  self-authored responder messages and webhooks are ignored by the adapter.
- A pass requires an external-sender message through the established Discord
  test method. The sender can be a human Discord user or the second Lemonade
  Stand bot token, but it must be distinct from the responder bot. The proof
  must show a Lemon run created from that inbound message and a Discord reply
  observed in the same DM, channel, or thread.
- Record target guild/channel/thread IDs and message IDs without exposing bot
  tokens or user credentials.
- The current release-candidate proof uses the second Lemonade Stand bot as the
  external sender. If future environments lose a reliable external-sender method,
  Discord must return to preview until the matrix passes again.

Evidence requirements:

- Record chat/channel IDs, Telegram topic IDs, Discord thread/channel IDs, run
  IDs, message IDs, timestamps, runtime command, config shape, and exact test
  prompts without exposing secrets.
- Save machine-readable result artifacts for release-candidate runs when the
  runner supports it, especially `tmp/discord-live-proof.json` for Discord.
- Capture enough transcript excerpts or screenshots to reproduce every claim.
- Promote any bug found in live Telegram or Discord testing into deterministic
  coverage where practical.
- Do not classify a channel feature as stable unless the direct live matrix for
  that feature passes.
- Treat a channel proof as stale after major adapter, router, runner,
  persistence, approval, markdown, file-delivery, or runtime-restart changes.
  Rerun the affected live matrix before a release candidate.

Current repeatable live runner:

```bash
scripts/live_telegram_matrix.py --timeout 90
```

This uses the established Telethon credentials from
`~/.zeebot/api_keys/telegram.txt`, sends through the real bot, and verifies the
DM prompt/reply path plus the Lemonade Stand forum-topic path. It is the base
runner for the broader Telegram live matrix.

Topic-isolation runner:

```bash
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
  --topic-isolation \
  --isolation-topic-id 35 \
  --isolation-topic-id 16456 \
  --timeout 180
```

This forces overlapping topic runs through short shell sleeps and verifies that
each final answer replies to the original message in its own `reply_to_top_id`.
It passed on 2026-05-12 for topics `35` and `16456`.

Topic-cancel runner:

```bash
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
  --topic-cancel \
  --cancel-topic-id 35 \
  --timeout 95
```

This starts a real long-running tool call inside forum topic `35`, sends bare
`/cancel` into the same topic, and watches long enough to prove that the
cancelled command does not later post its success marker. It passed on
2026-05-12 with `Cancelling current run...`, `Run failed: user_requested`, a
failed `sleep 60` tool-status edit, and no late successful completion.

Topic tool-rendering and markdown runner:

```bash
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
  --topic-tool-rendering \
  --topic-markdown \
  --timeout 160
```

This runs a successful shell tool, an intentionally failing shell tool, and a
Markdown/code-block reply inside forum topic `35`. It passed on 2026-05-12 after
fixing Lemon action export so bash `exit_code != 0` renders as a failed action
in channel tool-status messages. The live proof observed `✓ echo OK ...`,
`✗ sh -c 'echo FAIL ...; exit 7' -> ... Command exited with code 7`, and
Telegram `MessageEntityBold` / `MessageEntityPre` entities in the final
Markdown reply.

Topic approval runner:

```bash
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
  --topic-approval \
  --approval-topic-id 35 \
  --timeout 180
```

This forces bash approval through an approval-enabled test profile, sends a real
bash command inside forum topic `35`, clicks Telegram `Approve once`, verifies
the approval message edits to `Approval: approve once`, observes
`✓ echo APPROVED ...`, and verifies the final reply stays in the same topic. It
passed on 2026-05-12 after fixing Telegram approval rendering to use the
adapter's `send_message/5` shape, with approval message `16668`, status message
`16667`, and final reply `16669`.

Topic long-output runner:

```bash
scripts/live_telegram_matrix.py --skip-dm --topic-id 35 \
  --topic-long-output \
  --long-output-topic-id 35 \
  --timeout 120
```

This sends three fast `/echo` parts into forum topic `35`, forcing a combined
answer above Telegram's single-message limit. It passed on 2026-05-12 with bot
chunks `16675`, `16676`, and `16677`, chunk lengths `3267`, `3204`, and `2936`,
combined length `9409`, the expected end marker, and all follow-up chunks still
inside topic `35`.

Topic file-get runner:

```bash
scripts/live_telegram_matrix.py --skip-dm --skip-topic \
  --topic-file-get \
  --file-get-topic-id 35 \
  --timeout 90
```

This creates an ignored proof file under `tmp/`, requests it through Telegram
`/file get` inside forum topic `35`, and verifies Telegram returns a real
document reply in the same topic. It passed on 2026-05-12 with user command
`16682` and document message `16683` for
`telegram-proof-lemon-file-35-1778604213.txt`.

Topic restart/dedupe runner:

```bash
scripts/live_telegram_matrix.py --skip-dm --skip-topic \
  --topic-restart-seed \
  --restart-topic-id 35 \
  --timeout 60

# restart ./bin/lemon

scripts/live_telegram_matrix.py --skip-dm --skip-topic \
  --topic-restart-verify \
  --restart-topic-id 35 \
  --restart-nonce lemon-restart-seed-35-1778604398 \
  --restart-reply-id 16685 \
  --timeout 35
```

This seeds a handled forum-topic message, restarts the runtime, watches for any
duplicate replay of the seed nonce, and then sends a fresh post-restart prompt.
It passed on 2026-05-12: seed message `16684` received reply `16685`, the
post-restart verifier observed no duplicates, and fresh message `16686`
received reply `16687` in topic `35`.

Current Discord live runner:

```bash
scripts/live_discord_matrix.py --list-channels
scripts/live_discord_matrix.py --channel-id 1475727417372049419 --bot-api-smoke
scripts/live_discord_matrix.py --channel-id 1475727417372049419 --bot-token-index 0 --sender-bot-token-index 1 --wait-user-inbound --reset-session-between-checks --timeout 120
scripts/live_discord_matrix.py --channel-id 1475727417372049419 --bot-token-index 0 --sender-bot-token-index 1 --wait-thread-inbound --per-check-thread --reset-session-between-checks --timeout 180 --result-path tmp/discord-thread-inbound-proof.json
scripts/live_discord_matrix.py --channel-id 1475727417372049419 --bot-token-index 0 --sender-bot-token-index 1 --manual-matrix --reset-session-between-checks --timeout 300 --result-path tmp/discord-live-proof.json
LEMON_EVAL_API_KEY_SECRET={local-zai-secret} LEMON_EVAL_PROVIDER=zai LEMON_EVAL_MODEL=glm-5-turbo LEMON_EVAL_API_TYPE=openai_completions LEMON_EVAL_BASE_URL=https://api.z.ai/api/coding/paas/v4 scripts/test live-eval
```

This uses the established Discord bot credentials from
`~/.zeebot/api_keys/discord.txt` or `DISCORD_BOT_TOKEN` without printing token
values. The runner accepts labeled bot-token lines, common bot-token aliases,
optional `Bot ` prefixes, and bare-token lines. The first command discovers the
allowed test guild/channel shape. The second command verifies bot API
reachability only and is not a Lemon inbound proof. The third command is the
required live proof path: it sends or prints a nonce prompt from an external
sender, then waits for the Lemon bot to reply with the exact expected text in
the same channel. The sender can be a human Discord user or the second Lemonade
Stand bot token. With the second bot sender, `--reset-session-between-checks`
uses the local control-plane `sessions.reset` method so each matrix prompt has a
fresh Discord channel session. The manual matrix extends that path with
external-sender prompts for markdown/code rendering, long-output chunking, tool
success/failure markers, and Discord attachment delivery. The adapter correctly
ignores self-authored responder messages and webhooks, so this live matrix is
the support-boundary proof for Discord's text-first path. The manual
matrix stops on the first failed check by default so later prompts are printed
only after earlier checks pass; `--continue-on-failure` is diagnostic-only and
does not produce release evidence.

Discord live result on 2026-05-12:

- `scripts/live_discord_matrix.py --list-channels` resolved bot
  `Zeebot-Debug`, guild `1475727416549969980`, and text channel `general`
  `1475727417372049419`.
- `scripts/live_discord_matrix.py --channel-id 1475727417372049419
  --bot-api-smoke` passed with message id `1503803470493257890` after verifying
  credential-file loading with `DISCORD_BOT_TOKEN` unset.
- `mix test apps/lemon_channels/test/lemon_channels/adapters/discord/transport_test.exs`
  passed, proving self-authored and webhook messages are ignored before routing.
- `scripts/live_discord_matrix.py --channel-id 1475727417372049419 --bot-token-index 0 --sender-bot-token-index 1 --manual-matrix --reset-session-between-checks --timeout 300 --result-path tmp/discord-live-proof.json`
  passed. It used Zeebot-Debug as the external sender and Zeebot as the Lemon
  responder, and covered exact prompt/reply, markdown/code rendering,
  long-output chunking, tool success/failure rendering, and text-file attachment
  delivery.
- The live run found and fixed a Discord outbound chunking bug: normal Discord
  messages are capped at 2000 characters, so long text is now split into
  1900-character chunks before delivery.

Discord public-thread live result on 2026-05-16:

- `scripts/live_discord_matrix.py --channel-id 1475727417372049419 --bot-token-index 0 --sender-bot-token-index 1 --wait-thread-inbound --per-check-thread --reset-session-between-checks --timeout 180 --result-path tmp/discord-thread-inbound-proof.json`
  passed. It used Zeebot-Debug as the external sender and Zeebot as the Lemon
  responder, created public thread `1505317536286376089` under Lemonade Stand
  `general` `1475727417372049419`, reset the thread-scoped session key, sent
  nonce `lemon-discord-thread-1778966068`, and observed the Lemon reply inside
  the same thread. This promotes public-thread prompt/reply routing for the
  supported Discord boundary; it does not promote Discord DMs or client-click
  slash-command behavior.

Exit criteria:

- The Hermes-vs-Lemon feature matrix is complete and current.
- No P0 parity or reliability gap remains in the parity scorecard.
- P1 gaps have BEAM-native implementation plans with owners, acceptance tests,
  and support-boundary language for the interim state.
- Deterministic evals cover every harness behavior that can be tested without
  external credentials.
- Live-model evals cover the core behaviors that depend on actual provider
  behavior.
- Telegram DM, group chat, and forum-topic live matrices pass under established
  real credentials, including topic isolation, cancellation, approvals, tool
  status, markdown/code rendering, long output, document delivery, and
  restart/dedupe.
- Discord live matrices pass under established real credentials with an
  external-sender inbound prompt, including the supported channel/thread/session
  boundary. Bot API reachability alone is not sufficient.

### Workstream 3: Installation and Setup

Goal: a fresh user can get Lemon running without becoming a maintainer.

Target install paths:

1. Source-dev path for contributors.
2. Release-runtime path for users who do not need Mix.
3. Attached-client path for TUI/web against an existing runtime.

Required improvements:

- Verify `docs/user-guide/setup.md` against a clean environment.
- Make `mix lemon.setup` the canonical interactive path.
- Make `mix lemon.doctor` actionable, with specific fixes and links.
- Ensure Linux and macOS guidance is current.
- Decide the 1.0 supported package path:
  - release tarball only
  - release tarball plus install script
  - package-manager distribution later
- Document minimum provider setup for Anthropic, OpenAI, and OpenAI-compatible
  local endpoints.
- Keep secrets guidance consistent across README, setup guide, config docs, and
  doctor output.

Exit criteria:

- A fresh Linux machine can run Lemon from release artifacts.
- A fresh contributor machine can run Lemon from source.
- A user can configure one provider and complete one successful agent run.
- Failed provider, missing secret, bad config, and missing runtime dependency
  cases produce actionable doctor output.

### Workstream 4: Packaging, Release, and Update

Goal: make Lemon publishable and upgradeable.

Existing pieces:

- release profiles in `docs/release/deployment_flows.md`
- CalVer and channels in `docs/release/versioning_and_channels.md`
- release workflow
- product smoke workflow
- staged `mix lemon.update`

Required improvements:

- Verify the release workflow produces usable artifacts.
- Verify artifact names, checksums, and manifest shape.
- Decide which profiles are public:
  - `lemon_runtime_min`
  - `lemon_runtime_full`
  - `sim_broadcast_platform` if it remains a separate public target
- Make update behavior honest:
  - if remote update download is not implemented, docs must say so clearly
  - if stage-1 update is config and bundled-skill sync only, docs must say so
- Create a release checklist.
- Create a rollback checklist.
- Add a support policy for stable, preview, and nightly.
- Ensure changelog release sections are useful to users, not only maintainers.

Exit criteria:

- A tagged release builds artifacts through CI.
- Artifacts boot locally.
- Manifest checksums verify.
- Release docs match actual behavior.
- Stable and preview channels have clear expectations.

### Workstream 5: TUI, Web, and Channel Polish

Goal: each primary interface should have a complete daily-use path.

Primary surfaces:

- TUI for local development.
- Web UI for observability and operations.
- Telegram for remote chat access.

TUI launch criteria:

- connect to runtime reliably
- start or resume sessions
- show streaming output
- show tool progress and failures
- allow cancellation and follow-up
- make repo/cwd context clear

Web UI launch criteria:

- list sessions and runs
- inspect run timeline
- inspect tool calls and failures
- inspect subagent tree
- inspect approvals
- inspect memory searches and skill loads
- inspect cron/background runs
- expose logs or diagnostic references
- show health and version information

Telegram launch criteria:

- setup guide works end-to-end
- allowed chat configuration is safe by default
- command list is accurate
- long-running runs have useful progress
- cancellation works
- media and markdown behavior is documented
- error states are understandable
- direct-message prompt/reply works with real credentials
- group-chat prompt/reply works with real credentials
- forum-topic prompt/reply preserves `message_thread_id`
- simultaneous forum topics are isolated
- topic-scoped cancellation does not leak late replies
- approvals render and resolve inside the originating topic
- tool success/failure status renders clearly
- long output chunks without losing topic context
- document delivery works for the stable text-first support boundary
- restart/reconnect does not duplicate handled topic messages

Discord launch criteria:

- bot credential and target guild/channel discovery works without exposing
  secrets
- external sender-authored inbound prompt creates a Lemon run
- Lemon replies in the same supported channel or thread
- mention/free-response behavior matches the documented support boundary
- session isolation is proven for the supported channel/thread shape
- cancellation, tool success/failure, markdown/code, long-output, and file
  delivery are proven before Discord is promoted from preview

Exit criteria:

- Each surface has a documented happy path.
- Each surface has at least one smoke or integration check.
- Failure states are visible and actionable.
- Telegram launch claims are backed by live DM, group, and forum-topic proof.
- Discord launch claims are blocked until live external-sender inbound proof passes.

### Workstream 6: Website and Public Docs

Goal: create a public face for Lemon that can convert an interested user into a
successful install.

Existing pieces:

- VitePress docs scaffold in `docs/.vitepress/config.js`
- docs-site workflow
- root README
- user-guide docs
- architecture docs

Website information architecture:

1. Home
   - what Lemon is
   - who it is for
   - why local-first matters
   - primary install CTA
   - secondary docs CTA
2. Install
   - release install
   - source install
   - provider setup
   - first run
3. Features
   - coding agent
   - memory
   - skills
   - subagents
   - schedules
   - channels
   - web/TUI
4. Compare
   - Hermes-class harness parity
   - Claude Code, Codex, OpenCode, Pi positioning
   - honest strengths and gaps
5. Docs
   - user guide
   - config
   - troubleshooting
   - architecture
6. Support
   - issue templates
   - support bundle
   - security policy
   - release channels

Website acceptance criteria:

- The homepage explains Lemon in one screen.
- Install instructions are not buried in architecture docs.
- Feature claims link to docs or demos.
- The site can be built in CI.
- Broken internal docs links are treated as a real release blocker once the
  baseline is cleaned up.

### Workstream 7: Testing and Evaluation

Goal: confidence should come from product-level gates, not only unit tests.

Canonical local lanes:

- `scripts/test fast`
- `scripts/test quality`
- `scripts/test clients`
- `scripts/test eval-fast`
- `scripts/test all`

Release and product lanes:

- release smoke
- product smoke
- docs site build
- live-model evals for release candidates

Required improvements:

- Make product smoke prove real user flows:
  - boot packaged runtime
  - health check
  - doctor check
  - memory search probe
  - skill lint
  - representative control-plane request
  - web health check for full profile
- Add a release-candidate checklist that includes:
  - deterministic evals
  - live-model evals
  - client builds
  - docs build
  - artifact boot
  - update/rollback dry run
- Keep unit lanes hermetic and credential-safe.
- Add focused tests for any new setup, doctor, release, or support-bundle
  behavior.

Exit criteria:

- `scripts/test all` is meaningful for BEAM-centric local confidence.
- Client CI catches UI regressions.
- Product smoke catches packaged-runtime regressions.
- Release candidates run live-model evals before stable promotion.

### Workstream 8: Observability and Supportability

Goal: maintainers should be able to diagnose user issues from structured
evidence.

Required capabilities:

- support bundle command or doctor mode
- version and build metadata
- config redaction report
- runtime health snapshot
- provider configuration status without secret exposure
- recent run summary
- recent error summary
- log file locations
- extension and skill inventory
- memory store status
- channel adapter status
- release channel and update status

Possible command:

```bash
mix lemon.doctor --bundle
```

or, for release runtime:

```bash
lemon_runtime_full doctor --bundle
```

Support bundle rules:

- never include API keys, OAuth tokens, private keys, cookies, or raw secrets
- redact provider headers and command env
- include `provider_diagnostics.json` with provider setup shape, routing shape,
  and credential-reference counts without raw API keys, secret names, base URLs,
  env var names, provider responses, or model prompts
- include proof diagnostics that preserve both generic `cleanup` maps and
  proof-level `redaction` maps, so extension/WASM proof artifacts can show
  omission of raw cwd, session ids, params, paths, manifests, distribution
  URLs, and tool payloads without embedding raw proof files
- include enough version/config state to reproduce common issues
- write a single archive or directory path
- print exactly what was included

Docs required:

- troubleshooting guide
- support bundle guide
- log locations
- common provider errors
- common Telegram errors
- common release boot errors
- upgrade and rollback guide

Exit criteria:

- A GitHub issue template asks for the support bundle.
- The support bundle can be generated from source-dev and release-runtime paths.
- A maintainer can identify setup, config, provider, release, and channel
  classes of failure from the bundle.

### Workstream 9: Security and Trust

Goal: users should understand what Lemon can do, what it will ask approval for,
and how secrets and untrusted content are handled.

Existing pieces:

- `SECURITY.md`
- `docs/security/agent-safety-contract.md`
- tool policies
- approval gates
- secret screening for memory and skill synthesis
- skill install/update audit
- untrusted tool-output boundary

Required improvements:

- Make the public security model easy to read.
- Document default approval behavior for shell and file writes.
- Document what skills can and cannot do.
- Document extension trust levels.
- Keep the launch-focused prompt-injection tests for web, email, skill, and
  extension-style tool surfaces green.
- Add broader adversarial variant depth after 1.0.
- Ensure website and README do not imply unsafe automation is enabled by
  default.

Exit criteria:

- New users can understand the safety model before running tools.
- Security docs match actual tool policy behavior.
- Prompt-injection regressions are covered by deterministic tests.

### Workstream 10: Documentation Maintenance

Goal: documentation remains accurate as launch work lands.

Rules:

- Every doc in `docs/` must be registered in `docs/catalog.exs`.
- Product docs should distinguish implemented, partial, and planned behavior.
- README should stay short and correct.
- Deep details should live in docs, not app guides.
- Any code change that changes behavior must update the relevant docs.

Immediate cleanup candidates:

- Replace stale roadmap references with this plan or restore a real roadmap.
- Ensure VitePress navigation points only at existing docs.
- Make release/update docs match actual `mix lemon.update` behavior.
- Keep changelog entries user-readable.

Exit criteria:

- `mix lemon.quality` passes documentation freshness checks.
- Docs site builds.
- Internal links are clean enough to make link failures blocking.

## Launch Gap Execution Ledger

This is the first repo-backed audit snapshot for Milestone 1. It should be
updated as each gap is closed or reclassified.

Snapshot date: 2026-05-11

Priority:

- P0: must be resolved before Lemon can claim Hermes-class stable readiness.
- P1: parity work that should land before broad "Hermes, but better, on the
  BEAM" positioning.
- P2: ecosystem breadth, polish, or hardening that can follow once the core
  parity claim is credible.

Status:

- Done: no remaining action for this gap in the current milestone.
- Partial: some remediation landed, but launch work remains.
- Open: no implementation or proof exists yet.
- Blocked: needs a product or scope decision before implementation.

| ID | Area | Owner lane | Priority | Status | Current evidence | Gap | Next action |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G1 | Launch goal | Product / Docs | P0 | Done | `docs/plans/lemon-1.0-mainstream-readiness.md` exists, is registered in `docs/catalog.exs`, and is linked from `README.md`, `docs/README.md`, and VitePress navigation. | The launch goal needed a durable repo artifact. | Keep this document as the execution ledger. |
| G2 | Roadmap truth | Docs | P1 | Done | Root `README.md` and `docs/README.md` now point at this plan instead of a missing `ROADMAP.md`. A repo-wide stale-reference pass found no remaining main-checkout `ROADMAP.md` references outside this execution ledger; only old `.worktrees/` review branches still contain their own roadmap files. | No remaining launch-blocking roadmap-truth gap. | Keep this plan as the launch roadmap unless a separate public roadmap is intentionally restored. |
| G3 | Release/update truth | Runtime / Docs | P0 | Done for docs truth | `apps/lemon_core/lib/mix/tasks/lemon.update.ex` says remote update download is not available; `docs/release/versioning_and_channels.md` now describes current stage-1 update behavior. | Remote binary update is not implemented. | Treat remote update as a separate launch gap only if 1.0 requires auto-update. |
| G4 | Release artifact scope | Release | P0 | Done for initial 1.0 scope | `.github/workflows/release.yml` builds `lemon_runtime_min` and `lemon_runtime_full` on `ubuntu-latest`; release docs now state Linux `x86_64` artifact scope. `docs/release/release_checklist_and_support_policy.md` makes Linux `x86_64` tarballs the initial stable 1.0 release artifact support target. | macOS and other release artifacts remain future release-matrix work. | Reopen only when expanding supported artifact platforms. |
| G5 | Product smoke strength | Release / Harness | P0 | Done for deterministic packaged runtime | `.github/workflows/product-smoke.yml` now boots a release, checks control-plane HTTP health, handshakes over the control-plane WebSocket protocol, calls `health`, submits a deterministic `echo` agent run through `agent`, waits through `agent.wait`, checks web `/healthz` for `lemon_runtime_full`, lints skills, and runs adaptive gate checks. | Product smoke intentionally avoids live provider credentials and does not cover memory-search behavior. | Keep live provider and memory behavior covered by eval, focused tests, and manual release-candidate checks rather than CI product smoke. |
| G6 | Doctor support mode | Runtime / Support | P0 | Done | `mix lemon.doctor --bundle` and release-runtime `LemonCore.Doctor.CLI.bundle!()` now write a redacted zip containing the doctor report, runtime metadata, selected environment shape, redacted Lemon config files, proof-artifact diagnostics, redacted channel readiness, compact launch readiness, and redacted cron diagnostics. Product smoke verifies release support-bundle generation from the packaged artifact, and `scripts/verify_release_runtime_boot` now inspects generated release-runtime support bundles for core entries including `channel_readiness.json` and `readiness_summary.json`. `readiness_summary.json` is backed by `LemonCore.Doctor.ReadinessSummary` and carries the same doctor/channel/media/proof rollup plus shared `LemonCore.Doctor.ProofLaunchGates` proof-gate summary as `mix lemon.readiness` / `./bin/lemon readiness` without raw ids, prompts, provider responses, proof paths/details, or secret values. `proof_diagnostics.json`, read-only `proofs.status`, and Web `/ops` scan `.lemon/proofs/*proof*.json`, `.lemon/proofs/*-latest.json`, and `tmp/*proof*.json` for pass/fail/skip counts, generated timestamps, safe reason kinds, safe proof-scope/check-name counts, latest redacted check status, file/proof hashes, and safe Discord slash/live-matrix coverage counts and booleans, including slash-registration coverage, without raw paths, filenames, prompts, provider responses, proof details, proof file contents, or raw Discord ids/messages/tokens. `cron_diagnostics.json` summarizes cron job/run counts, status/trigger counts, timestamps, lifecycle audit shape, and hashed prompt/output/error/session/agent/memory metadata without raw prompts, outputs, errors, session ids, agent ids, memory paths, audit ids/reasons, or meta values; `scripts/live_cron_diagnostics_smoke.exs` proves the support-bundle entry and redaction boundary. `scripts/live_cron_channel_origin_smoke.exs` writes a redacted channel-origin proof artifact for Telegram- and Discord-shaped cron completion delivery. | Bundle redaction intentionally excludes logs, memory contents, private prompts, tool outputs, raw proof contents, and generated artifacts rather than collecting them. | Keep redaction tests current as support data expands. |
| G7 | Issue triage | Support | P1 | Done | `.github/ISSUE_TEMPLATE/bug_report.md` distinguishes source-dev vs release-runtime installs and asks for the appropriate redacted support-bundle command in each path. | Users still need to review bundles before attaching them. | Keep artifact naming in issue templates aligned with the supported release profiles. |
| G8 | Website scaffold | Product / Docs | P0 | Partial | `docs/index.md` now provides a VitePress homepage with positioning, launch-stage status, and entry points; `docs/install.md` provides a short install landing page with source install, provider setup, doctor, and release-artifact status; `docs/compare.md`, `docs/demo.md`, and `docs/support.md` add public-facing comparison, deterministic demo, and support-boundary pages; navigation links the full product-doc set. `docs/assets/launch/web-session-proof-2026-05-11.png` and `docs/assets/launch/web-ops-proof-2026-05-11.png` provide initial launch screenshots for the Web interface. | The site still needs broader launch media and final artifact wording. | Keep release artifact language aligned with the locally verified artifact contract and capture TUI/Telegram launch visuals when those live proofs pass. |
| G9 | Docs site link gate | Docs | P1 | Done | VitePress navigation links to existing launch, user guide, architecture, testing, release, and contributor docs. The docs markdown link baseline passes locally with `markdown-link-check`, and `.github/workflows/docs-site.yml` now fails when the link check reports broken links. `scripts/verify_docs_site` now installs docs dependencies in a temp copy, runs high-severity docs-tooling audit, builds the VitePress site, and runs the markdown link check without leaving `docs/node_modules`, `docs/package-lock.json`, or `docs/.vitepress/dist` in the repo. | External links can still drift after a green CI run. | Keep `.mlc.json` focused on intentional localhost/internal exceptions and fix broken external docs links when they appear. |
| G10 | Hermes parity | Harness | P0 | Partial | `docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md` is the source-grounded Hermes-vs-Lemon feature matrix, refreshed against `/home/z80/dev/hermes-agent` `origin/main` at `4ad5fa702`. `docs/plans/lemon-channel-command-parity-matrix-2026-05-12.md` maps Lemon Telegram and Discord commands against Hermes messaging slash commands. `docs/plans/lemon-hermes-agent-harness-parity-scorecard.md` tracks substantial harness work, including tool lifecycle, memory, skills, delegation, safety, and live-model slices. Provider-backed live eval and provider-backed goal-judge proof now pass against Z.ai `glm-5-turbo`. Discord bot-to-bot live proof now passes for exact prompt/reply, markdown/code, long-output chunking, tool success/failure rendering, and text-file attachment delivery. A first BEAM-native kanban foundation now exists through `LemonCore.KanbanStore`, redacted kanban support-bundle diagnostics, control-plane `kanban.board.*` / `kanban.task.*` methods, expiring leases, `LemonAutomation.KanbanDispatcher` supervised lease/reclaim/worker-result handling plus deterministic bounded multi-worker/crash/reclaim proof, production-shaped real-`KanbanRunWorker` bounded-concurrency proof, and provider-backed live real-worker proof against Z.ai `glm-5-turbo`, control-plane `kanban.dispatcher.*` operator controls, `KanbanRunWorker` router-backed task submission with per-task git worktree cwd when the board workspace is a git repository, a default coding-agent `kanban` tool for model-facing board/task management, redacted Web `/ops` board/task visibility, TUI `/kanban` board/task/archive/dispatcher controls, Telegram `/kanban` commands with credential-backed topic proof for create/task/comment/show/archive redaction, and Discord `/kanban` slash commands. A BEAM-preview `lsp_diagnostics` tool now runs workspace-aware file diagnostics with graceful fallback, and `write`, `edit`, and `patch` can opt into post-edit baseline/delta diagnostics; focused coding-agent tests cover the tool and all three mutation hooks. `LemonCore.MemoryProvider` and `LemonCore.MemoryProviders` now provide a supervised BEAM-native memory-provider boundary behind `search_memory`, with local SQLite as the default provider, safety-screened ingest fan-out, scoped search fan-out, provider failure isolation, and redacted `memory_diagnostics.json` support-bundle proof, read-only `memory.status`, and Web `/ops` memory-provider visibility, and Web `/ops` now includes recent redacted LSP proof artifacts and proof-check summaries inside the LSP diagnostics panel. Cron creation/update now accepts supported schedule shorthands and stores normalized cron expressions; cron diagnostics now have a core-owned, redacted support-bundle surface plus `scripts/live_cron_diagnostics_smoke.exs` proof for counts, retry policy/lineage, redaction, and bundle inclusion; scheduled ticks now suppress duplicate starts when a persisted active run exists, active runs older than the job timeout recover as `:timeout`, channel-origin summaries enqueue through `LemonChannels` with `scripts/live_cron_channel_origin_smoke.exs` proof for Telegram- and Discord-shaped channel-peer delivery, scheduled failures/timeouts can retry as separate `:retry` runs with bounded policy and lineage metadata, active cron runs can be aborted through control-plane `cron.abort`, the model-facing cron tool, Web `/ops`, and TUI `/cron abort <run-id>`, and operator-owned no-agent command cron jobs can be created and updated without assigning an agent. | Lemon has strong harness parity, but not yet broad product parity for browser automation, media/vision/TTS, ACP/API/editor integration, checkpoint rollback, multi-backend terminal execution, plugin/provider ecosystem breadth, full language-server diagnostics breadth, provider routing/fallback/credential pools, richer messaging, broad slash-command parity, and deployed external-channel cron proof. | Treat these as BEAM-native parity workstreams, not permanent exclusions. Design each as supervised processes/state machines with telemetry, support bundles, and eval proof before claiming stable parity. |
| G11 | UI and live-channel reliability | Interfaces / Support | P0 | Partial | `docs/plans/lemon-1.0-interface-supportability-audit-2026-05-11.md` records broad TUI, Web, control-plane, and supportability APIs. `docs/plans/lemon-1.0-interface-proof-pack-2026-05-11.md` records TUI/Web source-runtime proofs and Telegram live proof for `/cwd`, progress rendering, prompt round trip, bare `/cancel`, approval-button resolution, invalid-model errors, 2026-05-12 DM recovery from an interrupted persisted tool call, Telegram forum-topic routing in Lemonade Stand topic `35`, overlapping forum-topic isolation for topics `35` and `16456`, topic-scoped cancellation, successful and failing tool-status rendering, markdown/code rendering, group-topic approval-button resolution in topic `35`, long-output chunking inside topic `35`, `/file get` document delivery in topic `35`, and restart/dedupe behavior in topic `35`. `scripts/live_telegram_matrix.py --timeout 90` now provides a repeatable credential-backed DM/topic runner and passed on 2026-05-12. The topic-isolation, topic-cancel, topic-tool-rendering/markdown, topic-approval, topic-long-output, topic-file-get, and topic-restart/dedupe runner variants also passed on 2026-05-12. `scripts/live_discord_matrix.py --manual-matrix --sender-bot-token-index 1 --reset-session-between-checks` passed on 2026-05-12 and produced `tmp/discord-live-proof.json`; `scripts/live_discord_matrix.py --wait-thread-inbound --per-check-thread --sender-bot-token-index 1 --reset-session-between-checks --result-path tmp/discord-thread-inbound-proof.json` passed on 2026-05-16 for public-thread prompt/reply routing. | Telegram is live-proven for the text-first plus document-delivery boundary. Discord is live-proven for the text-first plus file-delivery boundary through second-bot inbound messages, including public-thread prompt/reply; DMs, slash-command client-click breadth, voice, and richer media remain BEAM-native parity targets. | Keep the live proof scripts and deterministic regressions current, and promote any newly discovered live-channel bugs into focused tests. |
| G12 | Fresh install proof | Runtime / Docs | P0 | Done for initial 1.0 scope | `docs/plans/lemon-1.0-fresh-install-proof-2026-05-11.md` records a clean source-copy install proof with isolated `HOME`, `MIX_HOME`, and `HEX_HOME`; `mix deps.get`, `mix compile`, and `mix lemon.doctor --bundle` completed with no doctor failures. It also records a clean Docker source-install proof on the current supported toolchain, Elixir 1.19.5 / Erlang/OTP 28, using `elixir:1.19.5-otp-28`; `mix deps.get`, `mix compile`, and `mix lemon.doctor --bundle` completed with no doctor failures. The simulator UI Dockerfile now builds on the current Hex.pm Elixir/OTP image, `hexpm/elixir:1.19.5-erlang-28.5-debian-bookworm-20260505`, and `docker manifest inspect` confirmed that image tag exists. The same proof file now records isolated `mix lemon.setup --non-interactive`, `mix lemon.setup runtime --profile runtime_min`, and fake-token `mix lemon.setup provider` checks for Anthropic and OpenAI; the runtime check found and fixed a stale release command, now covered by setup task tests. `docs/plans/lemon-1.0-release-artifact-proof-2026-05-11.md` records refreshed `2026.05.0` local tarball proofs for `lemon_runtime_min` and `lemon_runtime_full`: checksum verified, extracted runtime booted, `/healthz` returned ok, and release `eval` generated a support bundle. Setup docs now include `mix local.hex --force`, real `mix lemon.setup` / `mix lemon.secrets.*` commands, an OpenAI-compatible endpoint example, and prerequisites updated to Elixir 1.19.5, Erlang/OTP 28.5, and Node.js 24 LTS. | No launch-blocking install or local artifact proof gap remains for the stated source-install plus Linux tarball boundary. | Keep source-install and local artifact proof current when setup or release profiles change. |
| G13 | Security posture | Security / Docs | P0 | Done for initial 1.0 scope | `SECURITY.md`, `docs/security/agent-safety-contract.md`, and `docs/security/safety.md` exist. The public safety page explains Lemon's local-first safety model, recommended approval defaults, secrets handling, high-risk operations, support-bundle redaction, and vulnerability reporting. The parity scorecard tracks tool policies, approvals, memory screening, skill audit, and untrusted boundaries. Deterministic prompt-injection coverage now spans web fetch output, inbound email prompts, skill prompt rendering, and generic untrusted extension-style tool results. | Broader adversarial prompt-injection variant depth must expand as browser, media, plugins, MCP, and channel attachments become stable surfaces. | Keep the launch-focused safety tests green and add deeper adversarial variants alongside each new parity surface. |
| G14 | Release channel support | Release / Support | P1 | Done for initial 1.0 scope | `docs/release/versioning_and_channels.md` defines stable, preview, and nightly channels. `docs/release/release_checklist_and_support_policy.md` now defines the release-candidate checklist, optional publish checklist, rollback checklist, initial support matrix, and support boundaries. `.github/workflows/release.yml` publishes `manifest.json` with artifact sizes and SHA-256 checksums, verifies the assembled artifact directory before publishing, and requires matched release files. `scripts/verify_release_artifacts` verifies manifest entries against downloaded files. `scripts/verify_release_runtime_boot` verifies manifest/checksums, extracts both runtime profiles, boots them without Mix, checks health, and generates support bundles. `.github/workflows/live-eval.yml` provides a manual release-candidate live-model eval lane on Elixir 1.19.5 / Erlang/OTP 28.5. `scripts/audit_1_0_readiness` wraps the final release-candidate audit for version metadata, release notes, CI/docs policy, canonical local test lanes, docs-site verification, local artifact manifest/runtime boot verification, provider-backed live eval, Discord external-sender manual live result JSON, matching redacted `.lemon/proofs` Discord live proof artifact, Discord `/media` registration result JSON plus matching redacted proof artifact, Discord all-command slash registration result JSON plus matching redacted proof artifact, completed Discord DM/free-response/real slash client-click proof artifacts, and completed redacted image/TTS/STT/vision/video provider proof artifacts for support/doctor surfaces. `scripts/lint_ci_docs.sh` now fails if first-party version metadata drifts from `mix.exs`, first-party BEAM toolchain pins drift from Elixir 1.19.5 / OTP 28.5, docs-site verification or canonical local test lanes fall out of the final readiness audit, the manual live-eval workflow is missing, not manual-only, disconnected from `scripts/test live-eval`, or undocumented, or the final audit stops requiring documented Discord external-sender live proof plus redacted proof artifacts, Discord `/media` and all-command registration proof plus redacted proof artifacts, Discord DM/free-response/client-click proof artifacts, or completed provider-backed media proof artifacts. `CHANGELOG.md` has a `## [2026.05.0]` release section, and `scripts/prepare_release_notes 2026.05.0` passes. | Remote binary update remains out of 1.0 scope. | Keep release notes versioned and keep local artifact verification in the readiness audit. |
| G15 | Dependency audit | Docs / Security | P1 | Done for initial 1.0 scope | `npm audit --json` in `docs/` reports three moderate advisories in `vitepress -> vite -> esbuild`, no high or critical advisories, and `fixAvailable: false`. `docs/release/release_checklist_and_support_policy.md` now defines the dependency audit policy: high/critical runtime or docs-tooling advisories block release candidates; moderate docs-build tooling advisories are accepted only when they do not ship in runtime tarballs, static docs build succeeds, link checking succeeds, there is no safe available fix, and the finding is recorded in the launch ledger. `.github/workflows/docs-site.yml` runs `npm audit --audit-level=high` after installing docs dependencies. | The accepted advisories can still be fixed later when VitePress publishes a safe dependency chain. | Revisit before public docs launch or when a safe VitePress/Vite/esbuild fix becomes available. |
| G16 | Live channel launch proof | Harness / Channels | P0 | Partial | Telegram and Discord adapters, delivery modules, and support docs exist. Telegram delivery supports topic/thread IDs and has live proof for DM recovery, forum-topic prompt/reply, overlapping topic isolation, topic cancellation, tool-status rendering, markdown/code, approval buttons, long-output chunking, `/file get`, restart/dedupe, `/kanban`, `/checkpoint`, generated-SVG delivery, and generated-audio delivery in topic `35`. Discord has live proof for second-bot channel prompt/reply, markdown/code, long output, tool success/failure rendering, text-file attachment delivery, public-thread prompt/reply, free-response unmentioned-thread prompt/reply, generated-SVG delivery, generated-audio delivery with one WAV attachment, `/kanban`, `/checkpoint`, `/media`, all-command registration, and restart/reconnect replay after a deliberate runtime restart with no duplicate seed reply and a fresh post-restart response. Deterministic Discord proof covers slash payload decoding, safe mention output, approval components, cancel/keepalive components, duplicate `MESSAGE_CREATE` suppression through runtime restart, bot-message policy, and free-response trigger-mode storage. Live matrix scripts now write sanitized `--proof-path` artifacts for support bundles, doctor gates, `proofs.status`, and Web `/ops` while keeping raw operator handoff data under `tmp/`. Support bundles include `channel_diagnostics.json` for redacted Telegram/Discord enablement, credential-shape booleans, binding counts, file-transfer/generated-file auto-send shape, Telegram voice-transcription shape, Discord DM/free-response/slash-command readiness, inbound-replay proof, and bot-message policy without bot tokens, secret names, chat IDs, channel IDs, guild IDs, or message bodies. | Telegram and Discord are live-proven for the current text-first plus file/document/generated-media boundary; Discord public-thread prompt/reply and restart/reconnect replay are live-proven; Telegram `/kanban`, `/checkpoint`, generated-SVG, and generated-audio topic controls are live-proven; Discord command registration, generated-SVG, generated-audio, deterministic component/control paths, and transport-restart inbound-dedupe subsets are proven. Discord DMs, voice, and real client-click slash execution remain BEAM-native parity targets. | Keep channel claims bounded to proven behavior while adding live matrices for DM, provider-backed media/voice, and real Discord client-click parity. |
| G17 | BEAM-native browser/media parity | Harness / Runtime / Channels | P0 | Partial / BEAM preview | Lemon now has first-class supervised local browser automation through `browser_navigate`, `browser_snapshot`, `browser_get_content`, `browser_click`, `browser_type`, `browser_hover`, `browser_select_option`, `browser_upload_file`, `browser_download`, `browser_press`, `browser_scroll`, `browser_back`, `browser_wait_for_selector`, `browser_evaluate`, `browser_events`, `browser_get_cookies`, `browser_set_cookies`, `browser_clear_state`, `browser_screenshot`, and `browser_analyze`; `browser.status`, Web `/ops`, and support bundles expose redacted local-driver and artifact metadata. `browser_navigate` now applies BEAM-side route classification and guardrails before worker dispatch: default `auto` preserves local-first behavior while classifying public/private/local-document targets, `public` rejects local/private/data/file targets, `local` rejects public web targets, and metadata endpoints are blocked for every route. `browser_evaluate` executes page-scoped JavaScript against the current page, returns untrusted output, is treated as dangerous/external by policy, and redacts evaluated expressions from progress. `browser_hover` and `browser_select_option` cover menu/form interaction workflows; select-option is policy-gated as dangerous/external, hover is external, and progress redacts selectors plus selected values. `browser_upload_file` covers project-local file-input workflows; it is policy-gated as dangerous/external, resolves paths on the BEAM side, rejects files outside the current project, and redacts selectors plus upload paths from progress. `browser_download` covers supervised download workflows; it is policy-gated as dangerous/external, optionally clicks a selector before waiting for the Playwright download event, saves into a managed project-local artifact path when no path is supplied, rejects out-of-project output paths, and redacts selectors plus download paths from progress. The browser node helper also supports `LEMON_BROWSER_CDP_ENDPOINT` / `--cdp-endpoint` attach-only mode for already-running local, container, or managed CDP endpoints without launching a replacement browser, with endpoint credential redaction on connection errors. Deterministic ExUnit proof and `scripts/live_browser_smoke.exs` now drive a local proof page through the supervised browser boundary, capture screenshot artifacts, prove selector waiting, page evaluation, hover, select-option, file upload, file download, route classification plus metadata/public-route blocking, set/read redacted cookies, explicitly opt into raw cookie-value proof, clear browser state, and prove one-step browser analysis with `completed_count: 20`, `failed_count: 0`, `progress_update_count: 40`, `model_visible_image_included: true`, `browser_to_media_vision_completed: true`, `browser_wait_for_selector_completed: true`, `browser_evaluate_completed: true`, `browser_hover_completed: true`, `browser_select_option_completed: true`, `browser_upload_file_completed: true`, `browser_upload_file_count: 1`, `browser_download_completed: true`, `browser_download_bytes: 22`, `browser_analyze_completed: true`, and `browser_cdp_attach_completed: true`. Focused tests prove browser route guards, metadata blocking, selector waiting with redacted progress, page evaluation with redacted expression progress, hover/select with redacted selector and selected-value progress, upload-file project-local validation with redacted selector/path progress, download output validation with redacted selector/path progress, cookie inspection with value redaction by default, explicit value opt-in, cookie seeding, and clear-state reset controls across the BEAM tool boundary. Screenshot writes enforce managed artifact retention: 14 days or the newest 100 files. `browser_screenshot` defaults to artifact-only metadata, `includeImage: true` returns a model-visible screenshot image block for explicit visual inspection, and `sendToChannel: true` requests final Telegram/Discord attachment delivery through redacted `auto_send_files` metadata while keeping raw base64 out of result details and support bundles. Telegram and Discord finalized-run attachment delivery now share an opt-in generated-file auto-send boundary: generated files require per-channel files config with auto_send_generated_files or the legacy image alias, count limits, and size limits, while explicit file-send requests still use the normal attachment path. `media_status` gives models a read-only redacted view of media job summaries, recent jobs, cleanup policy, and worker supervisor state. `media_generate_image` gives models a BEAM-supervised `local_svg` preview plus provider-backed `openai_image` and `vertex_imagen` paths through `LemonCore.MediaJobSupervisor`, writes managed SVG/PNG/JPEG/WebP artifacts, records redacted prompt hash/chars in `LemonCore.MediaJobs`, resolves OpenAI or Vertex credentials through Lemon runtime config/secrets when not injected, retries bounded transient provider failures, redacts provider errors, and can request generated-file channel delivery metadata with `sendToChannel: true`. `media_generate_speech` adds a matching BEAM-supervised `local_wav` plus provider-backed `openai_tts`, `elevenlabs_tts`, and `google_tts` paths, writes managed MP3/Opus/AAC/FLAC/WAV/PCM artifacts, records redacted text hash/chars in `LemonCore.MediaJobs`, resolves provider credentials through Lemon runtime config/secrets when not injected, retries bounded transient provider failures, redacts provider errors, and can request generated-file channel delivery metadata with `sendToChannel: true`. `media_transcribe_audio` adds BEAM-supervised local transcript preview and provider-backed `openai_transcribe` STT, accepts only project-local audio files, records audio fingerprints instead of raw paths/bytes, writes managed JSON/text transcript artifacts, redacts provider errors, and can request transcript attachment metadata. `media_analyze_image` adds BEAM-supervised local image-analysis preview and provider-backed `openai_vision`, accepts only project-local image files, records image fingerprints instead of raw paths/prompts/bytes, writes managed JSON/text analysis artifacts, redacts provider errors, and can request analysis attachment metadata. `media_generate_video` adds BEAM-supervised local MP4 preview and provider-backed `openai_video` and `vertex_veo`, creates/polls/downloads provider video jobs, writes managed MP4 artifacts, records prompt hashes instead of raw prompt text, redacts provider errors and provider job ids, and can request generated video attachment metadata. Live Telegram and Discord generated-SVG plus generated-audio delivery are proven through the same generated-file auto-send path, and proof diagnostics expose generated-audio coverage, Telegram document status, Discord attachment count, marker status, and redacted media proof fields. Media support remains preview. | Browser automation, image generation, TTS, STT, image analysis, and video generation are usable as local/provider-backed BEAM-supervised previews, but provider-specific Browserbase/Camofox lifecycle integration, broader hybrid routing policy, voice mode, and live image/TTS/video provider proof is still not Hermes-complete. | Keep browser/media claims bounded to preview while adding richer `/ops` controls, provider-backed browser vision/media job workers, channel delivery adapters, support-bundle redaction, and deterministic plus live proof for each media surface. |
| G18 | BEAM-native rollback/checkpoint parity | Harness / Runtime | P0 | Partial / preview | Lemon has git/worktree discipline, support bundles, strong file-tool tests, session checkpoints, and preview filesystem checkpoints. Shared checkpoint storage, filesystem diff/restore, and checkpoint lifecycle events now live in `LemonCore.Checkpoint`; `CodingAgent.Checkpoint` is a compatibility wrapper for coding-agent todo/requirement resume state. `write`, `edit`, and `patch` create restorable filesystem checkpoints when a session id is present, the `checkpoint` tool supports list, diff preview, per-file/full restore, and delete, checkpoint create/restore/delete events are emitted into introspection plus run/session streams, and `checkpoint.status`, Web `/ops`, Telegram/Discord `/checkpoint`, and support bundles expose redacted checkpoint metadata without file contents or raw paths. `exec` now supports configured risky-shell checkpoints: when `checkpoint_paths` or session-configured risky-shell paths are present and the shell command matches destructive patterns such as `rm`, `mv`, `sed -i`, `find ... -delete`, `git reset`, or `git clean`, Lemon snapshots those files before launch and returns the checkpoint id in tool details for restore. The control plane now uses `LemonCore.Checkpoint` for `checkpoint.diff` and `checkpoint.restore`, so Web/TUI/channel surfaces can share one rollback path without depending on `coding_agent`; responses hash session ids while keeping selected file paths operator-visible. TUI `/checkpoint diff` and `/checkpoint restore` now call those control-plane methods and format operator notifications. Web `/ops` now shows copy-ready TUI and control-plane diff/restore commands plus direct diff preview and restore-all controls per recent checkpoint through the same core rollback path. Telegram and Discord `/checkpoint` now expose redacted status with checkpoint lifecycle event counts, redacted event history through `/checkpoint events`, pushed active-run checkpoint notices, redacted diff counts, and restore actions gated by explicit confirmation while keeping raw file paths, file contents, and session ids out of chat output. Focused control-plane checkpoint proof passed with `43 tests, 0 failures`, focused coding-agent terminal/checkpoint proof passed with `93 tests, 0 failures`, direct core checkpoint proof passed with `3 tests, 0 failures`, focused TUI checkpoint command proof passed with `163 tests, 0 failures` plus a successful TUI build, focused channel checkpoint event/action proof passed with `11 tests, 0 failures`, focused Web checkpoint action proof passed with `25 tests, 0 failures`, Telegram `/checkpoint` live restore proof passed in topic `35`, and Discord `/checkpoint` live API registration/check proof passed. | Discord client-click restore proof is still missing. | Model the remaining checkpoint surface as live Discord client-interaction proof before claiming stable slash-command parity. |
| G19 | BEAM-native API/editor parity | Control Plane / MCP / Web | P1 | Partial / BEAM preview | Lemon now has a preview OpenAI-compatible HTTP adapter on the control plane: `GET /v1/health`, `GET /v1/capabilities`, `GET /v1/models`, `GET /v1/models/:model_id`, `POST /v1/chat/completions`, `POST /v1/responses`, `GET /v1/responses/:response_id`, `GET /v1/runs/:run_id`, and `POST /v1/runs/:run_id/cancel`. The adapter maps OpenAI-style chat messages and Responses input, including text, redacted URL/file-id image metadata, and data URL image pass-through, into router-submitted Lemon runs, preserves named sessions through `session_key` metadata, returns queued OpenAI-shaped metadata by default, supports `wait: true` / `timeout_ms` through the existing `agent.wait` path, maps completed answers into Chat Completions or Responses output text, supports `stream: true` SSE over Lemon run bus `:delta`, `:engine_action`, and `:run_completed` events, emits redacted Chat Completions `lemon.tool_progress` and Responses `response.tool_progress` events without raw tool args/results, exposes `resp_<run_id>` stored response retrieval from the run store, supports `previous_response_id` continuation by defaulting follow-up runs to the prior response session key, hashes/redacts HTTP(S) image URLs and file ids into run metadata and bounded prompt placeholders by default, fetches HTTPS URL images only when `LEMON_OPENAI_COMPAT_IMAGE_URL_FETCH=true` and the host is allowlisted, MIME/size-checks fetched URL bytes before runtime-only pass-through, validates and size/count-limits base64 data URL images, redacts them from prompt/metadata, and threads them as runtime-only image blocks through `RunRequest`, the router, gateway, `LemonRunner`, and `CodingAgent.Session.prompt/3`, exposes redacted run status, dispatches cancellation through `LemonRouter.abort_run/2` for non-terminal runs, and supports opt-in token auth through application config or `LEMON_OPENAI_COMPAT_API_TOKEN` / `LEMON_OPENAI_COMPAT_TOKEN` with bearer or `x-api-key`. Lemon also now has a preview ACP JSON-RPC bridge at `POST /acp`: `initialize`, `session/new`, `session/resume`, `session/list`, `session/prompt`, `session/cancel`, and `session/close` map ACP-shaped clients onto store-backed ACP session state and router-submitted Lemon runs. The ACP bridge advertises text and resource-link prompt support only, leaves image/audio/embedded-resource and MCP HTTP/SSE capabilities disabled, supports queued prompt submission through `_meta.lemon.wait: false`, waits through `agent.wait` by default, routes cancellation through `LemonRouter.abort_run/2`, and supports opt-in token auth through `:acp_api_token` or `LEMON_ACP_API_TOKEN`. `scripts/lemon_acp_stdio.exs` packages the same ACP handler for spawned editor-style stdio clients using ACP's newline-delimited JSON stream shape, including `session/update` notifications for Lemon text deltas and redacted tool-progress updates while a prompt wait is active, and round-trips permission plus read/write/delete/rename filesystem client requests for the ACP file bridge. `scripts/live_acp_stdio_smoke.exs` proves the deterministic stdio boundary, `scripts/live_acp_stdio_external_client.mjs` spawns the bridge from a separate Node client, negotiates client filesystem capabilities, answers permission/read/write/delete/rename requests, proves the approval-bus bridge, and passed with `completed_count: 9`, `failed_count: 0`, `update_count: 2`, and `client_request_count: 6`; `scripts/live_acp_official_sdk_client.mjs` uses official `@zed-industries/agent-client-protocol@0.4.5` `ClientSideConnection` against the same stdio bridge, discovered the official `session/load` method and approval option-kind contract, and passed with `completed_count: 8`, `failed_count: 0`, `update_count: 2`, and `client_request_count: 4`. Focused HTTP tests cover model list/retrieve, supportsVision metadata, and capability shape, chat/responses submission, synchronous wait completion, Responses output text mapping, wait timeout handling, Chat Completions SSE, Responses SSE, redacted tool-progress SSE events, stored response retrieval, previous-response continuation metadata, redacted image-input metadata normalization for Chat Completions and Responses without leaking raw URL/data bytes, data URL image pass-through into runtime-only Lemon image blocks, opt-in allowlisted HTTPS image URL fetch into runtime-only Lemon image blocks, disallowed remote image host rejection, known non-vision model rejection before runtime-image submission, redacted run status, unknown-run errors, stored-response not-found errors, run cancellation dispatch, optional bearer auth, optional `x-api-key` auth, metadata-derived session keys, streaming-request metadata, prompt normalization, and validation errors without starting a real model run. ACP tests cover capability negotiation, session creation, router-backed prompt submission with text/resource links, queued prompts, unsupported media rejection, session list/resume/cancel/close, HTTP auth, NDJSON stdio parsing, store-backed session recovery after ETS cache loss, `session/update` projection from run bus events, redacted client-request summaries for permission/read/write/delete/rename, approval-bus resolution, and focused coding-agent ACP file bridge add/update/delete/move routing. `scripts/live_openai_compat_smoke.exs` starts a local Bandit router, calls `/v1` through `:httpc`, runs an external Node `fetch` client plus official OpenAI Node SDK and Python SDK clients against the same boundary, includes single-model retrieval and supportsVision consistency in all three external clients, writes redacted proof JSON, includes top-level `non_vision_image_rejection` coverage for sanitized rejection without submitting a run, and passed with `completed_count: 14`, `failed_count: 0`, nested external-fetch `completed_count: 7` covering raw Chat Completions and Responses SSE, nested OpenAI Node SDK `completed_count: 6`, and nested OpenAI Python SDK `completed_count: 6`, with both official SDK clients covering Chat Completions and Responses streaming. `proofs.status` and `mix lemon.doctor --verbose` now expose these redacted result rows as `openai_compat_*` checks and `openai_compat.api_preview`, which passes only when all fourteen local smoke rows are complete. The combined ACP/OpenAI-compatible control-plane adapter lane passed with `32 tests, 0 failures`. `scripts/live_openai_compat_vision_smoke.exs` also passed through OpenRouter `openai/gpt-4o-mini` on 2026-05-16 with `completed_count: 1`, `failed_count: 0`, and redacted proof JSON; direct OpenAI was blocked by quota and Z.ai's coding endpoint rejected image input in this environment. | Deployed editor UI compatibility and provider-specific image transport hardening remain open after the official ACP SDK client proof. | Keep protocol adapters over the existing control plane/run graph instead of bypassing supervision; add deployed editor UI compatibility proof and keep the vision proof green. |
| G20 | BEAM-native terminal backend parity | Harness / Agent Core / Services | P1 | Partial / BEAM preview | Lemon now has a shared `LemonCore.TerminalBackend` behavior, `LemonCore.TerminalBackends` registry, `LemonCore.TerminalBackendPolicy`, `:local` backend metadata for the existing supervised `ProcessSession` Erlang Port runner, `:local_pty` execution via util-linux `script(1)` when available, optional `:docker` execution through Docker CLI with cwd mounted at `/workspace`, `--pull never`, dropped capabilities, no-new-privileges, read-only root filesystem by default, bounded `/tmp` tmpfs scratch space, plus default CPU, memory, pids, and no-network policy, and optional `:ssh` execution through OpenSSH `BatchMode=yes` when `LEMON_SSH_TERMINAL_TARGET` is configured. SSH execution also supports `LEMON_SSH_TERMINAL_IDENTITY_FILE` and `LEMON_SSH_TERMINAL_USER_KNOWN_HOSTS_FILE` for managed key/known-hosts boundaries without exposing raw paths in status/proof metadata. `exec` accepts backend parameters with the current `local` / `local_pty` / `docker` / `ssh` enum, validates env payloads at the tool boundary, and `ProcessManager` validates backend ids, availability, backend allow/deny policy, optional Docker image allowlists, and optional SSH target allowlists before launch. `exec` can require backend-specific approvals through `LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL` using a redacted action with backend, command hash, cwd hash, and env keys only, process records store backend/capability metadata plus bounded-log counts, max-log settings, started/completed timestamps, and manual restart lineage, `process` list/poll responses expose backend visibility and log/restart metadata, `process restart` replays a finished process as a fresh supervised child with a new process id while preserving the original record, `terminal.backends.status` exposes read-only backend and policy metadata through the control plane, support bundles include redacted `terminal_diagnostics.json`, and Web `/ops` shows terminal backend metadata and policy state without commands, env values, process output, or raw SSH target. Focused tests cover backend metadata, atom-safe id normalization, explicit local and local-PTY backend execution, optional Docker execution when the daemon and configured image are already usable, Docker image policy, SSH target policy/redaction, backend-specific approval gating/redaction, env payload rejection, invalid/backend-policy rejection, stored process capabilities, process tool details, process restart/log metadata, support-bundle redaction, Web snapshot visibility, and the control-plane status method. `scripts/live_terminal_backend_smoke.exs` adds a redacted live smoke and now starts a temporary high-port loopback `sshd` when no SSH target is configured, using generated host/client keys plus temporary known-hosts storage. The smoke passed on 2026-05-17 at `2026-05-17T06:26:25.028059Z` with `local`, `local_pty`, `docker`, and loopback `ssh` completed, `skipped=0`, `failed=0`, and proof metadata containing only hashes, boolean setup flags, and safe Docker hardening booleans/policy values. The Docker proof now validates read-only rootfs, no-exec `/tmp`, dropped effective capabilities, no-new-privileges, pull policy `never`, network `none`, memory `1g`, CPUs `2`, pids limit `256`, and cgroup-observed memory/CPU/pids limits from inside the launched container. Support bundles and `proofs.status` infer `terminal_backend` scope from the result rows, expose `terminal_backend_*` checks, and whitelist only safe Docker hardening fields. `mix lemon.doctor --verbose` now reports this as `terminal.backends_live`, passing only when the redacted proof has completed rows for local, local PTY, Docker, and SSH preview backends and warning on failed or missing rows. | This is preview terminal parity, not full Hermes-style multi-environment terminal parity. Lemon still lacks container fleet backends, fleet restart/resume policies, broader sandbox backends, and advanced hardening profiles. | Keep all execution inside `ProcessManager`/`TerminalBackends`, keep Docker/SSH proof lanes green, then add fleet/container backends, restart policy, and advanced sandbox profiles. |
| G21 | BEAM-native plugin ecosystem parity | Skills / MCP / Extensions | P1 | Partial / operator diagnostics plus BEAM host, stdio MCP tools/resources/prompts/filtering/sampling callback, reviewed-policy, and ops-approval wrappers, Streamable HTTP tools/resources/prompts/OAuth client-credentials, refresh-token, bearer-reacquisition, and PKCE auth-code proof plus OAuth token cache resume, configured-source loopback callback capture plus operator approval routing, legacy SSE MCP tools/resources/prompts, WASM telemetry/policy/lifecycle, and registry audit proof | Lemon has skills, stdio MCP tools/resources/prompts/filtering proof plus opt-in sampling callback, reviewed model-backed policy, and ops approval wrappers, Streamable HTTP tools/resources/prompts plus OAuth metadata, client-credentials token acquisition, refresh-token grant, bearer-reacquisition, and authorization-code PKCE proof, OAuth token cache resume, configured-source loopback callback capture plus operator approval routing, legacy SSE MCP tools/resources/prompts proof, MCP docs, WASM/extension status tools, audits, conflict reporting, and a read-only `extensions.status` control-plane method. `extensions.status` loads trusted configured or explicit extension paths for a cwd and returns redacted loaded-extension names, versions, capabilities, config-schema presence, load/validation error counts, tool-conflict resolution, extension-provided provider names, extension-host execution telemetry proof shape, WASM wrapper telemetry proof shape, WASM policy proof shape, WASM lifecycle proof shape, extension registry audit proof shape, WASM status shape, and execution-policy shape without raw source paths, load-error messages, config schemas, provider modules, path-like WASM metadata, raw registry paths, package names, distribution URLs, or manifest contents. Default global/project extension directories remain diagnostics-only unless `[runtime.extensions] auto_load_default_paths = true`; explicit `[runtime] extension_paths = [...]` or control-plane `extensionPaths` is the trust boundary for executing extension code. Doctor checks, support bundles, and Web `/ops` now expose `extension_diagnostics.json`-equivalent global/project/configured extension directory existence, extension-file counts, manifest valid/invalid counts, aggregate manifest capability/provider/host/distribution/audit shape, nested library-file counts, default-directory execution policy shape, redacted host-runtime/degraded-startup shape for BEAM/WASM/MCP/external extension hosts, redacted extension-host telemetry proof status/hash/counts/redaction shape, redacted WASM telemetry, policy, and lifecycle proof status, redacted registry install/update audit proof status, and path/file hashes without loading extension code or including raw source paths, file contents, manifest contents, distribution URLs, plugin names, provider names, or load-error messages. `mix lemon.doctor` reports these as `extensions.telemetry`, `extensions.wasm_telemetry`, `extensions.wasm_policy`, `extensions.registry_audit`, and `extensions.wasm_lifecycle`. `LemonCore.Extensions.Manifest`, `LemonCore.Extensions.RegistryAudit`, and `mix lemon.extension.validate` provide code-free pre-install/package/registry validation lanes for required fields, provider types, host types, distribution source kinds, audit statuses, installable/blocked package counts, and update-candidate detection. `LemonCore.MemoryProvider` / `LemonCore.MemoryProviders` now define the BEAM memory-provider execution boundary that extension hosts can target: extension-declared memory providers register into `LemonCore.MemoryProviders`, receive memory-document ingest fan-out, and participate in scoped `search_memory` fan-out while Lemon keeps local SQLite as the built-in provider and isolates provider failures. `scripts/live_extension_host_smoke.exs` now proves the local BEAM extension-host execution boundary: default extension directories do not execute without trust, an explicit `extension_paths` entry loads and executes an extension tool through `CodingAgent.ToolRegistry`, streamed tool updates work, extension tool start/stop/exception telemetry is emitted with hashed extension and tool-call identities, disabled mode blocks explicit-path BEAM extension execution through both config and env policy, and built-in tools win namespace conflicts. `scripts/live_wasm_telemetry_smoke.exs` proves the WASM tool wrapper telemetry boundary with four completed checks for success, returned sidecar errors, sidecar exits, and redaction, writing `.lemon/proofs/wasm-tool-telemetry-latest.json` without raw params, paths, call ids, sidecar error text, or tool result payloads. `scripts/live_wasm_policy_smoke.exs` proves risky-capability approval defaults for WASM tools with five completed checks for `http`, `tool_invoke`, `exec`, safe-capability execution, and explicit `never` override, writing `.lemon/proofs/wasm-policy-latest.json`. `scripts/live_extension_registry_audit_smoke.exs` proves a code-free extension registry install/update audit with five completed checks for registry index validation, unaudited install blocking, audited update detection, no extension-code loading, and redaction, writing `.lemon/proofs/extension-registry-audit-latest.json`. `scripts/live_wasm_lifecycle_smoke.exs` proves per-session WASM sidecar lifecycle with five completed checks for redacted discover/invoke telemetry, running status, stop termination, and redaction, writing `.lemon/proofs/wasm-lifecycle-latest.json`. `scripts/live_mcp_stdio_smoke.exs` proves stdio MCP capability hosting with seventeen completed checks for degraded missing-command startup, clean client initialization over stdio, tool listing, resource list/read, prompt list/get, success and tool-error calls, prefixed `LemonSkills.McpSource` discovery, resource/prompt utility invocation, exact allow/block filtering, `CodingAgent.ToolRegistry` exposure, `notifications/initialized` compatibility, the opt-in `sampling/createMessage` callback wrapper, the reviewed model-backed sampling policy wrapper, and the configured-source ops approval bridge with redacted request summaries and approval gating, writing `.lemon/proofs/mcp-stdio-latest.json`. `scripts/live_mcp_http_smoke.exs` proves Streamable HTTP MCP capability hosting with twenty-four completed checks for initialize, JSON and per-request SSE responses, session/protocol headers, OAuth protected-resource and authorization-server metadata discovery, OAuth client-credentials token acquisition with form-post or HTTP Basic token endpoint auth, protected-request retry, refresh-token grant retry and one-shot bearer reacquisition after a later 401, authorization-code PKCE callback/token exchange, OAuth token cache resume without another metadata or token request, configured-source loopback callback capture plus operator approval routing, tool listing, resource list/read, prompt list/get, success and tool-error calls, prefixed source discovery, source resource/prompt utility invocation, registry exposure, status capability shape, and exact HTTP filtering, writing `.lemon/proofs/mcp-http-latest.json`. `scripts/live_mcp_sse_smoke.exs` proves legacy HTTP+SSE MCP capability hosting with fourteen completed checks for endpoint discovery, tool listing, resource list/read, prompt list/get, success and tool-error calls, prefixed source discovery, source resource/prompt utility invocation, registry exposure, status capability shape, and exact SSE filtering, writing `.lemon/proofs/mcp-sse-latest.json`. Focused control-plane/schema proof passed with `94 tests, 0 failures`, including a real temp extension that shadows `read`, exposes an extension provider, has a broken sibling extension whose raw path/message stay redacted, and proves default directories stay diagnostics-only until explicitly trusted. Focused coding-agent extension/tool-registry proof passed with `164 tests, 0 failures`, covering explicit default-directory trust, cache behavior, conflicts, and extension-provider registration. Focused core config proof passed with `24 tests, 0 failures`, proving `auto_load_default_paths` config/env behavior. Focused support-bundle proof passed with `2 tests, 0 failures`, covering extension directory/manifest diagnostics, host-runtime/degraded-startup summary, execution-policy visibility, and redaction. Focused manifest/registry-validator proof passed with `4 tests, 0 failures` for manifest maps and registry audits plus the existing `mix lemon.extension.validate` lane. Focused memory-provider proof passed with `49 core tests, 93 control-plane tests, and 25 Web tests, all with 0 failures`, covering search/ingest fan-out, failure isolation, supervision, SQLite safety, `memory.status`, Web `/ops` visibility, and support-bundle redaction. Focused extension-provider proof passed with `85 tests, 0 failures`, covering model providers, extension memory providers, unsupported provider skips, conflicts, string-keyed provider specs, registration, and unregister cleanup. Focused Web `/ops` proof passed with `25 tests, 0 failures`, including extension directory/manifest visibility, host-runtime/degraded-startup visibility, execution-policy visibility, registry audit visibility, and cleanup assertions. The focused extension host-runtime lane passed on 2026-05-16 with `mix test apps/lemon_core/test/lemon_core/doctor/support_bundle_test.exs apps/lemon_control_plane/test/lemon_control_plane/methods/optional_parity_methods_extended_test.exs apps/lemon_web/test/lemon_web_test.exs --seed 1`, covering 2 core support-bundle tests, 52 control-plane tests, and 25 Web tests with 0 failures. The extension-host smoke proof passed on 2026-05-17 with seven completed checks, including redacted extension tool execution telemetry plus config and env disabled-mode explicit-path blocking, and wrote `.lemon/proofs/extension-host-smoke-latest.json`. | Lemon lacks Hermes-style built-in plugin breadth, dynamic plugin hooks, full public marketplace hosting, and full sandbox execution proof. The stdio MCP, Streamable HTTP MCP with OAuth metadata, client-credentials acquisition, Basic token auth, refresh-token grant, authorization-code PKCE callback, token cache resume, configured-source loopback callback capture plus operator approval routing, and bearer reacquisition, legacy SSE MCP, WASM telemetry/policy/lifecycle, and registry audit proofs cover local capability hosting, wrappers, lifecycle, filtering, callback plumbing, reviewed sampling policy, configured-source ops approval, token acquisition, Basic token auth, bearer reacquisition, token cache resume, loopback callback capture, and metadata boundaries, not full MCP or marketplace parity. | Treat plugins as supervised capability hosts with install/update audits, health checks, tool namespace conflict handling, policy wrappers, telemetry, richer degraded-startup behavior, support-bundle diagnostics, and `/ops` visibility. |
| G22 | BEAM-native persistent goals | Automation / Router / Channels | P0 | BEAM live-judge proof | Lemon now has durable per-session goal state in `LemonCore.GoalStore`, control-plane `goal.set`/`goal.status`/`goal.pause`/`goal.resume`/`goal.continue`/`goal.loop.once`/`goal.loop.start`/`goal.loop.status`/`goal.loop.stop`/`goal.clear`, persisted `maxContinuations` budget plumbing, redacted support-bundle diagnostics, lifecycle and loop-status events, supervised one-shot `LemonAutomation.GoalContinuationManager` submission through LemonRouter, preview verdict ticks, bounded autonomous loops, opt-in persisted auto-loop scheduling through `LemonAutomation.GoalLoopManager`, pluggable judge-runner/model metadata, dev/prod router-backed `:goal_judge` default with `LEMON_GOAL_JUDGE_MODEL` override, JSON verdict parsing, default fail-closed, explicit fail-open, budget-exhaustion tests, a production-shaped router proof where `GoalJudge.RouterRunner` submits through `LemonRouter`, starts a real router `RunProcess`, waits through `RunCompletionWaiter`, parses a JSON verdict, and completes the goal, and a production-shaped persisted-auto proof where `GoalLoopManager` starts a stored auto loop through the same real router judge path. Router queue transitions now keep channel/control-plane user `:collect` submissions ahead of queued `goal_continuation` `:followup` submissions, so queued autonomous continuation work does not block fresh user input. `apps/lemon_automation/test/lemon_automation/goal_judge_router_live_test.exs` passed locally against Z.ai `glm-5-turbo` on 2026-05-15. TUI `/goal` includes budgeted `set`, `continue`, `loop once`, `loop start --auto`, `loop status`, and `loop stop`; Telegram/Discord `/goal` support status/set-with-budget/pause/resume/continue/loop/clear commands with auto-loop start controls; Web `/ops` exposes goal budget plus loop-status visibility. | Richer channel-visible loop behavior still needs more live coverage. | Keep the provider-backed judge proof green while adding richer channel-visible loop behavior. |
| G23 | BEAM-native kanban boards | Automation / Agent Core / Web | P0/P1 | BEAM live-worker proof plus Discord registration proof | `LemonCore.KanbanStore` now persists boards, columns, tasks, dependencies, comments, assignees, worker profiles, session/run links, lifecycle events, expiring leases, and redacted diagnostics. The control plane exposes `kanban.board.create`, `kanban.board.list`, `kanban.board.get`, `kanban.board.archive`, `kanban.task.create`, `kanban.task.update`, `kanban.task.comment`, and `kanban.dispatcher.start/status/stop`. `LemonAutomation.KanbanDispatcher` supervises task leasing, expired-lease reclaim, worker execution, completion, and failure marking. Focused dispatcher coverage now proves bounded multi-worker leasing, completion, explicit worker failure, crashed-worker failure marking, expired-lease reclaim, and a production-shaped bounded-concurrency path through the real `KanbanRunWorker` with router/waiter stubs. `apps/lemon_automation/test/lemon_automation/kanban_dispatcher_live_test.exs` passed locally against Z.ai `glm-5-turbo` on 2026-05-15: it created three durable tasks, proved dispatcher `running_count: 2` through real `KanbanRunWorker`/router/waiter execution, then completed all tasks with run ids and cleared leases. The default `KanbanRunWorker` submits leased tasks through `LemonRouter` with `origin: :kanban`, board/task provenance, per-task git worktree cwd when the board workspace is a git repository, blocked recursive kanban tooling, and optional model override for proof runs. The default coding-agent toolset now includes `kanban` for model-facing board/task CRUD and comments. Web `/ops` now exposes redacted board/task status, counts, lease state, columns, worker metadata, and workspace hashes. TUI `/kanban`, Telegram `/kanban`, and Discord `/kanban` now support board list/create/show/archive, task create/update/comment, and dispatcher start/status/stop over the durable board API; focused store/API/dispatcher/worker/tool/Web/TUI/channel/support-bundle tests pass. `scripts/live_telegram_matrix.py --skip-dm --skip-topic --topic-kanban --kanban-topic-id 35 --timeout 120` passed on 2026-05-15, proving Telegram topic create/task/comment/show/archive controls in topic `35` with private board/task/comment text redacted. `scripts/live_discord_matrix.py --bot-token-index 0 --register-kanban-slash-command --result-path tmp/discord-kanban-slash-proof.json` and follow-up `--check-kanban-slash-registration` passed through Discord's API for the in-repo `/kanban` schema. | Lemon still needs broader Discord client-interaction proof if channel-complete slash-command parity is claimed. | Keep registration proof green and add Discord client-interaction/manual matrix when broad slash parity is promoted. |
| G24 | BEAM-native LSP diagnostics | Agent Core / Tools | P1 | Partial / BEAM preview plus full-fleet real-repo proof | Lemon now has a model-facing `lsp_diagnostics` coding-agent tool plus opt-in `diagnostics` flags on `write`, `edit`, and `patch`. The runner detects file language, performs deterministic Elixir syntax diagnostics, uses local workspace tools when present (`mix compile --return-errors`, `node --check`, `tsc --noEmit`, `py_compile`, `cargo check`, `go test`, compiler `-fsyntax-only`), computes baseline/delta diagnostics after edits, and degrades to skipped results when a checker, compiler, or workspace marker is missing. `LemonCore.LspServers` registers ElixirLS, TypeScript Language Server, Pyright, rust-analyzer, gopls, and clangd without atom leaks. `LemonCore.LspServerManager` runs under the core supervisor, reports redacted registry/session state, available/missing counts, planned capabilities, and restartability, and supports supervised stdio sessions through `lsp.server.start`, initialize/initialized orchestration through `lsp.server.initialize`, document open/change/close notifications through `lsp.document.open` / `lsp.document.change` / `lsp.document.close`, Content-Length JSON-RPC request/response through `lsp.server.request`, redacted `textDocument/publishDiagnostics` notification capture plus `textDocument/diagnostic` pull-response capture, stderr containment, request-timeout session termination, launcher/descendant cleanup, and shutdown through `lsp.server.stop`. `scripts/live_lsp_server_smoke.exs` now accepts `--servers`, `--editor-flow`, `--project-fixtures` / `--fixture-profile project`, and `--real-repo-fixtures` / `--fixture-profile real_repo`. The project-fixture full local fleet proof passed on 2026-05-17 with `completed_count: 6`, `failed_count: 0`. The real-repository full local fleet proof also passed on 2026-05-17 with `pyright,gopls,clangd,rust_analyzer,typescript_language_server,elixir_ls`, `completed_count: 6`, `failed_count: 0`, safe `lsp_real_repo_fixtures_smoke` proof scope, six per-server editor-flow checks, non-zero injected and reintroduced diagnostics, final clean diagnostics, closed documents, and cleanup flags false for raw paths, file contents, diagnostic output, raw session ids, and server I/O. It covers Lemon CLI Python, maintained Go and C repo fixtures, Lemon WASM runtime Rust, Lemon TUI TypeScript, and LemonCore Elixir source hashes only. A broken-default-wrapper cleanup proof returned `:request_timeout` and left no `elixir-ls`, `language_server`, or language-server smoke processes running. `docs/tools/lsp.md` documents local checker installs, language-server installs, override env vars, ElixirLS launcher support, timeout cleanup, control-plane methods, project-fixture proof, real-repo fixture proof, and proof lanes. `lsp.diagnostics.status`, Web `/ops`, support-bundle `lsp_diagnostics.json`, and read-only `proofs.status` expose redacted checker/server/session/proof capability metadata without paths, executable paths, raw session ids, file contents, workspace roots, diagnostic output, or server I/O. Focused tests cover clean syntax, introduced syntax diagnostics, pre-existing diagnostics suppression, JavaScript syntax fixtures, Python clean/error fixtures, TypeScript no-tsconfig skip behavior, TypeScript tsconfig diagnostics, Go workspace diagnostics, Rust workspace diagnostics, C compiler diagnostics, the model-facing tool result, `write`/`edit`/`patch` post-edit hooks, registry status, stdio session lifecycle, JSON-RPC framing and response correlation, initialize handshake, request-timeout session cleanup, document-sync notifications, redacted push and pull diagnostic capture, stderr containment, wrapper child-process cleanup, manager restartability, control-plane schema/status/start/initialize/document/request/stop, support-bundle redaction, and Web snapshot visibility. | This is still a preview diagnostic runner and supervised JSON-RPC/document-sync transport surface, but full registered-server real-repo proof is now covered. Lemon still needs broader editor integration and operational promotion criteria before claiming stable Hermes LSP parity. | Keep focused diagnostics/JSON-RPC tests plus project-fixture and real-repo full-fleet editor-flow smokes green while extending editor integrations. |
| G25 | Provider routing, fallback, and credential pools | AI / Runtime / Ops | P1 | BEAM live-fallback plus support diagnostics proof | `apps/ai` supports multiple providers and live eval covers one OpenAI-compatible provider path. `AgentCore.ModelRuntime.StreamOptions` now carries configured OpenAI-compatible provider API keys and base URLs into provider-specific stream options, which unblocked the Z.ai provider-backed goal judge proof. `AgentCore.ModelRuntime.ProviderStatus` now backs read-only control-plane `providers.status` and Web `/ops` provider readiness, returning redacted provider readiness/config-shape booleans without raw API keys, secret names, base URLs, or env var names. `AgentCore.ModelRuntime.ProviderRouting` now defines `runtime.provider_routing` fallback semantics and returns a redacted route-plan preview through `providers.status` and Web `/ops`, including requested provider/model, selected provider/model, selected routing profile, selected credential pool, candidate readiness, profile distribution weights, pool strategy/provider names, and credential-reference counts. `LemonCore.ProviderPoolRotator` now provides supervised in-memory round-robin ordering for credential pools, and coding-agent default model resolution consumes the same fallback/profile/pool ordering before starting `AgentCore.Agent`, selecting a ready fallback provider with the same model id when the configured default provider has no credentials while leaving explicit model specs fixed. Default-model streams are also wrapped with response-time fallback: provider stream errors before useful assistant content or tool calls retry the same turn against the next credential-ready fallback provider, while post-content failures surface normally to avoid duplicate transcript output. Doctor support bundles now include core-owned `provider_diagnostics.json` with provider setup shape, default-provider/default-model presence, credential-reference counts, ambient-provider booleans, routing fallback shape, credential-pool/profile shape, and per-provider redacted config shape without raw API keys, secret names, raw base URLs, env var names, provider responses, or model prompts. `mix lemon.doctor` now includes a `providers.routing` check that flags configured fallback routes with no credential-ready fallback and passes when a credential-ready fallback can rescue a not-ready default provider, without exposing credential material. `proof_diagnostics.json`, read-only `proofs.status`, and Web `/ops` now also expose the latest provider fallback proof status with redacted proof object, primary/fallback/final provider labels, modified timestamp, proof hash, and next action. Focused core-config/runtime/coding-agent/control-plane/Web/support-bundle tests prove primary selection, startup fallback selection, response-time fallback selection, profile/pool candidate ordering, round-robin pool rotation, explicit-model no-wrap behavior, schema validation, Web visibility, support-bundle provider diagnostics, provider doctor routing checks, provider fallback proof visibility, and redaction. `scripts/live_provider_fallback_smoke.exs` passed on 2026-05-16 with an intentionally invalid OpenAI primary and Z.ai `glm-5-turbo` fallback, producing redacted proof JSON with `completed_count: 1` and `final_provider: "zai"`. | Provider onboarding can still be smoother for non-default hosted endpoints and OAuth variants. | Keep setup docs current, keep support-bundle redaction tests green, and keep the live fallback proof green. |
| G26 | OpenAI/Codex runtime interop | Agent Core / MCP / Plugins | P1 | Open | Lemon can run Codex as an engine and has MCP/control-plane surfaces. | Lemon lacks Hermes-style optional Codex app-server runtime integration and automatic Codex plugin/MCP callback migration. | Decide whether parity means native Lemon equivalents or an interop path; if interop, wrap Codex app-server behind capability policy and event projection instead of bypassing Lemon observability. |
| G27 | Web/dashboard parity | Web / Ops | P1 | Partial | `/ops` and run detail already cover core runtime visibility, browser status with driver session timestamps, safe capability labels, operator guidance, hashed driver process ids, and artifact cleanup metadata, checkpoints, redacted goal status, redacted kanban board/task state, media job metadata, proof-artifact pass/fail summaries, safe reason/scope/check coverage, latest redacted proof-check status backed by `proofs.status`, channel failure drilldown that joins redacted channel diagnostics with proof evidence for Discord DM/free-response/reconnect/slash-client promotion, terminal backends, terminal proof hardening/cgroup booleans from recent proof artifacts, redacted LSP diagnostics checker/server-registry/session status, redacted provider readiness, redacted provider routing/fallback route previews, redacted live provider fallback proof status, and redacted extension/plugin directory plus manifest diagnostics. | New parity surfaces need first-party operator views before they are supportable. | Add panels for richer checkpoint restore controls, richer LSP diagnostic/session detail, live media delivery results, and richer sandbox execution health. |

Latest channel-proof addendum, 2026-05-17:

- `LemonChannels.Adapters.Discord.Transport.slash_command_args_for_interaction/1`
  is now the shared runtime decoder for Discord `/checkpoint`, `/rollback`,
  `/kanban`, and `/media status` application-command payloads.
- `scripts/live_discord_slash_interaction_proof.exs` writes the current
  completed deterministic check set to
  `.lemon/proofs/discord-slash-interaction-proof-latest.json`. It covers the
  local 16-command slash inventory, checkpoint/rollback/kanban/media payload
  decoding, all durable kanban subcommand decoders, and safe local interaction responses
  for session/model/thinking/resume/cancel/media/trigger/cwd/topic/file paths.
  `proofs.status`, support bundles, and Web `/ops` now preserve the proof's
  safe coverage counts without exposing raw proof contents.
- Done in repo-side live proof plumbing: the Discord transport now passively
  writes a redacted `lemon.discord_slash_client_click` proof when a real
  slash-command interaction arrives with live Discord fields and Lemon emits a
  safe interaction response. The proof records command/response metadata,
  safe-mention status, and coverage counts without raw interaction tokens,
  application ids, channel ids, user ids, or message bodies. This gives the
  remaining client-click gate a runtime proof path, but it still needs an
  operator to click a real command in Discord after deploy or hot reload before
  broad slash-command parity can be promoted. The primary handoff command is
  `scripts/live_discord_matrix.py --wait-slash-client-click-proof --channel-id
  "$DISCORD_PROOF_CHANNEL_ID" --proof-path
  .lemon/proofs/discord-slash-client-click-check-latest.json`; it fails until a
  fresh local redacted proof artifact exists and has
  `real_client_click_proof=true`.
- Done in operator diagnostics: `mix lemon.doctor` now includes redacted channel
  readiness checks for Telegram/Discord credential shape plus Discord DM,
  free-response, reconnect, deterministic slash, and real slash client-click
  gates. The current repo state reports Discord config, free-response,
  deterministic slash, and restart/reconnect replay proof as passing while DM
  and slash client-click remain warnings with concrete operator actions. The final
  readiness audit now also prints bounded reason-kind labels from incomplete DM,
  free-response, and real slash client-click proof artifacts without exposing
  Discord IDs, tokens, or message bodies. Free-response diagnostics now also
  expose that Lemon requests Discord's `message_content` gateway intent at
  runtime, keeping that distinct from the operator declaration that the
  privileged Developer Portal setting is enabled.
- Discord outbound delivery now passes `allowed_mentions: :none` through Nostrum
  so outgoing text, edits, file captions, long chunks, component messages, and
  followups disable mention parsing without crashing Nostrum's allowed-mention
  normalization. Interaction responses still use the direct Discord API-safe
  `%{parse: [], replied_user: false}` shape. `scripts/live_discord_safe_mentions_proof.exs`
  passed locally with three completed checks and writes
  `.lemon/proofs/discord-safe-mentions-proof-latest.json`.
- Discord approval buttons now resolve pending `LemonCore.ExecApprovals`
  requests with the atom decisions expected by core approval state instead of
  tuple labels, and `scripts/live_discord_approval_component_proof.exs` writes
  `.lemon/proofs/discord-approval-component-proof-latest.json` with two
  completed checks.
- Discord cancel and watchdog keepalive buttons now have deterministic proof
  through `LemonChannels.Runtime` / `LemonCore.RouterBridge`, and
  `scripts/live_discord_runtime_components_proof.exs` writes
  `.lemon/proofs/discord-runtime-components-proof-latest.json` with three
  completed checks.
- Discord duplicate `MESSAGE_CREATE` handling now has deterministic proof
  through the normal inbound normalization, ETS dedupe, persisted idempotency
  boundary, debounce buffer, reaction path, `LemonChannels.Runtime`, and
  `LemonCore.RouterBridge`.
  `scripts/live_discord_dedupe_proof.exs` writes
  `.lemon/proofs/discord-dedupe-proof-latest.json` with four completed checks:
  first message buffered, duplicate marked seen before debounce flush, one run
  submitted after flush, and duplicate ignored after simulated transport restart
  with an empty in-memory buffer and cleared ETS table. Live external-sender
  Discord gateway reconnect replay is covered by the separate
  `scripts/live_discord_matrix.py --restart-seed` plus
  `--restart-verify --restart-runtime-confirmed` proof artifacts.
- Discord free-response trigger mode now has deterministic proof. By default,
  unmentioned group messages are suppressed; `/trigger all` stores the channel
  mode and lets an unmentioned message submit through the runtime path; and
  `/trigger mentions` restores mention-gated behavior. `scripts/live_discord_trigger_mode_proof.exs`
  writes `.lemon/proofs/discord-trigger-mode-proof-latest.json` with four
  completed checks.
- Live Discord free-response now has an explicit matrix harness:
  `scripts/live_discord_matrix.py --wait-free-response-trigger` creates a
  temporary public thread, seeds both safe thread trigger-mode key shapes, sends
  an unmentioned second-bot message, and clears the trigger override after the
  check. The latest run on 2026-05-17 passed and wrote
  `.lemon/proofs/discord-free-response-latest.json` with
  `discord_free_response_trigger_round_trip` completed,
  `message_content_intent_declared: true`, trigger mode `all`, cleanup mode
  `clear`, and redacted metadata. The live failure immediately before that run
  exposed a thread-shape bug: Discord can deliver thread `MESSAGE_CREATE` events
  with the thread id as `channel_id` and no parent-channel context, so transport
  trigger resolution now falls back from `{thread, nil}` to the stored
  `{thread, thread}` trigger-mode key. The live runner also preflights Discord
  application Message Content Intent flags against the local Lemon declaration
  before waiting for an unmentioned-message proof. Support bundles expose
  redacted Discord free-response readiness in `channel_diagnostics.json`,
  including the Message Content Intent declaration shape and the
  proof-diagnostics handoff without leaking Discord IDs or message bodies.
- Discord bot-message policy is explicit in code and diagnostics: Lemon ignores
  its own bot messages and webhooks, preserves external bot sender metadata, and
  routes external bot-authored messages when the normal trigger policy allows
  them. The latest second-bot free-response proof promotes that narrow
  unmentioned-thread path; broader external-bot support still requires
  feature-specific live proof before promotion.
- This closes the deterministic client-interaction gap for those command
  payloads. It is not a real Discord human-client click proof, so broad
  Discord slash-command parity still requires live client-click evidence.

## Hermes-on-BEAM Parity Classification

Sources:

- `docs/plans/lemon-hermes-feature-parity-matrix-2026-05-12.md`
- `docs/plans/lemon-hermes-agent-harness-parity-scorecard.md`

This table classifies the scorecard's current residual gaps for the
Hermes-on-BEAM product goal. It does not replace the scorecard; it decides which
parity gaps are already green, which must be built before broad parity claims,
and which can follow as ecosystem breadth.

This classification is intentionally stricter than the previous release-focused
plan. Lemon is not ready to claim "Hermes, but better, on the BEAM" until
Hermes parity and channel reliability are proven directly, especially over
Telegram and Discord.

| Scorecard area | Current scorecard status | Residual gap | Product classification | Required action |
| --- | --- | --- | --- | --- |
| Tool ergonomics and enforcement | Partial / strong foundation; high priority | Browser/media/Home Assistant/Feishu/RL tools are not yet comparable; Lemon file/shell/web/memory/skill/delegation tool contracts are covered by deterministic and live evals. | P0 for browser/media parity, P2 for niche integrations. | Keep existing contracts green while adding supervised BEAM-native browser/media/plugin tool workers. |
| Skills lifecycle and procedural memory | Green for Lemon core boundary | Dynamic skill commands, hub breadth, and plugin distribution need a broader ecosystem story. | P1. | Keep skill docs/evals green and design the plugin/skill ecosystem as audited capability hosts. |
| Memory and session recall | Green for Lemon core boundary plus BEAM preview compact/provider semantics | Lemon now has explicit external memory-provider ingest/search semantics through `LemonCore.MemoryProvider` and `LemonCore.MemoryProviders`, with local SQLite default, safety screening, scoped search fan-out, provider failure isolation, extension-provider registration, unregister cleanup, and redacted support-bundle diagnostics, read-only `memory.status`, and Web `/ops` memory-provider visibility. The default coding-agent toolset now also includes a Hermes-style `memory` tool for bounded assistant-home `USER.md` / `MEMORY.md` read/add/replace/remove with duplicate checks, unique-substring replace/remove, compact file limits, secret screening, prompt-injection screening, and invisible-control rejection. | P1 for live proof and concrete non-local provider adapters. | Keep provider semantics behind durable stores, secret screening, telemetry, and support-bundle redaction; promote compact memory after live model/channel proof. |
| Delegation and orchestration | Green for Lemon core boundary | Broader background-session breadth remains parity work. | P1. | Keep deterministic/live-model delegation evals green and expose long-running child work through BEAM run graphs and `/ops`. |
| Cron and durable background jobs | Partial / supportable preview; medium-high priority | Recursive model-facing scheduling is structurally blocked, redacted support-bundle diagnostics are proof-backed through `cron_diagnostics.json` and `scripts/live_cron_diagnostics_smoke.exs`, scheduled ticks suppress duplicate starts when a persisted active run exists, active runs older than the job timeout recover as `:timeout`, `CronManager` restarts reload persisted active runs without duplicate scheduled submit and recover stale active runs during initialization, scheduled run slots use deterministic IDs plus `Store.put_new` claims so competing dispatchers preserve the first claimant, full `:runtime_full` restart proof now observes a scheduled run before restart, persisted job/run history after restart, and a fresh scheduled run after restart, channel-origin forwarded summaries now reach the LemonChannels outbox through the router bridge, scheduled failures/timeouts can retry as separate `:retry` runs with redacted lineage, explicit pause/resume lifecycle controls exist in the control plane and model-facing cron tool, active-run abort is exposed through control-plane, model-facing cron tool, Web, and TUI, durable `cron.audit` history is visible through control-plane, WebSocket, Web, and support diagnostics, Web `/ops` exposes retry policy create/edit controls, and operator-owned no-agent command cron jobs can be created and updated through the control plane without entering model-facing prompt cron. Live deployed external-channel proof is the main remaining cron parity gate. | P1. | Promote cron/background jobs after deployed Telegram/Discord external-channel proof is complete. |
| Cron final audit | Final readiness gate. | `mix lemon.doctor --verbose` now reports `cron.preview`, and the final readiness audit validates cron diagnostics, full-runtime restart, and Telegram/Discord-shaped channel-origin proof artifacts before cron preview support can be promoted. | P1. | Keep all three cron proof artifacts current while deployed external-channel proof remains the stable-promotion blocker. |
| Messaging and native delivery | Partial / strong foundation; medium priority | Telegram and Discord text/file paths are proven; Discord public-thread prompt/reply and free-response unmentioned thread prompts are live-proven; Telegram and Discord generated-SVG plus generated-audio delivery through `sendToChannel` are live-proven; media job metadata and support visibility exist through control-plane, Web, support bundle, and `/media status` channel commands; support bundles now expose redacted Telegram/Discord channel setup diagnostics including Discord DM, free-response, slash-command readiness, and safe proof reason-kind counts, but provider-backed voice, Discord DMs, broad slash commands, and other platforms remain parity work. | P0 for Telegram/Discord breadth, P2 for additional platforms. | Keep both live matrices green and add remaining BEAM-native media/channel proof before claiming broad messaging parity. |
| Browser/web/media tools | Partial. | Text web search/fetch exists; browser automation has supervised preview proof; generated-media jobs now have redacted metadata, artifact summaries, support-bundle diagnostics, Web `/ops` visibility, Telegram/Discord `/media status` visibility, a model-facing `media_status` reader, a model-facing `media_generate_image` path for deterministic local SVG previews plus provider-backed OpenAI or Vertex Imagen image artifacts, a model-facing `media_generate_speech` path for deterministic local WAV previews plus provider-backed OpenAI, ElevenLabs, or Google TTS artifacts, a model-facing `media_transcribe_audio` path for local transcript previews plus provider-backed OpenAI STT artifacts, a model-facing `media_analyze_image` path for local image-analysis previews plus provider-backed OpenAI vision artifacts, a model-facing `media_generate_video` path for deterministic local MP4 previews plus provider-backed OpenAI video or Vertex Veo create/poll/download artifacts on the same supervisor/artifact path, and live Telegram/Discord generated-SVG plus generated-audio delivery proof, but voice mode and live image/TTS/video provider proof are not stable. | P0. | Build supervised browser/media workers with artifact storage, progress events, policies, and deterministic plus live proof. |
| Browser final audit | Final readiness gate. | `mix lemon.doctor --verbose` now reports `browser.preview`, and the final readiness audit validates `.lemon/proofs/browser-smoke-latest.json` before browser preview support can be promoted. The gate requires local-driver execution, CDP attach, route guardrails, page interaction, upload/download, screenshots, cookies/state reset, progress redaction, and browser-to-media vision coverage. | P0/P1. | Keep the browser smoke current while broader remote-provider browser lifecycle and hybrid routing remain preview. |
| Checkpoint and rollback | Partial / preview. | Lemon now owns shared rollback state in `LemonCore.Checkpoint`, snapshots `write`, `edit`, and `patch` file mutations when a session id is present, exposes a `checkpoint` tool for list, diff, restore, and delete, emits checkpoint lifecycle events through introspection plus run/session streams, exposes redacted checkpoint status through control plane, Web `/ops`, Telegram/Discord `/checkpoint`, and support bundles, snapshots configured file paths before risky `exec` shell commands, provides control-plane `checkpoint.diff` / `checkpoint.restore` methods for shared operator rollback flows, exposes TUI `/checkpoint diff` / `/checkpoint restore` controls, shows copy-ready rollback command guidance and direct diff/restore controls in Web `/ops`, and exposes Telegram/Discord `/checkpoint` redacted status with lifecycle event counts, browsable event history, pushed active-run notices, and diff/restore controls with explicit restore confirmation. | P0. | Add Discord client-click restore proof before stable slash-command parity. |
| API/editor integration | Partial / BEAM preview. | Lemon now exposes preview `/v1/health`, `/v1/capabilities`, `/v1/models`, `/v1/models/:model_id`, `/v1/chat/completions`, `/v1/responses`, `/v1/responses/:response_id`, `/v1/runs/:run_id`, and `/v1/runs/:run_id/cancel` over the control-plane HTTP router. Chat Completions and Responses requests submit Lemon runs through the router/run graph, return queued OpenAI-shaped metadata by default, support `wait: true` / `timeout_ms` to synchronously wait through `agent.wait`, map completed answers into OpenAI-shaped output, support `stream: true` SSE from run bus events, emit redacted tool-progress SSE events for Lemon `:engine_action` updates, retrieve stored Responses from the run store, continue from `previous_response_id` on the same Lemon session by default, hash/redact HTTP(S) image URLs and file ids into run metadata plus bounded prompt placeholders by default, opt into allowlisted HTTPS URL fetch for runtime-only image pass-through, pass validated base64 data URL images as runtime-only Lemon image blocks without storing raw bytes in prompt metadata, expose `supportsVision` through the model endpoints, and reject known text-only models before runtime-image submission. Run endpoints expose redacted status and cancellation dispatch, `/v1` can require bearer or `x-api-key` auth when configured, and `scripts/live_openai_compat_smoke.exs` proves the local HTTP boundary with a real `:httpc` client plus an external Node `fetch` client plus official OpenAI Node SDK client, single-model retrieval, allowlisted remote image URL fetch proof, and redacted proof JSON. `POST /acp` now provides a preview ACP JSON-RPC bridge for initialize, store-backed session lifecycle, text/resource-link prompt submission, wait/queued prompt behavior, cancel, close, list, resume, and bearer/`x-api-key` auth over the same router run graph; `scripts/lemon_acp_stdio.exs` exposes the same handler over newline-delimited JSON for spawned stdio clients, emits `session/update` notifications for Lemon text deltas and redacted tool progress while prompt waits are active, and round-trips permission plus read/write/delete/rename filesystem client requests for the ACP file bridge. | P1 unless positioned as launch headline. | Add deployed editor UI compatibility proof and keep the OpenRouter vision proof green. |
| Terminal backends | Partial / BEAM preview. | Lemon now has a shared terminal backend behavior/registry/policy layer, local Erlang Port backend metadata, local PTY backend execution via `script(1)`, optional Docker CLI container execution with cwd mounting, no implicit image pulls, dropped capabilities, no-new-privileges, read-only root filesystem by default, bounded `/tmp` tmpfs scratch space, and default no-network/resource policy, optional OpenSSH `BatchMode=yes` execution when configured, temporary identity-file and known-hosts-file support for managed SSH proofs, backend allow/deny policy, optional Docker image allowlists, optional redacted SSH target allowlists, backend-specific `exec` approval requirements with redacted approval actions, backend-aware `exec`, env payload validation before backend launch, `process` backend/capability/log/restart metadata visibility, manual restart of finished processes as fresh supervised children, read-only `terminal.backends.status` control-plane status, redacted support-bundle diagnostics, Web `/ops` visibility, and a redacted live smoke harness for all registered backends. The latest smoke completed `local`, `local_pty`, `docker`, and `ssh` through a temporary loopback sshd, skipped zero backends, and failed zero backends. The Docker portion now proves read-only rootfs, no-exec `/tmp`, dropped capabilities, no-new-privileges, no-network default, no implicit pulls, and cgroup-observed CPU/memory/pids policy from inside the launched container. Container-fleet/sandbox backends, fleet restart/resume policy, and advanced sandbox profiles are not Hermes-comparable yet. | P1. | Keep the focused backend-contract, support, Web, control-plane, process-restart, and all-backend live smoke lanes green; then add fleet/container backends, restart policy, and advanced sandbox profiles. |
| Persistent goals | BEAM live-judge proof. | Lemon now has durable objective state, `goal.set`/`goal.status`/`goal.pause`/`goal.resume`/`goal.continue`/`goal.loop.once`/`goal.loop.start`/`goal.loop.status`/`goal.loop.stop`/`goal.clear`, persisted `maxContinuations` budget plumbing, support-bundle diagnostics, lifecycle/loop-status events, supervised one-shot continuation through LemonRouter, preview verdict ticks, bounded autonomous loops, opt-in persisted auto scheduling through `GoalLoopManager`, pluggable judge-runner/model metadata, dev/prod router-backed `:goal_judge` default with `LEMON_GOAL_JUDGE_MODEL` override, JSON verdict parsing, default fail-closed plus explicit fail-open and budget-exhaustion tests, queued-continuation preemption for fresh user submissions, a production-shaped router proof through `GoalJudge.RouterRunner`, `LemonRouter`, a real router `RunProcess`, and `RunCompletionWaiter`, production-shaped persisted-auto scheduler proof through the same path, TUI `/goal` budget/loop/judge/auto options, Telegram/Discord `/goal` status/set-with-budget/pause/resume/continue/loop/clear commands, redacted Web `/ops` budget plus loop-status visibility, and provider-backed Z.ai `glm-5-turbo` live judge proof. | P0. | Keep the provider-backed judge proof green while adding richer channel-visible loop behavior. |
| Kanban/fleet coordination | BEAM live-worker proof plus Discord registration proof. | Lemon now has durable board/task state, JSON-RPC board/task/archive/dispatcher methods, supervised leasing and router-backed workers, per-task git worktree isolation, deterministic bounded multi-worker/crash/reclaim dispatcher proof, production-shaped real-`KanbanRunWorker` bounded-concurrency proof, provider-backed live real-worker proof through Z.ai `glm-5-turbo`, model-facing `kanban`, redacted Web `/ops`, TUI `/kanban`, Telegram `/kanban`, Discord `/kanban` controls, and Discord API proof that the live Zeebot application has the in-repo `/kanban`, `/checkpoint`, and `/media` schemas registered. | P0/P1. | Add Discord client-interaction proof before broad slash-command parity claims. |
| LSP semantic diagnostics | Partial / BEAM preview plus full-fleet real-repo proof. | Lemon now has a model-facing `lsp_diagnostics` tool plus opt-in post-edit baseline/delta diagnostics for `write`, `edit`, and `patch`, with deterministic Elixir, JavaScript, Python, TypeScript, Go, Rust, and C/C++ local checker fixtures, graceful local-tool fallback, redacted `lsp.diagnostics.status`, supervised `LemonCore.LspServerManager` registry/session visibility, initialize orchestration, document open/change/close notifications, JSON-RPC response correlation, request-timeout cleanup, redacted diagnostic notification counters, Web `/ops` checker/server/session visibility, support-bundle metadata, `docs/tools/lsp.md` install guidance, `scripts/live_lsp_server_smoke.exs` default Pyright proof, `--servers pyright,gopls,clangd,rust_analyzer,typescript_language_server,elixir_ls --editor-flow` full-fleet proof, `--project-fixtures` multi-file project proof, and `--real-repo-fixtures` full registered-server proof. The latest real-repo smoke completed Pyright, gopls, clangd, rust-analyzer, TypeScript Language Server, and ElixirLS with safe `lsp_real_repo_fixtures_smoke` inventory, six per-server editor-flow checks, final clean diagnostics, closed documents, and no raw path/content/server-output leakage. | P1. | Add broader editor integration and operational promotion lanes before stable parity. |
| LSP final audit | Final readiness gate. | `mix lemon.doctor --verbose` now reports `lsp.preview`, and the final readiness audit validates project-fixture plus real-repo fixture editor-flow proof artifacts before LSP preview claims can be promoted. | P1. | Keep the full-fleet LSP proof artifacts current while broader editor integration remains preview. |
| Provider routing/fallback/pools | BEAM live-fallback plus support diagnostics proof. | Lemon supports providers, carries configured OpenAI-compatible provider API keys/base URLs into runtime stream options, exposes redacted provider readiness plus route previews, supports routing profiles, credential pools, supervised round-robin pool ordering, default-model startup fallback, pre-output response-time fallback, and `provider_diagnostics.json` in support bundles for redacted setup/routing shape. `scripts/live_provider_fallback_smoke.exs` passed with invalid OpenAI primary and Z.ai fallback. | P1. | Keep setup docs current, keep support-bundle redaction tests green, and keep the live provider proof green. |
| Plugin/extension ecosystem | Partial / operator diagnostics plus BEAM host, stdio MCP with callback, reviewed-policy, and ops-approval sampling wrappers, Streamable HTTP MCP tools/resources/prompts/OAuth PKCE/token-cache/loopback and legacy SSE MCP tools/resources/prompts, WASM telemetry/policy/lifecycle, and registry audit proof. | Lemon has skills, MCP docs, extension/WASM status tooling, tool conflict reporting, extension provider discovery, read-only `extensions.status` control-plane diagnostics with redacted loaded-extension, load-error, validation-error, tool-conflict, extension-provider, host-runtime, WASM shape, extension-host telemetry proof shape, WASM telemetry proof shape, and extension registry audit proof shape, plus support-bundle and Web `/ops` `extension_diagnostics.json`-equivalent visibility for redacted extension directory/file/manifest, host-runtime shape, and proof status without loading plugin code. Manifest and registry diagnostics include aggregate capability, provider-type, host-type, distribution-source, audit-status, installable/blocked package, and update-candidate counts without raw names or URLs. Default global/project extension directories are diagnostics-only unless explicitly trusted with `[runtime.extensions] auto_load_default_paths = true`; configured `extension_paths` is the trust boundary for executing extension code when `[runtime.extensions] enabled` / `LEMON_EXTENSIONS_ENABLED` allows execution. Disabled mode blocks BEAM extension code execution even for explicit paths while keeping code-free diagnostics visible. The redacted `scripts/live_extension_host_smoke.exs` proof now verifies explicit BEAM extension tool loading/execution, streaming updates, redacted extension tool start/stop/exception telemetry, config and env disabled-mode explicit-path blocking, and built-in conflict precedence. `scripts/live_wasm_telemetry_smoke.exs` adds the matching WASM wrapper proof for redacted start/stop/exception telemetry around success, sidecar error, and sidecar-exit paths. `scripts/live_wasm_policy_smoke.exs` proves risky-capability approval defaults for `http`, `tool_invoke`, and `exec` WASM tools. `scripts/live_extension_registry_audit_smoke.exs` proves code-free registry validation, unaudited install blocking, audited update detection, no code loading, and redacted proof summaries. `scripts/live_wasm_lifecycle_smoke.exs` proves redacted WASM sidecar discover/invoke telemetry, running status, stop termination, and lifecycle redaction. `scripts/live_mcp_stdio_smoke.exs` proves stdio MCP tool/resource/prompt ingestion, filtering, registry exposure, clean lifecycle behavior, the raw sampling callback wrapper, the reviewed model-backed sampling policy wrapper, and the configured-source ops approval bridge with redacted summaries and approval gating; `scripts/live_mcp_http_smoke.exs` proves Streamable HTTP MCP tool/resource/prompt ingestion, JSON and per-request SSE responses, session/protocol headers, OAuth metadata, client-credentials, refresh-token, and PKCE authorization-code proof, OAuth token cache resume, configured-source loopback callback capture plus operator approval routing, source resource/prompt utilities, registry exposure, capability status, and exact HTTP filtering; `scripts/live_mcp_sse_smoke.exs` proves legacy HTTP+SSE MCP tool/resource/prompt ingestion, source resource/prompt utilities, registry exposure, capability status, and exact SSE filtering. `mix lemon.doctor --verbose` now reports `mcp.preview` from the same redacted proof artifacts and passes only when stdio, Streamable HTTP, and legacy SSE proof artifacts are all complete. Final readiness audit now validates `LEMON_MCP_STDIO_PROOF_JSON`, `LEMON_MCP_HTTP_PROOF_JSON`, and `LEMON_MCP_SSE_PROOF_JSON` evidence before MCP preview claims can be promoted. | P1. | Add full marketplace hosting, sandboxed non-BEAM host execution, and external memory-provider/plugin host execution before stable parity claims. |
| Plugin/extension final audit | Final readiness gate. | The final readiness audit now validates extension host, WASM telemetry, WASM policy, extension registry audit, and WASM lifecycle proof evidence before plugin/extension preview claims can be promoted. | P1. | Keep the proof artifacts current while broader marketplace and sandbox execution remain preview. |
| Safety, approvals, and untrusted content | Done for initial safety slices; broader hardening remains | Telegram approval and tool-failure rendering have direct live proof; Discord approvals have deterministic proof through the component path, browser/web/WASM outputs are untrusted, and media transcript plus image-analysis outputs now mark model-visible `text` as untrusted with trust metadata so the pre-LLM untrusted-content wrapper handles prompt-injection text from audio/image-derived content. | P0. | Expand prompt-injection and approval tests across plugin, MCP, email, channel attachment, richer browser, and live Discord client-click paths. |
| Observability and dogfood loop | Strong initial support scope; richer metrics remain. | `/ops` and `/ops/runs/:run_id` cover many support needs, including redacted media job metadata, redacted proof-artifact pass/fail summaries, safe proof reason/scope/check coverage through `proofs.status`, channel failure drilldown for Discord live-proof promotion gates, extension directory/manifest diagnostics, plugin host-runtime/degraded-startup shape, redacted BEAM extension tool execution telemetry, the latest extension-host telemetry proof hash/status/counts, WASM telemetry/policy/lifecycle proof status, and extension registry install/update audit proof status. Richer sandbox and marketplace execution telemetry still need first-class coverage. | P1. | Add `/ops` panels and event streams for every supervised parity surface. |

Media proof update: G17 and the browser/web/media row now have a separate
deterministic local smoke lane. The 2026-05-17 run completed the five local
providers (`local_svg`, `local_wav`, `local_transcript`, `local_vision`, and
`local_mp4`) with `proof_scope: media_local`. This improves the day-to-day
regression lane for BEAM-supervised media workers. Provider-backed vision now
has a current canonical proof at `.lemon/proofs/media-vision-smoke-latest.json`,
and provider-backed STT now has a current Deepgram proof at
`.lemon/proofs/media-transcription-smoke-latest.json`. Provider-backed media
remains blocked until image, TTS, and video `media_provider` smoke artifacts
also complete under usable credentials and quota. The final readiness audit now
prints safe provider-media `reason_kind`
labels when those artifacts are skipped or failed, so the blocker points at the
credential/quota/API class without exposing raw provider responses or media
payloads. The current Vertex Imagen image proof records
`vertex_imagen_http_error:permission_denied`, an earlier OpenAI image proof
recorded `openai_image_http_error:billing_limit_user_error`, the current Google
TTS proof records `google_tts_http_error:permission_denied`, and an earlier
ElevenLabs TTS proof used the ElevenLabs default voice id and recorded
`elevenlabs_tts_http_error:payment_required`, which keeps both lanes blocked by
provider account/quota/permission state rather than Lemon routing bugs.
Provider-prefixed OpenAI-compatible routing is currently limited to
the vision proof path; image, TTS, STT, and video proof scripts now emit the
safe `provider_prefixed_model_not_supported_for_media_type` reason when called
with `provider:model`, and compatible endpoint proof should use `--base-url`
with an unprefixed model.

Current parity decision:

- The core agent harness has a strong foundation, but "Hermes, but better, on
  the BEAM" is blocked on source-grounded product parity and P0 gap closure.
- Direct Telegram and Discord reliability proof is part of the product goal, not
  a later support nicety. Telegram group chats, forum topics, Discord channels,
  DMs, threads, approvals, cancellation, files, media, duplicate suppression,
  and restart/reconnect replay behavior are explicitly in scope.
- Lemon can only claim stable parity for live-proven surfaces. Browser
  automation, media generation, rich media channel delivery, Discord DMs/threads,
  Hermes-style slash-command breadth, API/editor integration, rollback,
  terminal-backend breadth, and plugins must be implemented, tested, and proven
  before broad parity claims.
- Public docs, website copy, and release notes are downstream once parity and
  reliability evidence is green.
- Werewolf and Vending Bench 2.0 are now explicit product missions. Do not claim
  either as launch-complete until the simulation mission plan's watch/replay,
  full-run, UI, test, and benchmark evidence exists.

## Docs-Site Audit Classification

Command run from `docs/`:

```bash
npm install --package-lock-only --ignore-scripts
npm audit --json
```

Current result:

- `vitepress` is the direct dependency with a moderate advisory through `vite`.
- `vite` reports a moderate optimized-deps source-map path traversal advisory.
- `esbuild` reports a moderate development-server request exposure advisory.
- `fixAvailable` is `false` for the reported dependency chain.

Launch classification:

- This does not block Lemon runtime release artifacts because the affected
  packages are docs-site tooling and are not shipped in `lemon_runtime_min` or
  `lemon_runtime_full`.
- This can block a public docs-site launch only if the docs site is served by a
  long-running Vite/VitePress development server. GitHub Pages/static hosting of
  the built output does not expose that dev server path.
- Before enabling a public docs deployment, rerun `npm audit`, check whether a
  fixed VitePress/Vite chain exists, and document any accepted risk in release
  notes if no fix is available.

## Current Launch Status

Milestone 0 is mostly complete:

- launch goal document exists
- docs catalog includes it
- docs hub links it
- README points to it
- docs site navigation exposes it
- initial quality and docs-site build validation passed after cleanup

Milestone 1 is now active:

- build the full gap ledger
- verify each launch claim against code, docs, workflows, or tests
- fix inaccurate launch-critical docs immediately
- classify remaining gaps as P0, P1, or P2 parity work
- turn the P0 rows into implementation slices

## Milestones

### Milestone 0: Launch Goal Accepted

Purpose: agree on the target and make it visible.

Deliverables:

- `docs/plans/lemon-1.0-mainstream-readiness.md`
- docs index and catalog registration
- initial launch checklist

Exit criteria:

- The goal is discoverable from the docs hub.
- The plan has measurable launch criteria.
- The next execution batch is explicit.

### Milestone 1: Truth Audit and Gap Ledger

Purpose: eliminate ambiguity.

Deliverables:

- current-state audit of README, setup docs, release docs, website scaffold,
  workflows, parity scorecard, and UI surfaces
- launch gap ledger
- stale-link cleanup
- product claim inventory

Exit criteria:

- Every launch-critical claim is classified as implemented, partial, planned, or
  incorrect.
- Incorrect claims are fixed or removed.
- Launch blockers are listed with acceptance criteria.

### Milestone 2: Installable Release Candidate

Purpose: make Lemon runnable by users who are not contributors.

Deliverables:

- verified release artifact boot
- release install guide
- source install guide refresh
- setup/doctor hardening
- config and secrets docs refresh
- release checklist
- rollback checklist

Exit criteria:

- Fresh machine install is verified.
- Packaged runtime boots and passes health checks.
- First-run provider setup is documented and tested.

### Milestone 3: Product Smoke and Harness Confidence

Purpose: make CI prove real product behavior.

Deliverables:

- stronger product smoke lane
- release-candidate eval checklist
- live-model eval release process
- expanded parity scorecard closure plan
- prompt-injection variant tests
- credential-backed Telegram live matrix for DM, group chat, forum topics,
  topic isolation, cancellation, approvals, tool rendering, long output,
  document delivery, and restart/dedupe
- credential-backed Discord live matrix for external-sender inbound prompt/reply,
  markdown/code rendering, long-output chunking, tool success/failure markers,
  file delivery, and the stable channel/thread boundary

Exit criteria:

- Release candidate gates catch packaged-runtime, provider, docs, and harness
  regressions.
- Remaining parity gaps are non-blocking or explicitly assigned.

### Milestone 4: Interface Polish

Purpose: make daily use coherent.

Deliverables:

- TUI happy-path polish
- web observability panels
- Telegram command/error polish
- Telegram DM/group/forum-topic polish from live evidence
- Discord channel/thread polish from external-sender inbound evidence
- media/channel rendering docs and tests
- browser tool product decision

Exit criteria:

- A user can run and inspect a real task from each primary surface.
- Failures are visible and actionable.
- Support docs explain each surface.

### Milestone 5: Support and Operations

Purpose: make user support practical.

Deliverables:

- support bundle
- troubleshooting guide
- log and diagnostics docs
- issue templates
- release channel support policy
- upgrade/update/rollback guide

Exit criteria:

- A user can file a useful issue without maintainer back-and-forth for basic
  environment data.
- Maintainers can triage setup, provider, runtime, channel, and release classes
  of failure from bundle data.

### Milestone 6: Public Website and Launch Package

Purpose: make Lemon understandable and credible to the public.

Deliverables:

- public homepage
- install page
- feature pages
- comparison page
- demos or screenshots
- docs site deployment
- launch changelog
- first stable release

Exit criteria:

- Website explains the product clearly.
- Install path works from the site.
- Stable release artifacts are published.
- Docs, README, changelog, and release notes agree.

## Readiness Checklist

### Product

- [x] Clear one-sentence positioning exists.
- [x] README matches current behavior.
- [x] Website homepage exists.
- [x] Website install path exists.
- [x] Source-grounded Hermes feature matrix exists.
- [x] Hermes-class parity status is summarized from current evidence.
- [x] Known gaps are documented honestly.

### Install and Setup

- [x] Source install verified.
- [x] Release install verified locally for `lemon_runtime_full` artifact shape.
- [x] `mix lemon.setup` verified.
- [x] `mix lemon.doctor` verified.
- [x] Provider setup verified for Anthropic.
- [x] Provider setup verified for OpenAI.
- [x] OpenAI-compatible local endpoint setup documented.
- [x] Secrets setup documented.
- [x] Config examples are current.

### Runtime and Release

- [x] `lemon_runtime_min` boots.
- [x] `lemon_runtime_full` boots.
- [x] Health endpoint works for both local release artifact proofs.
- [x] Product smoke covers packaged runtime.
- [ ] Release workflow publishes artifacts.
- [x] Manifest includes checksums.
- [x] Release notes are useful.
- [x] Update behavior is documented accurately.
- [x] Rollback path is documented.

### Agent Harness

- [x] Source-grounded Hermes feature matrix complete against refreshed
  `4ad5fa702` baseline.
- [x] Lemon behavior mapped against every launch-relevant Hermes surface.
- [ ] P0 Hermes feature and reliability gaps closed.
- [x] Lemon channel command surfaces are enumerated against Hermes messaging slash commands.
- [x] Persistent goal loop implemented and proven.
- [x] Durable kanban board implemented and live worker-proven.
- [ ] LSP semantic diagnostics promoted from BEAM preview to stable parity.
- [~] OpenAI-compatible API / ACP adapter implemented and proven. Preview
      `/v1` health/capabilities/models/chat-completions/responses/runs now
      submits Lemon runs, supports synchronous wait, exposes redacted run
      status, dispatches cancellation, supports opt-in token auth, and streams
      SSE answer and redacted tool-progress events over run bus events; it also
      hashes/redacts URL/file-id image references into request metadata and
      bounded prompt placeholders, and passes validated data URL images as
      runtime-only Lemon image blocks, exposes `supportsVision` model metadata,
      and rejects known text-only models before runtime-image submission. The
      deterministic `/v1` smoke now proves single-model retrieval and
      `supportsVision` consistency through external Node `fetch`, official
      OpenAI Node SDK, and official OpenAI Python SDK clients.
      Preview `/acp` JSON-RPC now supports initialize, session lifecycle,
      text/resource-link prompts, wait/queued prompt behavior, cancel, close,
      list, resume, opt-in auth, newline-delimited JSON stdio packaging, and
      stdio `session/update` notifications over the same router run graph. The
      deterministic stdio smoke now proves initialize/session lifecycle,
      queued and waiting prompt behavior, update notifications, parse errors,
      and redacted proof output with `completed_count: 6`.
      Stable parity still needs deployed editor UI proof beyond the official ACP
      SDK client proof and provider-specific image transport hardening beyond
      the passing OpenRouter vision smoke.
- [x] Terminal backend contract promoted from open gap to BEAM preview.
- [ ] Multi-backend terminal layer implemented and proven.
- [ ] Plugin/provider ecosystem implemented and proven.
- [x] Tool lifecycle tests pass.
- [x] Memory tests pass.
- [x] Skill tests pass.
- [x] Delegation tests pass.
- [x] Cron/background tests pass.
- [x] Safety tests pass.
- [x] Live-model evals run for release candidates.
- [x] Live-model evals include at least one realistic multi-step coding-repair
  task. The opt-in `live_model_coding_repair_contract` creates a failing Elixir
  project, requires the provider-backed model to read source, patch code, run
  `elixir test/lemon_release_report_test.exs`, and answer only after the test
  passes.

### Interfaces

- [x] TUI happy path documented and tested for source-runtime deterministic echo path, rendered tool-failure path, and real-run cancellation path.
- [x] Web UI happy path documented and tested for source-runtime deterministic echo path and unified-runtime custom-port boot.
- [x] Telegram single-chat happy path documented and tested for /cwd, prompt round trip, progress rendering, bare /cancel, and approval-button resolution.
- [x] Telegram direct-message live reliability matrix passes for the text-first 1.0 boundary.
- [x] Telegram group-chat live reliability matrix passes through the Lemonade Stand forum-topic group boundary.
- [x] Telegram forum-topic live reliability matrix passes for the text-first plus document-delivery 1.0 boundary, including topic isolation, cancellation, approval, markdown/code, tool success/failure, long-output, document delivery, and restart/dedupe.
- [x] Discord live reliability matrix passes for the supported text-first plus file-delivery boundary with second-bot inbound messages in Lemonade Stand `general`.
- [x] Web UI shows tool failures.
- [x] Web UI shows subagent tree.
- [x] Web UI shows approvals.
- [x] Web UI shows memory/skill activity.
- [x] Cron/background jobs visible.
- [x] Channel markdown behavior documented.
- [x] Media attachment behavior documented for Telegram's text-first 1.0 support boundary.
- [x] Stable Telegram text/document file-delivery claims are proven live for the text-first 1.0 boundary.

### Support

- [x] Support bundle exists.
- [x] Support bundle redacts secrets.
- [x] Troubleshooting guide exists.
- [x] Log locations documented.
- [x] Issue templates request useful diagnostics.
- [x] Security policy is current.
- [x] Release channel support policy exists.

### Documentation

- [x] Docs catalog includes every doc.
- [x] Docs site builds.
- [x] Internal links are clean.
- [x] VitePress navigation points at existing pages.
- [x] Stale roadmap references fixed.
- [x] Changelog is current.
- [x] Prompt-to-artifact completion audit exists.

## Latest Validation

2026-05-12:

- `scripts/test quality` passed: CI/docs lint, test runner contract, skill lint,
  `mix lemon.quality`, and focused quality/eval harness tests.
- `scripts/test clients` passed after the `2026.05.0` client metadata and
  lockfile updates.
- `uv run pytest` passed in `clients/lemon-cli` after the Python CLI metadata
  and `uv.lock` update.
- `scripts/lint_ci_docs.sh` passed with the first-party version metadata guard.
- `scripts/test_contract.sh` passed after adding the explicit `scripts/test
  live-eval` lane.
- `.github/workflows/live-eval.yml` now provides a manual release-candidate
  live eval lane on Elixir 1.19.5 / Erlang/OTP 28.5, backed by repository
  secrets and dispatch inputs for provider/model/base URL/API type.
- `scripts/lint_ci_docs.sh` now fails if the manual live eval workflow is
  missing, is not manual-only, drifts from the supported BEAM toolchain, stops
  calling `scripts/test live-eval`, or falls out of testing/release docs.
- `scripts/lint_ci_docs.sh` now also fails if first-party workflow or simulator
  UI Dockerfile BEAM pins drift from Elixir 1.19.5 / Erlang/OTP 28.5.
- `npm run build` in `docs/` now passes after replacing raw angle-bracket
  placeholders in public release docs with VitePress-safe brace placeholders.
- The docs markdown link check passes after the public release-doc placeholder
  cleanup.
- `scripts/verify_docs_site` now repeats the docs high-severity audit, VitePress
  build, and markdown link check in a temp copy, so the final readiness audit can
  validate the public docs surface without leaving generated files in the repo.
- `scripts/audit_1_0_readiness` now runs the canonical local release-candidate
  lanes before accepting local evidence: `scripts/test fast`,
  `scripts/test quality`, `scripts/test eval-fast`, and `scripts/test clients`.
- `scripts/audit_1_0_readiness` now provides a final release-candidate audit
  wrapper for version metadata, release notes, CI/docs policy, local test lanes,
  docs-site verification, local artifact manifest and runtime boot
  verification, and provider-backed live eval. It now also requires
  `LEMON_DISCORD_LIVE_PROOF_JSON` to point at a passing Discord external-sender manual
  matrix result JSON before claiming Hermes-channel readiness, requires completed
  Discord DM, free-response-with-Message-Content-Intent, and real slash
  client-click proof artifacts before broad Discord promotion, and requires
  completed provider-backed image, TTS, STT, vision, and video proof artifacts
  before claiming provider-backed media parity.
- `scripts/verify_release_artifacts` now enforces the initial 1.0 artifact
  contract directly: CalVer manifest version, safe channel name, exact Linux
  `x86_64` artifact names, and both required profiles
  (`lemon_runtime_min`, `lemon_runtime_full`).
- `scripts/test_contract.sh` now proves the artifact verifier accepts a complete
  min/full manifest and rejects a manifest missing `lemon_runtime_full`.
- `scripts/audit_1_0_readiness 2026.05.0
  /tmp/lemon-release-artifact-proof-2026-05-0/artifacts` confirms version
  metadata, release notes, CI/docs policy, `scripts/test fast`,
  `scripts/test quality`, `scripts/test eval-fast`, `scripts/test clients`,
  docs-site verification, and local artifact manifest/runtime boot
  verification.
- The final `scripts/test fast` rerun passed after tightening three
  timing-sensitive cleanup tests: LocalServer duplicate-name teardown, Outbox
  queue-full fixture shape, and AgentCore EventStream timeout cleanup.
- `env -u LEMON_EVAL_API_KEY -u INTEGRATION_API_KEY -u ANTHROPIC_API_KEY
  scripts/test live-eval` failed fast with exit `66` before app startup and
  printed the accepted credential variables.
- `docs/plans/lemon-1.0-completion-audit-2026-05-12.md` now maps the launch
  objective to concrete artifacts, commands, evidence, and the remaining
  launch blockers.
- `scripts/bump_version.sh 2026.05.0` aligned first-party version metadata
  across the Elixir umbrella, Node clients, package locks, Python CLI metadata,
  Python CLI lockfile package block, and CLI banner.
- `mix run --no-start -e 'IO.puts(Mix.Project.config()[:version])'` returned
  `2026.05.0`.
- `scripts/prepare_release_notes 2026.05.0` passed and produced the
  version-specific release notes from `CHANGELOG.md`.
- `MIX_ENV=prod mix release lemon_runtime_min --overwrite` and
  `MIX_ENV=prod mix release lemon_runtime_full --overwrite` passed for the
  `2026.05.0` candidate.
- `scripts/verify_release_artifacts
  /tmp/lemon-release-artifact-proof-2026-05-0/artifacts` passed for the
  refreshed local release tarballs.
- Extracted `2026.05.0` local proof tarballs for `lemon_runtime_min` and
  `lemon_runtime_full` booted without Mix, returned `{"ok":true}` from
  `/healthz`, and generated release-runtime support bundles.
- Focused deterministic harness tests passed:
  - memory store, ingest, document, safety, routing-fingerprint, and simulation
    memory tools
  - all `apps/lemon_skills/test`
  - AgentCore tool-call and tool-supervision tests
  - CodingAgent eval harness, task, agent, subagent, and extension lifecycle
    tests
  - all `apps/lemon_automation/test/lemon_automation`
- Provider-backed live eval passed against Z.ai `glm-5-turbo` using a local
  Lemon secret reference: `scripts/test live-eval` reported 31 checks passing
  and 0 failing.
- Cron and scheduled automation are now classified as preview for stable 1.0:
  supported only for reproducible operator-controlled scheduling bugs through
  first-party runtime/Web paths, not production-grade scheduling guarantees or
  unrestricted model-facing cron management.
- Browser/media support is now classified in public docs: first-party text web
  search/fetch can be supported in reproducible agent runs, while browser
  automation, generated media, image analysis, and voice/TTS remain preview
  until the supervised BEAM-native workers and live proof land.
- 1.0 install support is scoped to source install plus verified Linux `x86_64`
  tarballs. A one-line remote install script is not part of the initial support
  promise.
- Telegram and Discord are stable remote channels for the live-proven text-first
  plus file/document-delivery boundary. X/Twitter, XMTP, SMS, voice, and other
  channel adapters remain preview until they meet the same live-proof standard.
- Hermes comparison is public as a scorecard/readiness reference. The product
  target is broad Hermes parity on BEAM, but claims must stay bounded to proven
  surfaces until each BEAM-native parity slice lands.
- `mix lemon.update` remains stage-1 only for 1.0: version reporting, config
  migration, and bundled-skill sync, not remote binary update.
- The minimum live-model eval matrix for stable promotion is the full current
  `scripts/test live-eval` lane passing at least once for the release
  candidate.
- `scripts/test live-eval` passed against a real provider on 2026-05-12 using
  a local Lemon secret reference and the Z.ai OpenAI-compatible endpoint:
  31 checks passed, 0 failed. The lane covered deterministic contracts plus
  live-model memory recall, durable memory-topic capture, workspace memory-file
  lookup, skill capture, relevant skill loading, skill-curator consolidation,
  blocked cron fallback, prompt-injection handling, parallel delegation,
  delegation artifacts, and leaf-tool filtering.
- The live-eval lane now also includes `live_model_coding_repair_contract`,
  which exercises read/patch/test/finalize behavior on a failing Elixir fixture.
  This closes the checklist gap for realistic multi-step coding-task coverage in the
  release-candidate eval suite; the next provider-backed run should be treated
  as the live proof for the expanded lane.

## Launch Blockers

These should block a 1.0 stable release:

- Any future regression in these already-closed gates should reopen the launch
  blocker: fresh install first run, packaged release boot, product smoke,
  setup/doctor clarity, README/website truth, approval defaults, support-bundle
  redaction, primary-interface happy paths, support path coverage, Telegram and
  Discord live matrix proof, and release artifact checksum/runtime boot
  verification.

## Interim Support Boundaries

These can stay bounded while the BEAM-native parity work is in progress, but
they should not be treated as permanent exclusions from the product goal:

- Limited OS/package-manager coverage beyond release tarballs.
- Browser automation marked preview until supervised browser workers and proof
  land.
- Cron and scheduled automation marked preview until durable job lifecycle proof
  lands.
- Media generation, image analysis, rich media delivery, and TTS marked preview
  until supervised media workers and channel delivery proof land.
- Advanced extension marketplace deferred until plugin hosts, audits, policies,
  and degraded-startup behavior are proven.
- Hosted service deferred.
- Some channel integrations marked experimental.
- One-line remote install script deferred.

## First Execution Batch

The first implementation batch should be small enough to finish without turning
into a general rewrite.

### Batch 1A: Documentation Truth Cleanup

Tasks:

- Add this plan to docs index and catalog.
- Keep stale `ROADMAP.md` references removed unless a real roadmap is restored.
- Check VitePress navigation for missing docs.
- Audit root README for product claims and stale links.
- Audit release docs against actual `mix lemon.update` and release workflows.

Validation:

- `mix lemon.quality`
- docs site build if dependencies are available

### Batch 1B: Launch Gap Ledger

Tasks:

- Convert this checklist into a gap table with owner, status, and priority.
- Link each launch blocker to a file, workflow, command, or issue.
- Mark each parity scorecard gap as P0, P1, or P2 and define the BEAM-native
  implementation shape for each P0/P1 gap.

Validation:

- plan review
- no code required unless stale docs are fixed

### Batch 1C: Fresh Install Probe

Tasks:

- Run setup from a clean environment or container.
- Record missing system dependencies.
- Verify one provider path.
- Verify first agent run.
- Capture every friction point.

Validation:

- documented install transcript
- setup docs patch
- doctor improvements if needed

### Batch 1D: Product Smoke Upgrade

Tasks:

- Extend product smoke to check the full profile web health endpoint. Done.
- Add a representative control-plane request that is not only `/healthz`. Done:
  product smoke now submits a deterministic `echo` agent run through WebSocket
  and waits for completion through `agent.wait`.
- Make memory search expectations explicit per profile. Done for CI scope:
  product smoke no longer claims or probes unimplemented memory search behavior;
  memory behavior remains covered by focused tests and eval lanes.
- Ensure release logs upload on failure.

Validation:

- product-smoke workflow
- release-smoke workflow

## Ownership Model

Suggested ownership lanes:

| Lane | Owns |
| --- | --- |
| Product | positioning, website, feature matrix, launch checklist |
| Runtime | setup, doctor, release profiles, update, health checks |
| Harness | tool lifecycle, memory, skills, delegation, evals |
| Interfaces | TUI, web, Telegram, channel rendering |
| Support | support bundle, troubleshooting, issue templates |
| Docs | docs catalog, README, docs site, changelog |
| Security | approval defaults, secrets, untrusted content, support redaction |

## Success Metrics

Quantitative:

- fresh install to first run in under 15 minutes for a technical user
- release artifact boots in CI and locally
- product smoke passes on every release candidate
- zero known secret leaks in support bundle paths
- zero high-priority parity gaps
- docs site builds successfully
- setup/doctor failure messages link to docs

Qualitative:

- Users can describe what Lemon is after reading the homepage.
- Users can recover from common setup errors without asking a maintainer.
- Maintainers can triage issues from diagnostics.
- Contributors can add features without violating architecture boundaries.
- Agent behavior feels reliable across multi-step tasks.

## Open Decisions

The current product decision is made: Lemon should target Hermes-level feature
parity, implemented in BEAM-native form, and should only keep support boundaries
as interim claims while those surfaces are built.

Open implementation decisions:

- Browser worker shape: keep the Node client as the browser executor, wrap it in
  an OTP supervision boundary, or replace it with a different BEAM-owned host.
- Rollback storage shape: snapshot files directly, use git/worktree-backed
  checkpoints, or combine both behind a run checkpoint state machine.
- API/editor parity shape: ACP first, OpenAI-compatible API first, or a shared
  protocol adapter layer over the control plane.
- Terminal backend scope: local PTY first, Docker first, SSH first, or a common
  backend behaviour with staged implementations.
- Plugin ecosystem scope: built-in plugin suite first, external plugin host
  first, or MCP/WASM capability host first.
- Persistent goals scope: implement the goal loop as a router/automation
  feature first, then add Telegram/Discord commands, or implement all surfaces
  in one vertical slice.
- Kanban scope: implement durable boards as a new automation app first, or
  extend the existing run graph/task primitives into a board abstraction.
- LSP install scope: auto-install language servers into Lemon-owned paths, or
  only detect servers already on PATH for the first release.

## Implementation Launch Plan

This is the execution plan to launch after the docs refresh. The goal is not to
start with every feature at once; it is to build vertical slices that prove the
BEAM-native pattern and then repeat it.

### Slice 1: Browser Worker

Owner lane: Harness / Runtime / Web

Status: in progress as of 2026-05-15. Lemon now exposes the existing
OTP-supervised local browser driver through first-class default coding-agent
tools:

- `browser_navigate`
- `browser_snapshot`
- `browser_get_content`
- `browser_click`
- `browser_type`
- `browser_hover`
- `browser_select_option`
- `browser_upload_file`
- `browser_download`
- `browser_press`
- `browser_scroll`
- `browser_back`
- `browser_wait_for_selector`
- `browser_evaluate`
- `browser_events`
- `browser_get_cookies`
- `browser_set_cookies`
- `browser_clear_state`
- `browser_screenshot`
- `browser_analyze`

The implementation keeps `clients/lemon-browser-node` as the Playwright/CDP
executor and uses `LemonCore.Browser.LocalServer` as the BEAM-owned supervision
boundary. Screenshot output is written as a local artifact under
`.lemon/browser-artifacts/` by default instead of returning raw base64 to the
model. A caller can pass `includeImage: true` to return a model-visible
`ImageContent` block for visual inspection; result details and support bundles
still omit raw screenshot base64. Tool policy now treats browser tools as
external tools, and treats page-mutating browser interactions plus screenshot
artifact writes as dangerous for safe-mode profiles.

The second browser-worker slice now adds the first supportability layer:
`LemonCore.Browser.LocalServer.status/0` reports BEAM-owned local driver state,
`browser.status` exposes local driver status, recent artifacts, and paired
browser nodes through the control plane, and doctor support bundles include
`browser_diagnostics.json` with lifecycle counters and screenshot artifact
metadata but not screenshot bytes or page contents. The third browser-worker
slice adds `browser_events`, backed by the Node helper's bounded page-event
buffer, so agents can inspect console messages, dialogs, page errors, and
request failures without shelling out to Playwright. The fourth slice renders
local browser worker state in Web `/ops`, including local driver lifecycle
counters, last error, artifact directory, and recent screenshot artifact
metadata. The fifth slice adds a deterministic local-page proof at the
coding-agent tool boundary: a test drives a `data:` page through the
OTP-supervised local browser server with navigate, snapshot, type, click,
content extraction, and event-buffer reads. The sixth slice adds artifact
cleanup metadata to the BEAM status surface: `/ops` and support bundles now
report artifact counts, total bytes, oldest/newest timestamps, and the current
managed cleanup policy without embedding screenshot bytes. The seventh slice
adds `scripts/live_browser_smoke.exs`, a repeatable live local smoke runner
that launches the supervised browser driver against Chrome/Chromium, drives the
same coding-agent browser tool boundary, captures a screenshot artifact,
exercises cookie set/get plus clear-state reset, and writes redacted proof JSON
under `.lemon/proofs/`. The eighth slice makes
screenshot artifact cleanup active: after screenshot writes, Lemon prunes the
browser artifact directory to 14 days or the newest 100 files. The ninth slice
adds explicit model-visible screenshot capture: `browser_screenshot` stays
metadata-only by default, while `includeImage: true` returns the screenshot as
an `ImageContent` block for visual inspection without leaking raw base64 into
details. The tenth slice adds explicit browser session-state tools:
`browser_get_cookies` inspects browser-context cookies with value redaction by
default and explicit value opt-in, `browser_set_cookies` seeds cookies for
authenticated or fixture flows, and `browser_clear_state` clears cookies,
current-page local/session storage, and buffered events by default without
restarting the BEAM runtime. The eleventh slice enriches Web `/ops` browser
operator visibility with safe local-driver session timestamps, pending/buffered
request counters, hashed driver process ids, capability labels, and next-action
guidance without embedding screenshot bytes, page contents, cookie values, or
raw driver logs. The twelfth slice adds `browser_analyze`, which composes a
managed screenshot capture with `media_analyze_image` so a model can inspect the
current page through one BEAM-owned browser vision operation. Later browser
slices add BEAM-side `browser_navigate` route classification and metadata
blocking, attach-only remote CDP endpoint support through
`LEMON_BROWSER_CDP_ENDPOINT` / `--cdp-endpoint`, selector waits through
`browser_wait_for_selector`, page-scoped JavaScript evaluation through
`browser_evaluate`, and menu/form interactions through `browser_hover` and
`browser_select_option`, with selector and selected-value redaction in progress
updates. The next slice adds project-local file-input workflows through
`browser_upload_file`, with BEAM-side path validation, out-of-project rejection,
and selector/upload-path redaction in progress updates. The newest slice adds
supervised download workflows through `browser_download`, with an optional
selector click, Playwright download-event waiting, managed project-local output
when no path is supplied, out-of-project output rejection, and selector/download
path redaction in progress updates. The latest live browser smoke completed 20
browser requests, 40 redacted progress updates,
selector-wait proof, page-evaluate proof, hover proof, select-option proof,
upload-file proof, download proof, attach-only CDP proof,
the manual screenshot-to-media proof, and the one-step `browser_analyze` proof
with 0 failures.

Why first: browser automation is the largest user-visible capability gap and
unlocks later web, media, screenshot, and live-proof work.

Scope:

- wrap `clients/lemon-browser-node` behind an OTP-supervised browser session
  manager: started via `LemonCore.Browser.LocalServer`
- add run-scoped browser artifacts, screenshots, event streaming, and cleanup:
  screenshot artifacts, support-bundle artifact metadata, page-event buffering,
  cleanup metadata, and managed retention cleanup are now covered
- expose navigate, snapshot, click, type, upload-file, download, press, scroll, back, screenshot,
  browser analysis, content, cookie, and clear-state tools behind existing
  tool-policy plumbing
- expose console/dialog/page-error/request-failure tooling through
  `browser_events`
- expose cookie inspection/seeding and clear-state reset controls through
  `browser_get_cookies`, `browser_set_cookies`, and `browser_clear_state`
- show active sessions and artifacts in `/ops`: `browser.status` now supplies
  the backend status contract; Web UI rendering now covers local driver status
  and recent artifact metadata
- add deterministic local-page proof and one live smoke proof: both are now
  covered for the local supervised browser boundary

Exit criteria:

- a model can navigate and inspect a local test page without shelling out:
  covered by deterministic and live local browser tool smoke
- browser session failure does not crash the run or runtime
- support bundles include redacted browser session metadata and `/ops` renders
  local browser driver status plus recent artifact and cleanup metadata
- `browser_screenshot includeImage: true` returns model-visible screenshot
  content while default screenshot calls and support bundles stay metadata-only
- `browser_analyze` captures a managed screenshot, runs local/provider image
  analysis, and returns untrusted analysis text without leaking raw screenshot
  bytes into result details
- browser cookie and clear-state tools are available through the same BEAM
  tool boundary and covered by focused wrapper tests
- docs classify the browser surface as preview or stable based on proof

### Slice 1b: Media Job Observability

Owner lane: Channels / Web / Support

Why here: generated media needs durable BEAM-owned job state before provider
workers or Telegram/Discord delivery can be made supportable.

Scope:

- record generated-media job metadata under `.lemon/media-jobs/`
- keep media artifacts in a managed `.lemon/media-artifacts/` boundary
- record generated final-answer files from router `auto_send_files` metadata
  into the media job store before channel delivery
- run provider-specific media workers under `LemonCore.MediaJobSupervisor`
  instead of unmanaged tasks or channel-local processes
- expose redacted job status/type counts, artifact counts, and cleanup policy
  through `media.status`, Telegram/Discord `/media status`, Web `/ops`, and
  support bundles
- never place prompts, raw artifact paths, generated bytes, provider responses,
  or channel message bodies in support surfaces

Exit criteria:

- [x] `LemonCore.MediaJobs` records redacted job metadata with prompt hashes,
  artifact path hashes, artifact byte counts, type/status state, and a managed
  30-day / 500-job / 250-artifact cleanup policy
- [x] read-only control-plane `media.status` returns the same redacted job and
  artifact metadata for TUI/client/channel consumers
- [x] `media_diagnostics.json` is included in doctor support bundles without
  prompts, raw artifact paths, provider responses, generated bytes, or channel
  message bodies
- [x] Web `/ops` shows media job counts, artifact counts, cleanup policy, and
  recent redacted job metadata
- [x] Telegram `/media` and Discord `/media status` expose the same redacted
  generated-media job counts, artifact counts, cleanup policy, and recent job
  summaries for channel operators
- [x] `LemonRouter.MediaJobRecorder` records generated final-answer
  `auto_send_files` into `LemonCore.MediaJobs` without leaking captions, raw
  paths, or session keys
- [x] `LemonCore.MediaJobSupervisor` and `LemonCore.MediaJobWorker` provide an
  OTP dynamic-supervisor boundary for queued/running/completed/failed media
  workers with redacted metadata updates and PubSub lifecycle events
- [x] focused tests cover job recording redaction, summary/count behavior,
  cleanup behavior, control-plane status, router finalization, support-bundle
  inclusion, Web snapshot visibility, and Telegram/Discord media status command
  formatting/schema
- [x] focused tests cover supervised media worker completion/failure paths,
  artifact recording, event delivery, and provider-error redaction
- [x] `media_status` exposes a model-facing read-only view of redacted media job
  summaries, recent jobs, cleanup policy, and worker supervisor state
- [x] `media_generate_image` exposes model-facing `local_svg`,
  `openai_image`, and `vertex_imagen` image generation through the media
  supervisor, writes managed artifacts, returns redacted prompt hash/chars,
  resolves OpenAI or Vertex credentials through Lemon runtime config/secrets
  when not injected, retries bounded transient provider failures, redacts
  provider errors, and can include
  generated `auto_send_files` metadata when
  `sendToChannel: true` is explicit
- [x] focused coding-agent tests cover `media_generate_image`, redaction,
  artifact writes, generated attachment metadata, runner source preservation,
  channel generated-file gating, registry membership, and policy profile
  behavior
- [x] `media_generate_speech` exposes model-facing `local_wav`, `openai_tts`,
  `elevenlabs_tts`, and `google_tts` speech generation through the media
  supervisor, writes managed audio artifacts, returns redacted text hash/chars,
  resolves provider credentials through Lemon runtime config/secrets when not
  injected, retries bounded transient provider failures, redacts provider
  errors, and can include
  generated `auto_send_files` metadata when
  `sendToChannel: true` is explicit
- [x] focused coding-agent tests cover `media_generate_speech`, redaction,
  artifact writes, generated attachment metadata, provider-error redaction,
  transient-provider retry behavior, registry membership, and policy profile
  behavior
- [x] `media_transcribe_audio` exposes model-facing `local_transcript` and
  `openai_transcribe` STT through the media supervisor, accepts only
  project-local audio paths, writes managed transcript artifacts, records
  redacted input hash/chars instead of raw paths/audio bytes, retries bounded
  transient provider failures, redacts provider errors, and can include
  generated `auto_send_files` metadata when
  `sendToChannel: true` is explicit
- [x] focused coding-agent tests cover `media_transcribe_audio`, path escape
  rejection, redaction, artifact writes, generated attachment metadata,
  provider-error redaction, transient-provider retry behavior, untrusted
  model-visible transcript output, registry membership, and policy profile
  behavior
- [x] `media_analyze_image` exposes model-facing `local_vision` and
  `openai_vision` analysis through the media supervisor, accepts only
  project-local image paths, writes managed JSON/text analysis artifacts,
  records redacted input hash/chars instead of raw paths/prompts/image bytes,
  retries bounded transient provider failures, redacts provider errors, supports
  provider-prefixed OpenAI-compatible models such as
  `openrouter:openai/gpt-4o-mini` by resolving the prefixed provider
  credentials/base URL and sending the stripped model id to the compatible
  endpoint, and can include generated `auto_send_files` metadata when
  `sendToChannel: true` is explicit
- [x] focused coding-agent tests cover `media_analyze_image`, path escape
  rejection, local-only SVG provider restrictions, redaction, artifact writes,
  untrusted model-visible analysis output,
  generated attachment metadata, provider-error redaction,
  transient-provider retry behavior, registry membership, and policy profile
  behavior
- [x] `media_generate_video` exposes model-facing `local_mp4`,
  `openai_video`, and `vertex_veo` generation through the media supervisor,
  writes managed MP4 artifacts, records redacted prompt hash/chars instead of
  raw prompt text, creates/polls/downloads provider video jobs, retries bounded
  transient provider failures, redacts provider errors and provider job ids,
  and can include generated `auto_send_files` metadata when
  `sendToChannel: true` is explicit
- [x] focused coding-agent tests cover `media_generate_video`, redaction,
  artifact writes, generated attachment metadata, provider create/poll/download
  handling, provider-error redaction, transient-provider retry behavior,
  registry membership, and policy profile behavior
- [~] provider-backed image, TTS, STT, vision, and video use this metadata
  store; provider-backed STT and vision now have successful live proof, while
  image, TTS, and video still need successful credential/quota-backed
  runs before promotion from preview
- [x] Telegram and Discord generated-SVG and generated-audio delivery are
  live-proven through the supported channel attachment path
- [~] `scripts/live_media_image_smoke.exs`,
  `scripts/live_media_speech_smoke.exs`,
  `scripts/live_media_transcription_smoke.exs`, and
  `scripts/live_media_vision_smoke.exs`, and
  `scripts/live_media_video_smoke.exs` provide opt-in provider-backed
  image/TTS/STT/vision/video proof and write redacted proof JSON; they can now
  take `--api-key-env`, `--api-key-secret`, and `--base-url` overrides for
  one-off live proof without editing Lemon config. The secret-backed commands
  use `mix run --no-start` so scripts can boot against the persistent encrypted
  Lemon secret store before resolving credentials.
  `scripts/live_media_vision_smoke.exs` passed on 2026-05-17 with
  `--model openrouter:openai/gpt-4o-mini --api-key-secret OPENROUTER_API_KEY`,
  writing `.lemon/proofs/media-vision-smoke-latest.json` with
  `completed_count: 1`, `failed_count: 0`, and `skipped_count: 0`. Direct
  OpenAI image, Vertex Imagen image, TTS, and STT proof attempts reached
  the media worker and wrote redacted failed proofs. The current image proof at
  `.lemon/proofs/media-image-smoke-latest.json` uses `vertex_imagen` and records
  `vertex_imagen_http_error:permission_denied`; an earlier OpenAI image proof
  recorded `openai_image_http_error:billing_limit_user_error`. Image, TTS, and
  video still need successful credential/quota-backed runs before promotion from
  preview.
- [x] the same media smoke scripts now support deterministic `--local` proof
  without credentials or provider quota. The 2026-05-17 local run completed
  `local_svg`, `local_wav`, `local_transcript`, `local_vision`, and
  `local_mp4`, writing separate `media-*-local-smoke-latest.json` artifacts
  with `proof_scope: media_local`. This is a regression lane for local BEAM
  media worker health only; it does not satisfy `media.provider_live` or the
  final provider-backed image/TTS/STT/vision/video audit gate.
- [x] `mix lemon.doctor` and Web `/ops` now expose media proof readiness as two
  separate gates: `media.channel_delivery` passes from Telegram/Discord
  generated-media/audio proof artifacts, while `media.provider_live` warns until
  provider-backed image, TTS, STT, vision, and video all have completed live
  proof. The provider smoke scripts write stable proof objects, per-provider
  check names, and redacted skipped credential-preflight artifacts so missing
  credentials show up as explicit promotion blockers instead of silent gaps.
  The final readiness audit now echoes bounded `reason_kind` labels from those
  incomplete artifacts while preserving the raw-response/media redaction
  contract.

### Slice 2: Checkpoint and Rollback

Owner lane: Harness / Safety / Web

Why second: it reduces the risk of the broader tool surface and gives Lemon a
trust advantage over a normal chat bridge.

Scope:

- create checkpoints before write/edit/patch and configured risky shell commands
- store snapshots under a run-scoped checkpoint store
- expose diff preview, per-file restore, full rollback, and checkpoint cleanup
- emit checkpoint/rollback events into run history, Web, TUI, Telegram, Discord,
  and support bundles

Exit criteria:

- [x] file mutation tools create checkpoints in deterministic tests for
  write/edit/patch when a session id is present
- [x] rollback restores files after a failed or unwanted edit through the
  `checkpoint` tool and `CodingAgent.Checkpoint.restore_filesystem/2`
- [x] checkpoint create/restore/delete events are recorded through
  introspection and broadcast on run/session event streams
- [x] checkpoint metadata is redacted and supportable through
  `checkpoint.status`, Web `/ops`, Telegram/Discord `/checkpoint`, and support
  bundles; channel output stays redacted and Telegram/Discord restore requires
  `/checkpoint restore <id> confirm` or an explicit Discord confirm boolean
- [x] risky shell command checkpoints are covered for configured file paths:
  `exec` accepts `checkpoint_paths`, detects destructive shell commands such as
  `rm`, `mv`, `sed -i`, `find ... -delete`, `git reset`, and `git clean`,
  snapshots those files through the existing filesystem checkpoint store, and
  returns checkpoint metadata for restore
- [x] shared control-plane rollback methods exist:
  `checkpoint.diff` previews filesystem changes and `checkpoint.restore`
  restores all or selected checkpoint paths while hashing session ids in API
  responses
- [x] shared checkpoint ownership lives in `LemonCore.Checkpoint`, with
  `CodingAgent.Checkpoint` kept as the coding-agent resume-state wrapper and
  control-plane diff/restore calling core directly
- [x] TUI `/checkpoint diff` and `/checkpoint restore` route through the
  control-plane rollback methods and render operator notifications
- [x] Web `/ops` exposes copy-ready TUI/control-plane diff and restore commands
  per recent checkpoint without raw file paths, raw session ids, or file content
- [x] Web `/ops` supports direct checkpoint diff preview and restore-all actions
  through `LemonCore.Checkpoint`
- [x] Telegram/Discord `/checkpoint` expose redacted status, redacted diff
  counts, and direct restore controls through `LemonCore.Checkpoint` with
  explicit confirmation
- [x] checkpoint lifecycle event counts and recent checkpoint event summaries
  project into Telegram and Discord `/checkpoint status` without leaking raw
  paths, contents, or session ids
- [x] active-run checkpoint lifecycle events push redacted notices into
  Telegram and Discord when the channel transport is subscribed to the session
  topic
- [x] richer checkpoint/rollback event history is browsable in Telegram and
  Discord through `/checkpoint events [limit]`
- [x] public docs explain the support boundary and commands

### Slice 3: Telegram/Discord Broadening

Owner lane: Channels / Harness / Support

Why third: Telegram and Discord are the only messaging platforms required for
this goal, and broad parity claims must be live-proven.

Scope:

- Telegram rich media delivery once media jobs exist
- Done in preview: live Telegram and Discord generated-media delivery probes
  request `media_generate_image` with `provider local_svg` and generated-audio
  probes request `media_generate_speech` with `provider local_wav`, all with
  `sendToChannel: true`, then validate the normal attachment path. Telegram
  generated media passed in topic `35` on 2026-05-16 and generated audio passed
  on 2026-05-17. Discord generated media passed in channel
  `1475727417372049419` on 2026-05-16 and generated audio passed there on
  2026-05-17.
- Telegram voice/STT/TTS only if the media slice provides stable primitives
- Discord DM proof, live free-response channel proof, safe-mention proof,
  duplicate-suppression proof, restart/reconnect replay proof, cancel proof,
  and approval proof where supported;
  `scripts/live_discord_matrix.py --wait-thread-inbound --per-check-thread`
  now creates a temporary public thread, resets that thread-scoped session, and
  verifies the responder replies in the thread, while Discord inbound
  normalization preserves thread-channel messages as parent channel plus
  `thread_id` when channel metadata is available. The live thread proof passed
  on 2026-05-16 in Lemonade Stand `general`, creating thread
  `1505317536286376089` and writing
  `tmp/discord-thread-inbound-proof.json`.
  `scripts/live_discord_matrix.py --wait-dm-inbound` now targets either a known
  DM channel or a recipient id, uses the DM-shaped Lemon session-reset key, and
  writes a redacted setup-failure proof when Discord refuses the DM channel. The
  proof includes a safe `failure_hint`, redacted `local_channel_diagnostics`,
  and support-bundle classification as `discord_dm_setup_refused` for Discord
  API code `50007`. The available second-bot proof attempt failed at Discord's
  API boundary with code `50007` (`Cannot send messages to this user`) and
  wrote `tmp/discord-dm-proof.json`; Discord DM support therefore remains
  unpromoted until a human/open-DM channel passes the same check.
- `scripts/live_discord_matrix.py` now also accepts `--proof-path` for live
  matrix runs. `--result-path` remains the operator handoff artifact with raw
  Discord nonces/message ids when needed; `--proof-path` writes a sanitized
  `.lemon/proofs` artifact with hashed identifiers, check counts, reason kinds,
  and cleanup assertions for `proofs.status`, support bundles, doctor gates,
  and Web `/ops`. The same redacted writer now covers Discord slash registration
  check/update branches when operators pass `--proof-path`; keep `--result-path`
  for command ids and versions.
- Done in deterministic proof: `LemonChannels.Adapters.Discord.Transport.slash_command_args_for_interaction/1`
  is the shared runtime decoder for `/checkpoint`, `/rollback`, `/kanban`, and
  `/media status`; `scripts/live_discord_slash_interaction_proof.exs` writes
  `.lemon/proofs/discord-slash-interaction-proof-latest.json` with completed
  deterministic checks covering the local 16-command inventory,
  checkpoint/rollback/kanban/media decoding, all durable kanban subcommand
  decoders, and safe local `INTERACTION_CREATE` response handling.
- Done in live registration proof: `scripts/live_discord_matrix.py
  --check-all-slash-registration` reads the live Discord application command
  inventory and verifies all names from
  `LemonChannels.Adapters.Discord.Transport.slash_commands/0` are registered.
  On 2026-05-16 it passed for Zeebot against the then-current 15-command
  inventory and wrote `tmp/discord-all-slash-proof-check.json`; after adding
  `/rollback`, rerun it before broad slash promotion. This is registration
  evidence; pair it with the deterministic local interaction proof for
  schema/runtime breadth. Real client-click proof remains required for broad
  slash-command parity.
- Done in deterministic proof: Discord outbound text, edits, file captions,
  long chunks, component sends, followups, direct transport messages, and
  interaction responses disable mention parsing and reply pings by default;
  `scripts/live_discord_safe_mentions_proof.exs` writes
  `.lemon/proofs/discord-safe-mentions-proof-latest.json` with three completed
  checks.
- Done in deterministic proof: Discord approval components now resolve pending
  core execution approvals and update the interaction safely; `scripts/live_discord_approval_component_proof.exs`
  writes `.lemon/proofs/discord-approval-component-proof-latest.json` with two
  completed checks.
- Done in deterministic proof: Discord cancel and watchdog keepalive buttons
  route to the runtime/router bridge and update interactions safely;
  `scripts/live_discord_runtime_components_proof.exs` writes
  `.lemon/proofs/discord-runtime-components-proof-latest.json` with three
  completed checks.
- Done in deterministic proof: duplicate Discord `MESSAGE_CREATE` events submit
  only one Lemon run through the normal inbound/debounce/runtime path, including
  after simulated ETS loss through a persisted idempotency boundary;
  `scripts/live_discord_dedupe_proof.exs` writes
  `.lemon/proofs/discord-dedupe-proof-latest.json` with four completed checks.
- Done in deterministic proof: Discord `/trigger all` enables unmentioned
  group messages to submit through the runtime path, and `/trigger mentions`
  restores default suppression; `scripts/live_discord_trigger_mode_proof.exs`
  writes `.lemon/proofs/discord-trigger-mode-proof-latest.json` with four
  completed checks.
- deterministic tests for Discord command routing and channel policy

Exit criteria:

- every promoted channel feature has deterministic tests and live proof
- support docs state stable vs preview behavior without ambiguity
- Discord no longer depends on a single channel-only proof for broad claims
  and still needs real client-click evidence before broad slash-command parity

### Slice 4: Media Jobs

Owner lane: Runtime / Channels / AI

Scope:

- Done in preview: model-facing `media_status` exposes redacted media summary,
  recent-job, cleanup, and worker-supervisor status.
- Done in preview: model-facing `media_generate_image` uses the
  `LemonCore.MediaJobSupervisor` path with deterministic `local_svg` output and
  provider-backed `openai_image` or `vertex_imagen` output, redacted
  `LemonCore.MediaJobs` metadata, managed SVG/PNG/JPEG/WebP artifacts, runtime
  credential resolution, transient-provider retry handling, provider-error
  redaction, and optional generated `auto_send_files` metadata.
- Done in preview: model-facing `media_generate_speech` uses the
  `LemonCore.MediaJobSupervisor` path with deterministic `local_wav` output and
  provider-backed `openai_tts`, `elevenlabs_tts`, or `google_tts` output,
  redacted `LemonCore.MediaJobs` metadata, managed MP3/Opus/AAC/FLAC/WAV/PCM
  artifacts, runtime credential resolution, transient-provider retry handling,
  provider-error redaction, and optional generated `auto_send_files` metadata.
- Done in preview: model-facing `media_transcribe_audio` uses the
  `LemonCore.MediaJobSupervisor` path with deterministic `local_transcript`
  output and provider-backed `openai_transcribe` output, path-escape rejection,
  redacted `LemonCore.MediaJobs` metadata, managed JSON/text transcript
  artifacts, runtime credential resolution, transient-provider retry handling,
  provider-error redaction, untrusted marking for model-visible transcript text,
  and optional generated `auto_send_files` metadata.
- Done in preview: model-facing `media_analyze_image` uses the
  `LemonCore.MediaJobSupervisor` path with deterministic `local_vision` output
  and provider-backed `openai_vision` output, path-escape rejection,
  local-only SVG provider restrictions, redacted `LemonCore.MediaJobs`
  metadata, managed JSON/text analysis artifacts, runtime credential
  resolution, provider-prefixed OpenAI-compatible model routing,
  transient-provider retry handling, provider-error redaction, untrusted marking
  for model-visible analysis text, and optional generated `auto_send_files`
  metadata.
- Done in preview: model-facing `media_generate_video` uses the
  `LemonCore.MediaJobSupervisor` path with deterministic `local_mp4` output and
  provider-backed `openai_video` or `vertex_veo` create/poll/download output,
  redacted `LemonCore.MediaJobs` metadata, managed MP4 artifacts, runtime
  credential resolution, transient-provider retry handling, provider-error
  redaction, provider-job-id redaction, and optional generated
  `auto_send_files` metadata.
- provider-backed image generation live proof now reaches OpenAI and Vertex
  providers with redacted failure reasons; it still needs one completed
  provider proof before promotion.
- provider-backed TTS live proof
- provider-backed STT live proof
- Done in preview: provider-backed vision live proof passed on 2026-05-17
  through `scripts/live_media_vision_smoke.exs --model
  openrouter:openai/gpt-4o-mini --api-key-secret OPENROUTER_API_KEY --proof-path
  .lemon/proofs/media-vision-smoke-latest.json`, with `completed_count: 1`,
  `failed_count: 0`, `skipped_count: 0`, and a redacted canonical proof at
  `.lemon/proofs/media-vision-smoke-latest.json`.
- provider-backed video live proof: OpenAI and Vertex Veo both have redacted
  proof lanes; the latest Vertex Veo proof reaches Google but records
  `vertex_veo_create_http_error:permission_denied`, so video still needs one
  completed provider proof before promotion.
- media doctor/operator visibility for channel delivery versus provider-backed
  image/TTS/STT/vision/video proof
- durable media artifacts
- provider config through Lemon secrets/config
- Telegram/Discord delivery adapters and opt-in generated-media live proof
  hooks
- prompt-injection and metadata-redaction tests

Exit criteria:

- each media job is supervised and observable
- generated/analyzed artifacts have durable metadata and cleanup behavior
- channel delivery succeeds in live Telegram/Discord proof for promoted paths;
  Telegram and Discord generated SVG delivery are proven

### Slice 5: API and Editor Adapter Layer

Owner lane: Control Plane / MCP / Web

Scope:

- Done in preview: OpenAI-compatible `GET /v1/health`,
  `GET /v1/capabilities`, `GET /v1/models`, and
  `GET /v1/models/:model_id`, with Lemon capability metadata including
  `supportsVision`
- Done in preview: OpenAI-compatible `POST /v1/chat/completions` and
  `POST /v1/responses` submit Lemon runs through the router/run graph, return
  queued OpenAI-shaped metadata by default, and support `wait: true` /
  `timeout_ms` through `agent.wait`
- Done in preview: metadata-derived `session_key`, `agent_id`, model override,
  synchronous wait completion, Responses output text mapping, wait timeout
  handling, streaming-request metadata, prompt normalization, and validation
  errors are covered by focused HTTP tests
- Done in preview: `GET /v1/runs/:run_id` redacted status and
  `POST /v1/runs/:run_id/cancel` cancellation dispatch
- Done in preview: `GET /v1/responses/:response_id` retrieval for
  `resp_<run_id>` and `previous_response_id` continuation on the prior Lemon
  session key
- Done in preview: opt-in bearer and `x-api-key` auth
- Done in preview: Chat Completions and Responses SSE over Lemon run bus events
- Done in preview: redacted tool-progress SSE mapping from Lemon
  `:engine_action` events without raw tool args/results
- Done in preview: Chat Completions `image_url` parts and Responses
  `input_image` parts hash/redact URL/file-id image references into run metadata,
  pass validated data URL images as runtime-only Lemon image blocks, reflect only
  `lemon.imageInputCount` to clients, and are covered by focused leak-prevention
  and pass-through tests
- Done in preview: known provider-prefixed text-only models reject runtime image
  bytes before run submission, while metadata-only URL/file references remain
  allowed as redacted prompt context
- Done in preview: deterministic live HTTP smoke via
  `scripts/live_openai_compat_smoke.exs` with redacted proof JSON
- Done in preview: the live HTTP smoke includes `non_vision_image_rejection`,
  which posts runtime image bytes to `openai:o3-mini`, expects the sanitized
  400 response, and verifies no submitter run was recorded
- Done in preview: opt-in provider-backed vision smoke harness via
  `scripts/live_openai_compat_vision_smoke.exs`; it submits a data URL image
  through unstubbed `/v1/responses`, passed on 2026-05-16 through OpenRouter
  `openai/gpt-4o-mini` with `completed_count: 1`, `failed_count: 0`, and
  external Node fetch client vision sub-proof `completed_count: 1` /
  `answer_matched_red: true` plus official OpenAI Node SDK vision sub-proof
  `completed_count: 1` / `answer_matched_red: true`, and writes redacted proof
  JSON. It skips when live credentials, a vision-capable model, or a resolvable
  provider credential are missing. Credential preflight uses
  `AgentCore.ModelRuntime.Credentials.provider_has_credentials?/3`, matching runtime provider
  credential resolution instead of a script-local env/key-only check.
- Done in preview: external Node `fetch` client proof through
  `scripts/live_openai_compat_fetch_client.mjs`, nested into the live HTTP smoke
- Done in preview: official OpenAI Node SDK client proof through
  `scripts/live_openai_compat_openai_sdk_client.mjs`, nested into the live HTTP smoke
- Done in preview: official OpenAI Python SDK client proof through
  `scripts/live_openai_compat_python_sdk_client.py`, nested into the live HTTP smoke
- Done in preview: single-model retrieval through `GET /v1/models/:model_id`
  plus `supportsVision` consistency is covered by focused HTTP tests and all
  three external client sub-proofs
- Done in preview: official OpenAI Node and Python SDK clients cover both Chat
  Completions streaming and Responses streaming through SDK stream interfaces
- Done in preview: `POST /acp` JSON-RPC `initialize`, `session/new`,
  `session/resume`, `session/list`, `session/prompt`, `session/cancel`, and
  `session/close`
- Done in preview: ACP text/resource-link prompts submit through the Lemon
  router/run graph, wait through `agent.wait` by default, support queued
  submission through `_meta.lemon.wait: false`, and cancel through
  `LemonRouter.abort_run/2`
- Done in preview: ACP advertises only capabilities it supports; image, audio,
  embedded-resource, MCP HTTP, and MCP SSE prompt paths remain disabled
- Done in preview: ACP optional bearer / `x-api-key` auth, store-backed session
  list/resume, and unsupported media rejection are covered by focused tests
- Done in preview: `scripts/lemon_acp_stdio.exs` packages ACP over
  newline-delimited JSON for spawned stdio clients
- Done in preview: ACP stdio prompt waits emit `session/update` notifications
  from Lemon run bus text deltas and redacted tool-progress events
- Done in preview: ACP stdio prompt waits round-trip
  `session/request_permission`, `fs/read_text_file`, `fs/write_text_file`,
  `fs/delete_file`, and `fs/rename_file` client requests with redacted response
  summaries
- Done in preview: model-facing `read`, `write`, `edit`, and `patch`
  add/update/delete/move operations route through the ACP client filesystem when
  matching safe filesystem capabilities are present
- Done in preview: `scripts/live_acp_stdio_smoke.exs` writes
  `.lemon/proofs/acp-stdio-smoke-latest.json` and proves initialize,
  session creation, queued prompts, waiting prompt updates, list/resume/close,
  parse-error handling, and redacted proof output with `completed_count: 6` and
  `failed_count: 0`
- Done in preview: `scripts/live_acp_stdio_external_client.mjs` spawns the ACP
  stdio bridge as a child process with deterministic fake runtime, sends
  newline-delimited JSON over stdin, observes `session/update` notifications on
  stdout, and writes `.lemon/proofs/acp-stdio-external-client-latest.json` with
  `completed_count: 9`, `failed_count: 0`, `update_count: 2`, and
  `client_request_count: 6`
- Done in preview: `scripts/live_acp_official_sdk_client.mjs` uses official `@zed-industries/agent-client-protocol@0.4.5` `ClientSideConnection` against Lemon stdio and writes `.lemon/proofs/acp-official-sdk-client-latest.json` with `completed_count: 8`, `failed_count: 0`, `update_count: 2`, and `client_request_count: 4`
- Remaining: deployed editor UI proof and broader provider-specific image
  transport proof beyond the passing OpenRouter vision smoke

Exit criteria:

- OpenAI-compatible clients can submit, stream, continue, and cancel a run
- tool progress is observable without corrupting assistant text
- named sessions map to Lemon session/run IDs
- ACP prompt submission and cancellation use the same router/run graph

### Slice 6: Terminal Backend Layer

Owner lane: Agent Core / Services / Security

Scope:

- common terminal backend behavior
- [x] preview common terminal backend behavior and registry
- [x] local backend metadata for the supervised Erlang Port runner
- [x] backend-aware `exec` parameter and `process` list/poll visibility
- [x] read-only `terminal.backends.status` control-plane operator surface
- [x] local PTY backend via util-linux `script(1)` when available
- Docker backend
- SSH backend
- resource limits, logs, approval policy, and support-bundle metadata

Completed in preview:

- `LemonCore.TerminalBackend` defines the backend contract and
  `LemonCore.TerminalBackends` resolves registered backends without creating
  atoms from arbitrary user input.
- `LemonCore.TerminalBackends.Local` reports `:erlang_port`, host isolation,
  `pty: false`, supervision, and shell/stdin/logs/kill/exit-status/cwd/env
  capabilities for the existing process runner.
- `LemonCore.TerminalBackends.LocalPty` reports `:util_linux_script`, host
  isolation, `pty: true`, supervision, and PTY capability when `script(1)` is
  available.
- `LemonCore.TerminalBackends.Docker` reports `:docker_cli`, container
  isolation, cwd mounting at `/workspace`, no implicit image pulls, dropped
  capabilities, no-new-privileges, read-only root filesystem by default,
  bounded `/tmp` tmpfs scratch space, no-network default, and default CPU,
  memory, and pids limits.
- `LemonCore.TerminalBackends.Ssh` reports `:openssh_cli`, remote-host
  isolation, `BatchMode=yes`, connect timeout, strict host-key policy, and a
  redacted target hash when `LEMON_SSH_TERMINAL_TARGET` is configured.
  It supports `LEMON_SSH_TERMINAL_IDENTITY_FILE` and
  `LEMON_SSH_TERMINAL_USER_KNOWN_HOSTS_FILE` so controlled proof harnesses and
  operators can use managed key material without exposing raw paths in
  diagnostics or proof JSON.
- `LemonCore.TerminalBackendPolicy` enforces
  `LEMON_TERMINAL_BACKENDS_ALLOW`, `LEMON_TERMINAL_BACKENDS_DENY`, optional
  `LEMON_DOCKER_TERMINAL_ALLOWED_IMAGES`, and optional
  `LEMON_SSH_TERMINAL_ALLOWED_TARGETS` before launch; diagnostics expose SSH
  targets only as hashes. It also validates Docker image, network, memory, CPU,
  pids, and tmpfs-size policy plus SSH port, connect-timeout, and
  strict-host-key policy before launch so invalid container/remote settings fail
  closed at the Lemon policy boundary.
- `LEMON_TERMINAL_BACKENDS_REQUIRE_APPROVAL` lets operators require
  backend-specific `exec` approval; the approval action includes backend,
  command hash, cwd hash, and env keys only.
- `exec` accepts `backend: "local"`, `backend: "local_pty"`, and
  `backend: "docker"`, and `backend: "ssh"`, and rejects unknown or
  unavailable or policy-blocked backends before launch.
- `process` list/poll results expose backend and terminal capabilities for
  model/operator visibility.
- `terminal.backends.status` returns registered backend metadata and cleanup
  assertions without commands, environment values, or process output.
- Support bundles include `terminal_diagnostics.json`, and Web `/ops` renders
  backend count, default backend, backend capabilities, policy state, and
  cleanup assertions without commands, environment values, process output, or
  raw SSH targets.
- `scripts/live_terminal_backend_smoke.exs` runs a redacted command through
  every registered backend and writes hashed command/cwd/output proof JSON.
  Its Docker path now proves the launched container actually sees read-only
  rootfs, no-exec `/tmp`, dropped effective capabilities, no-new-privileges,
  pull policy `never`, network `none`, memory `1g`, CPUs `2`, and pids limit
  `256`.
  When no SSH target is configured and local `sshd` plus `ssh-keygen` are
  available, it starts an ephemeral loopback `sshd` with generated host/client
  keys and temporary known-hosts storage instead of touching `~/.ssh`. The
  latest local run completed `local`, `local_pty`, `docker`, and loopback
  `ssh`, skipped zero backends, and failed zero backends.
- `scripts/live_terminal_process_smoke.exs` writes
  `.lemon/proofs/terminal-process-latest.json` after completing a local process,
  validating bounded-log metadata, restarting the finished process as a fresh
  supervised child, verifying restart lineage, and cleaning up both records
  without raw commands, logs, or process ids in the proof. The latest local run
  completed 5 checks with zero failures and zero skips.
- Focused core/support/policy proof passed with `15 tests, 0 failures`.
- Focused coding-agent terminal proof passed with `96 tests, 0 failures`.
- Focused process restart/log-metadata proof passed with `124 tests, 0 failures`.
- Focused control-plane status proof passed with `33 tests, 0 failures`.
- Focused Web `/ops` proof passed with `23 tests, 0 failures`.

Exit criteria:

- background processes can be spawned, logged, waited, killed, and manually
  restarted after completion without mutating the original record
- PTY mode works for interactive CLIs
- backend failure returns structured tool errors
- no backend bypasses Lemon tool policy or observability

### Slice 7: Persistent Goals

Owner lane: Automation / Router / Channels

Scope:

- durable goal state keyed by session/run context
- judge-model routing and verdict schema
- continuation budget, pause/resume/clear/status
- Web/TUI/Telegram/Discord controls
- fail-open and budget-exhaustion behavior

Progress:

- [x] durable per-session goal state in `LemonCore.GoalStore`
- [x] redacted goal diagnostics in support bundles
- [x] `goal.set`, `goal.status`, `goal.pause`, `goal.resume`, `goal.continue`, `goal.loop.once`, `goal.loop.start`, `goal.loop.status`, `goal.loop.stop`, and `goal.clear` control-plane methods
- [x] supervised one-shot continuation submission through `LemonAutomation.GoalContinuationManager` and `LemonRouter`
- [x] preview judge verdict tick, bounded autonomous loop, and opt-in persisted auto scheduling through `LemonAutomation.GoalLoopManager`, `GoalJudge`, `goal.loop.once`, and `goal.loop.start`
- [x] TUI `/goal` status/set with budgets/pause/resume/continue with options/loop once with judge options/loop start with budget, judge, and auto options/loop status/loop stop/clear command
- [x] Telegram and Discord `/goal` status/set-with-budget/pause/resume/continue/loop/auto/clear commands
- [x] Web `/ops` goal status, max-continuation budget, and loop status
- [x] preview verdict schema
- [x] judge-runner routing with model metadata and deterministic fail-open/fail-closed tests
- [x] router-backed `:goal_judge` runner with JSON verdict parsing
- [x] dev/prod default judge runner config with `LEMON_GOAL_JUDGE_MODEL` override
- [x] persisted `maxContinuations` budget and budget-exhaustion tests
- [x] opt-in always-on autonomous scheduling
- [x] router queue proof that fresh channel/control-plane user submissions
  start before queued autonomous `goal_continuation` follow-ups
- [x] production-shaped router judge proof through `GoalJudge.RouterRunner`, `LemonRouter`, router `RunProcess`, and `RunCompletionWaiter`
- [x] production-shaped persisted-auto scheduler proof through `GoalLoopManager`, `GoalLoop`, and the router judge path
- [x] opt-in provider-backed live model judge test harness
- [x] provider-backed live model judge proof with Z.ai `glm-5-turbo`

Exit criteria:

- a user can set a goal once and Lemon continues until done, blocked, paused, or
  budget-exhausted
- user messages preempt continuation
- judge failures do not wedge the session

### Slice 8: Kanban Boards

Owner lane: Automation / Agent Core / Web

Scope:

- durable board/task/comment/link schema
- worker profile and assignee model
- dispatcher supervisor with stale-claim and crash reclaim
- scratch and worktree workspaces under `.worktrees/`
- model-facing board tools
- Web board view

Exit criteria:

- multiple workers can coordinate through durable tasks without sharing one
  fragile parent context
- blocked tasks can be unblocked by a human or orchestrator
- crashed workers are visible and reclaimable

### Slice 9: LSP Diagnostics

Owner lane: Agent Core / Tools

Scope:

- Done in preview: model-facing `lsp_diagnostics` tool
- Done in preview: opt-in baseline/delta diagnostics after `write`, `edit`,
  and `patch`
- Done in preview: deterministic Elixir syntax diagnostics plus local checker
  fallback for JavaScript, TypeScript, Python, Rust, Go, and C/C++ when
  workspace tools or compilers are present
- Done in preview: redacted `lsp.diagnostics.status`, Web `/ops` checker
  visibility, and support-bundle `lsp_diagnostics.json`
- Done in preview: supervised `LemonCore.LspServerManager` registry/status and
  stdio session lifecycle process with ElixirLS, TypeScript Language Server,
  Pyright, rust-analyzer, gopls, and clangd metadata
- Done in preview: control-plane `lsp.server.start`, `lsp.server.initialize`,
  `lsp.server.request`, and `lsp.server.stop`
- Done in preview: Content-Length JSON-RPC request/response framing with timeout
  handling over supervised stdio sessions
- Done in preview: request timeouts terminate unhealthy sessions and their
  launcher descendants, with a live broken-wrapper cleanup proof leaving no
  language-server processes running
- Done in preview: initialize/initialized sequencing and redacted
  `textDocument/publishDiagnostics` notification counters over supervised stdio
  sessions
- Done in preview: `textDocument/didOpen`, `textDocument/didChange`, and
  `textDocument/didClose` notification orchestration with only URI hashes,
  versions, byte counts, and counters in status surfaces
- Done in preview: JavaScript syntax, Python clean/error, TypeScript
  no-tsconfig skip, TypeScript tsconfig diagnostics, Go workspace diagnostics,
  Rust workspace diagnostics, and C compiler diagnostics fixtures
- Done in preview: `docs/tools/lsp.md` checker/server install guide,
  control-plane method guide, and proof lane guide
- Done in preview: `scripts/live_lsp_server_smoke.exs` proves real supervised
  stdio sessions through initialize, document open, redacted
  `publishDiagnostics` capture, and proof JSON. The default Pyright lane still
  passes, and the full `--servers pyright,gopls,clangd,rust_analyzer,typescript_language_server,elixir_ls` lane passed on 2026-05-16
  with `completed_count: 6`, `failed_count: 0`, and `clean_after_change: true` for every server.
- Done in preview: `--editor-flow` reintroduces diagnostics after a clean edit,
  clears them again, and closes the document. The full six-server editor-flow
  proof passed on 2026-05-16 with `completed_count: 6`, `failed_count: 0`,
  non-zero reintroduced diagnostics, `final_clean_after_second_change: true`,
  and `editor_flow_close_status: "closed"` for every server.
- Done in preview: `--real-repo-fixtures --editor-flow` now covers the full
  registered server fleet (`pyright`, `gopls`, `clangd`, `rust_analyzer`,
  `typescript_language_server`, and `elixir_ls`) against copied or maintained
  Lemon repository fixtures. The latest proof wrote
  `.lemon/proofs/lsp-real-repo-fixtures-latest.json` with `completed_count: 6`,
  `failed_count: 0`, non-zero injected/reintroduced diagnostics, final clean
  diagnostics, closed documents, source hashes only, and cleanup flags false for
  raw paths, file contents, diagnostic output, raw session ids, and server I/O.
- Remaining for stable parity: broader editor integration and operational
  promotion criteria.

Exit criteria:

- new semantic diagnostics introduced by an edit are surfaced to the agent
- missing/flaky servers do not fail writes
- docs explain install/status/troubleshooting
- Web/support-bundle status makes diagnostic capability and failures visible

### Slice 10: Plugin and Provider Ecosystem

Owner lane: Skills / MCP / AI / Security

Scope:

- plugin manifest and host lifecycle
- Done in preview: default global/project extension directories are
  diagnostics-only unless explicitly trusted with
  `[runtime.extensions] auto_load_default_paths = true`; configured
  `[runtime] extension_paths = [...]` remains the execution trust boundary.
- Done in preview: support bundles, Web `/ops`, and `extensions.status` expose
  redacted BEAM/WASM/MCP/external host-runtime status, degraded host counts,
  manifest-only host counts, WASM supervisor state, and explicit cleanup flags
  showing these diagnostics do not load default-directory plugin code.
- Done in preview: `scripts/live_wasm_telemetry_smoke.exs` proves redacted
  WASM wrapper start/stop/exception telemetry for successful execution,
  returned sidecar errors, and sidecar exits.
- enable/disable policy beyond the default-directory trust boundary
- hook/tool/skill/provider/memory-provider extension points
- provider routing, fallback, and credential pools
- audit and conflict handling

Exit criteria:

- third-party code cannot run without explicit enablement
- plugin failures degrade with useful diagnostics
- external memory/provider plugins are visible in `/ops` and support bundles

### Slice 11: Cron Diagnostics and Scheduler Promotion

Owner lane: Automation / Core Support / Channels

Scope:

- Done in preview: `LemonCore.Doctor.CronDiagnostics` reads the core cron store
  tables and summarizes job/run counts, enabled/disabled counts, active/failed
  run counts, status counts, trigger counts, next/last timestamps, recent job
  shape, and recent run shape without taking a dependency on
  `lemon_automation`.
- Done in preview: support bundles include `cron_diagnostics.json` with hashed
  job/run ids, agent ids, session keys, prompts, outputs, errors, schedules,
  names, and memory-file paths. It records metadata keys only and omits raw
  prompts, outputs, errors, session ids, agent ids, memory paths, and metadata
  values.
- Done in preview: `scripts/live_cron_diagnostics_smoke.exs` passed
  `cron_diagnostics_counts`, `cron_diagnostics_retry_policy`,
  `cron_diagnostics_redaction`, and `cron_support_bundle_entry` with 0
  failures.
- Done in preview: scheduled ticks consult persisted active runs and do not
  launch a duplicate run while the same job has a pending/running run.
- Done in preview: active runs older than the job timeout recover as
  `:timeout`, clearing stale scheduler locks without raw output exposure.
- Done in preview: channel-origin scheduled summaries persist the synthetic
  base-session completion and enqueue through `LemonChannels` via the narrow
  `LemonRouter.ChannelsDelivery` bridge.
- Done in preview: `scripts/live_cron_channel_origin_smoke.exs` registers
  proof-only Telegram and Discord plugins, completes channel-peer cron runs
  through `CronManager`, proves forwarded run history plus
  `LemonRouter.ChannelsDelivery` -> `LemonChannels` outbox delivery, and writes
  `.lemon/proofs/cron-channel-origin-latest.json` with redacted channel-shape
  metadata and hashed cron IDs.
- Done in preview: cron creation/update accepts supported schedule shorthands
  such as `every 30m`, `hourly`, `every 2h`, `daily at 9am`,
  `weekdays at 09:30`, and `weekly monday at 8am`, then stores the normalized
  5-field cron expression so all execution still goes through the same BEAM
  scheduler. Interval shorthands must divide the enclosing cron field exactly,
  so rejected non-divisor intervals fail as input errors instead of storing
  misleading cron steps.
- Done in preview: control-plane operators can create no-agent command cron
  jobs with `command` instead of `agentId`/`sessionKey`/`prompt`. Command jobs
  run as supervised local shell commands under `CronManager`, store output/error
  in cron run history, retry through the same scheduled retry policy, and do not
  create LemonRouter runs or channel summaries. The model-facing `cron` tool
  remains prompt-job scoped.
- Done in preview: scheduled failures/timeouts can retry as separate `:retry`
  runs with `max_retries`, `retry_backoff_ms`, and redacted lineage metadata;
  manual and wake runs do not retry by default.
- Done in preview: `CronManager` restart reloads persisted jobs without
  duplicate scheduled submission while an active run is persisted, and recovers
  stale active runs as `:timeout` during initialization.
- Done in preview: control-plane `cron.pause` / `cron.resume` and model-facing
  `cron` tool pause/resume actions expose explicit lifecycle controls over the
  existing `enabled` state.
- Done in preview: active cron runs can be aborted by cron run id through
  control-plane `cron.abort` and the model-facing `cron` tool. The abort path
  routes to the underlying Lemon run cancellation when available, persists a
  terminal `:aborted` cron run, and ignores late submitter completions.
- Done in preview: Web `/ops` renders active recent cron runs with an Abort
  action that calls the same cron-run abort path and refreshes the redacted
  schedule/run snapshot.
- Done in preview: TUI `/cron abort <run-id>` routes through the control-plane
  `cron.abort` method and keeps focused command parsing plus WebSocket routing
  coverage green.
- Done in preview: cron lifecycle actions persist durable operator audit events
  in `:cron_audit_events`; control-plane `cron.audit` exposes filterable raw
  operator IDs to authorized clients, the WebSocket bridge emits `cron.audit`,
  and Web `/ops` renders recent lifecycle audit entries.
- Done in preview: support bundles and `CronDiagnostics` expose redacted audit
  counts, action counts, recent audit event shape, reason hashes, ID hashes,
  and changed-field names without raw audit IDs or reasons.
- Done in preview: `CronDiagnostics` classifies terminal `:aborted` runs as
  `aborted` instead of `unknown`.
- Done in preview: `scripts/live_cron_runtime_restart_smoke.exs` boots
  `:runtime_full` twice against one isolated durable store and proves scheduled
  run history survives restart plus a fresh scheduled run fires after restart.
- Remaining: live external-channel proof for deployed Telegram/Discord cron
  workflows.

Exit criteria:

- cron scheduler state survives full runtime restarts without duplicate execution
- scheduler locks prevent competing dispatchers from double-running a job
- bounded retry/backoff state and support-safe error shape stay covered
- channel-origin scheduled runs keep delivering completion to the correct origin
  surface
- Telegram- and Discord-shaped channel-origin cron runs have a reusable proof
  artifact that covers forwarded history and channel outbox delivery
- supported schedule shorthands normalize to the same 5-field cron expressions
  used by the durable scheduler path, with non-divisor intervals rejected as
  operator input errors
- no-agent command cron jobs run through a supervised BEAM path without
  requiring agent/session routing
- support bundles, Web, and control plane expose enough redacted cron state to
  debug production scheduling failures
- durable audit history records who/what changed cron lifecycle state without
  leaking prompts, outputs, credentials, or raw support-bundle identifiers

## Completion Bar

The implementation goal is satisfied when Lemon can credibly say:

- Telegram and Discord are first-class stable remote channels for the promoted
  text, file, media, command, cancellation, approval, and restart scopes.
- Browser, media, checkpoint, terminal, API/editor, goal, kanban, LSP, plugin,
  provider-routing, memory, skill, delegation, and cron surfaces are either
  stable with proof or explicitly preview with a named remaining gap.
- Every promoted parity surface is supervised, observable, durable where needed,
  tested, documented, and supportable.
- The public docs no longer describe "Hermes but better, on BEAM" as an
  aspiration; they point to working features and proof.
