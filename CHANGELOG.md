# Changelog

All notable changes to Lemon are documented here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).
Versions follow [CalVer](https://calver.org/) — `YYYY.MM.PATCH`.

---

## [Unreleased]

### Fixed

- Background process launches no longer bypass admission after queue failures.
  Fixed, owner-bound launch identities reconcile lost acknowledgements and
  reject conflicting retries instead of risking duplicate external effects.
- Background execution now holds a validated live-process capacity limit until
  confirmed termination, bounds pending admission and waiting, prevents canceled
  or expired queued commands from starting, and retains unknown capacity through
  restart. Yielded launches remain owner-scoped and inspectable; cancellation
  receipts no longer claim termination before it is confirmed.
- Local Unix background capacity now stays held when the root shell exits but
  descendants survive. Owned process groups are bound before command execution;
  live members are retained before forwarding stdin that can end the root, so
  verified cancellation still works after natural root exit. Groups reconcile
  until confirmed empty; stale ownership and unsupported workload witnesses
  remain unknown rather than freeing slots or signaling recycled PIDs.
  Repeated cancellation also requires the backend-aware workload witness:
  an empty host wrapper group cannot release SSH, container or PTY capacity.
  TUI tool cards and compact shelves also preserve queued and outcome-unknown
  receipts instead of presenting them as started or failed.

---

## [2026.10.5]

### Added

- **omp and Claude Code subagent definitions.** Task personas are also
  discovered from project `.omp/agents/` and `.claude/agents/` (cwd up to the
  Git root) and from `~/.omp/agent/agents/` and `~/.claude/agents/`, below the
  `.lemon` directories. Those files are read tolerantly (ID from `name`,
  unknown fields ignored, invalid files skipped). All definitions accept
  comma-separated `tools`/`model`, omp/Claude tool names, thinking-level
  aliases, `spawns`, and an `output` schema in JSON Schema or JTD form (JSON
  Schema constraints are preserved even without an explicit `type`). New
  shipped personas: read-only `security-reviewer` and the `@smol` mechanical
  worker `sonic`.
- **Task worktrees can merge back.** `task` gains `merge` (`none`, `patch`,
  `branch`; default `[runtime.task].worktree_merge`) for `worktree: true`
  children. `patch` replays the parent's uncommitted work into the worktree
  and, when the child succeeds, applies its changes to the parent checkout,
  failing closed on conflicts with the patch kept for review. `branch` commits
  the child's work on its kept `lemon/task-<id>` branch without merging it.
  Merge-back rechecks cancellation before mutation and retains detached or
  switched-branch worktrees for manual review. Both patch and branch modes retain
  committed or staged submodule changes, including index-only pins, and initialized
  HEAD/content changes even under `ignore = all`, without overwriting the original
  index or deleting recoverable work. Results report `details.merge`.
- **Task runtime parity with omp.** `task` accepts a top-level `context`
  shared by every child of a run, batch, or swarm. Persona thinking levels and
  output schemas become child defaults. Invalid structured output is
  re-prompted in the same child up to twice; `schema_mode: "permissive"`
  returns the text with `structured_output_error` instead of failing.
  `read agent://<id-or-name>` returns an owned child's status and output (even
  after it finishes), and `agent://<id>/<key>/…` extracts a `structured_output`
  field. New `[runtime.task]` settings: `max_depth` (default 2) caps nesting
  and persona `spawns` grants allowlisted delegation below it,
  `max_runtime_ms` limits each child, `disabled_agents` hides personas, and
  `agent_models` overrides persona models.
  Child depth/allowlists survive extension reloads, resumed user forks can
  still delegate, and live `agent://` names override completed namesakes.
- Context parity hardening: overlapping secret sources are redacted without
  exposing credential fragments; malformed secret YAML does not echo values
  into logs. Private plan tools restore placeholders and enforce interception
  hooks without bypassing their directory boundary. Foreign-global MCP configs
  still require opt-in when launched from home, enabling a server clears every
  matching denylist entry, and hidden skills stay out of missing-key suggestions.
  File commands preserve empty positional arguments, consume one-shot submission
  modes, and expand on local steering/redirect without expanding internal or
  named-destination prompts. Inline-code imports respect matching backtick runs
  across lines.
- Secret placeholders now protect friendly labels against every contextual
  regex value in the current input and previously matched session values,
  including overlap constituents, cached labels and forged token-shaped
  prefixes. Regexes retain context across protected tokens, and self-overlapping
  literal secrets redact their complete union without leaving a credential
  suffix visible. Provider batches collect regex values and reserve original raw
  tokens before emitting any message, block or nested argument, preventing
  cross-field label leaks and accidental restoration of original token-shaped
  text while retaining the existing system/image/metadata exclusions.
- Skills with `hide: true` or `disable-model-invocation: true` frontmatter are
  omitted from the model-visible skill listing and per-turn relevant-skill
  hints, yet stay listed and loadable by name (`read_skill`, `skill://`,
  `/skill:<name>`). See [skill manifest](docs/reference/skill-manifest-v2.md).
- File slash commands from Claude Code (`.claude/commands`, nested `a:b`),
  Codex (`.codex/prompts`), Copilot (`.github/prompts/*.prompt.md`), Gemini
  (`.gemini/commands/*.toml`), omp and `.agents` roots, plus their user-global
  dirs: `/name args` expands server-side for TUI, ACP and channel prompts, and
  the TUI palette, `/help` and ACP command list show them. Skills also load from
  `.codex/skills`, `.github/skills` and `~/.codex/skills`. See
  [File slash commands](docs/user-guide/slash-commands.md).
- **Secret obfuscation (opt-in).** With `[runtime.secret_obfuscation]
  enabled = true`, native sessions replace secret-shaped environment values,
  `secrets.yml` entries (global and project; plain or regex, obfuscate or
  replace) and GitHub/GitLab/OpenAI/Anthropic-style tokens in provider-visible
  messages with keyed `$$…$$` placeholders, and restore them in tool arguments
  before a tool runs. Session history keeps the original text. See
  [Secret obfuscation](docs/security/secret-obfuscation.md).
- **MCP servers from other tools.** Lemon now also loads MCP servers declared in
  omp, Claude Code, Codex, Gemini CLI, OpenCode, Cursor, Windsurf and VS Code
  configs and root `mcp.json`/`.mcp.json` (project files by default; other
  tools' `~/` files with `LEMON_MCP_EXTERNAL_USER_DISCOVERY=1`), below Lemon's
  own files. `lemon mcp enable|disable NAME` toggles any server per project or
  `--global`, and `lemon mcp list --all` shows the effective set with sources.
  Turn the import off with `LEMON_MCP_EXTERNAL_DISCOVERY=0`. See
  [Skills: Servers from other tools](docs/skills.md#servers-from-other-tools).
- Native sessions load other agents' instruction files: `GEMINI.md`,
  `CLAUDE.local.md`, `.gemini/`, `.agent(s)/`, `.omp/` and
  `.github/copilot-instructions.md` per directory, plus Gemini, Codex, OpenCode,
  `.agents` and Copilot globals, with `@path` imports expanded. Cursor,
  Windsurf, Cline, GitHub Copilot, `.agents` and `.lemon/rules` rule files are
  injected when always-apply and otherwise listed in a rulebook the model reads
  on demand. See [Instruction files and rules](docs/user-guide/context-files.md).
- Extension hooks can intercept tools: `on_tool_call` blocks a call or
  replaces its arguments (a raising handler blocks), and `on_tool_result`
  replaces a successful result's content/details. New `on_session_start` and
  `on_session_shutdown` hooks observe session lifecycle. See
  [Extensions: Intercepting tool calls](docs/extensions.md#intercepting-tool-calls).

### Fixed

- Extension result presentation hooks preserve authoritative checkpoint receipts
  and affected paths. Content-only or custom display details cannot erase real
  mutation provenance or fabricate receipts; omitted details retain the original.
  Reserved diff aliases, resolved locations and mutation line numbers are protected
  in both key forms; omitted snapshots and absent location lines remain absent.
- Direct, deferred and WASM-host targets restore secrets before interception
  under both disclosure profiles, including after reload. Private plan writes
  retain their restricted file boundary, and repeated plan refreshes no longer
  capture earlier wrapper generations.
- Active plan-mode extension reload now binds private writes, edits and proposals
  to newly loaded hooks immediately, preventing stale handlers from bypassing a
  new mutation blocker.
- OpenCode MCP discovery substitutes environment and file placeholders once in
  decoded JSONC string values. Quotes, backslashes and multiline environment
  values no longer invalidate the config and silently drop servers; inserted
  text cannot trigger another interpolation or file import. File path resolution,
  trimming and missing-value behavior are preserved.

---

## [2026.10.4]

### Added

- Opt-in `runtime.tools.disclosure.profile = "coding"` keeps a coding core
  directly exposed and defers optional registry-resolved built-ins behind
  `tool_search` / `tool_invoke`. Explicit pins and per-session overrides support
  isolated trials; defaults and caller-supplied toolsets remain unchanged.
  Disclosure diagnostics include resolved inventories, estimated schema size
  and a safe catalog/policy digest. Bridged calls retain approval, plan-mode,
  checkpoint, cancellation and sequential execution constraints. No cost or
  latency improvement is claimed; see [Tool Disclosure](docs/config.md#tool-disclosure).

### Fixed

- WASM host aliases resolve permitted deferred built-ins from the same frozen,
  wrapped disclosure catalog under both profiles, retaining plan-mode and reload
  authority boundaries while refusing WASM and disclosure-bridge recursion.
- Background process output now enforces finite retained-memory, artifact,
  owner and runtime storage byte quotas before capture growth. Oversized
  chunks/partial lines retain a bounded diagnostic tail; polling and artifact
  handles report incomplete output honestly. Write failures stop capture
  without changing execution status, and failed cleanup keeps its storage
  charge instead of allowing quota bypass. TTL cleanup removes expired closed
  captures even while their completed sessions linger for final polling.
  Capture accounting now serializes record mutations with reclamation, preserves
  live capture state across store-only restart, and rejects unpersisted
  reservations or unknown legacy artifact usage before process launch.

---

## [2026.10.3]

### Added

- **Lemon Web, rebuilt.** The browser UI is now a full workspace on the same
  control-plane methods and events as the TUI. Chat streams Markdown with
  highlighted code, thinking blocks and rich tool cards (shell output and exit
  status, diffs, reads, searches, todos, subagents), with attachments,
  follow-up/steer/redirect queueing, stop, inline approvals, model/thinking/
  tool-policy pickers, plan mode with Approve & execute / Refine, a context
  usage inspector with Compact, a git Changes viewer, fork and split view. New
  pages: omp, session manager, automation (kanban, goals, cron create/edit),
  blueprints, skills, memory, MCP, nodes, models, usage, diagnostics and
  settings; plus a ⌘K command palette with global search, `?` shortcut help,
  `g` navigation chords, run/approval notifications, light/dark themes and
  phone layouts. See [Use Lemon in a Browser](docs/user-guide/web.md).
- Control-plane methods for the web UI: `sessions.changes` (git status and
  bounded diffs of a session workspace), `doctor.run` (read-only `lemon doctor`
  checks), skill, MCP and node listings and lifecycle actions, `usage.cost`
  breakdowns by provider/model/session/day, and model pricing in
  `models.list`. `ProviderConfiguration` can set the default model and thinking
  level with the same preview/apply revision flow.
- **Delegate work to omp.** Lemon can run tasks in
  [omp](https://github.com/can1357/oh-my-pi) sessions: ask in chat ("run this
  in omp"), use the TUI's `/omp` panel, or `lemon omp start`. Lemon starts omp
  in the workspace over its RPC protocol and reports live status — activity,
  tools, todos, subagents, tokens and cost, latest output — and can steer,
  queue follow-ups, cancel, close and resume sessions. `lemon omp discover`
  lists omp's stored sessions for a workspace (read-only). omp output is
  treated as untrusted data, control fails closed, omp processes end with the
  runtime, and everything degrades to "omp is not installed" without the
  binary. See [Delegating to omp](docs/user-guide/omp.md).
- `lemon config migrate` rewrites deprecated sections (`[agent]`, `[agents.*]`,
  `[tools.*]`) in the global and project config to the current schema, keeping
  comments and a `config.toml.bak-<timestamp>` backup; `lemon setup` does the
  same for an existing config.

- **TUI startup logo.** `lemon` now opens with a block-glyph lemon painted in a
  yellow gradient with a green leaf, beside the version and key hints. It uses
  only `█ ▀ ▄` cells, so it renders in Tern and any UTF-8 terminal; ASCII
  locales and terminals narrower than 50 columns keep the one-line banner.
- **`lemonup` version switcher.** `bin/lemonup` switches `~/.lemon/bin/lemon`
  between installed releases (`lemonup use 2026.10.2`) and a source checkout
  (`lemonup use local [checkout]`), installs and removes releases, and moves a
  running runtime to the new selection. `lemonup update` installs the latest
  stable release if needed and activates it, from a release or from source.
  `install.sh --resolve-version` prints the version an install would pick. It
  was briefly `bin/lvm`, which collides with the Linux LVM2 command; replace a
  `~/.lemon/bin/lvm` link with one to `bin/lemonup`. Selections made with the
  old name are still recognized. See
  [Source development](docs/install.md#switching-between-releases-and-source-with-lemonup).
- **Tern-native TUI surfaces.** `lemon tui` in Tern now uses the same native
  surfaces as omp instead of painted rows. The composer shows a context meter,
  attachment chips, clickable model and effort chips, status facts, last-run
  usage, and Send/Stop. Tool calls are structured cards: shell run boxes with
  exit status, native diffs, numbered reads, file rows, web-search sources, a
  todo checklist, and subagent rows. Prompts show their send time, finished
  turns get a Copy/usage footer, and thinking shows a live spinner. The
  transcript also has error frames, a working row with Stop, editable queued
  prompts, and approval buttons. Pickers (sessions, models, command palette,
  `/output`) open as native sheets, and the welcome card draws the lemon as an
  image. Other terminals render as before.
- **Claude Pro/Max sign-in.** `lemon model anthropic` (and the Anthropic choice
  in `lemon setup`) signs in with a Claude subscription in the browser using
  Anthropic's OAuth PKCE flow, without Claude Code installed. The login is
  stored encrypted, refreshed automatically with one refresh per runtime, and
  fails closed when Anthropic rejects it. Headless sessions paste the
  `code#state` from Anthropic's code page. Anthropic currently bills these
  requests to the account's extra usage, not the plan's included limits.
- `lemon model PROVIDER --status` shows the auth source, stored login, expiry
  and whether credentials are usable; `--logout` deletes the stored OAuth login
  and its config keys.
- **Context-window usage breakdown.** `/context` (alias `/ctx`) in the TUI and
  `/context` in ACP chat, plus `lemon sessions context <key>`, show how the next
  request spends the model's context window: system prompt, tool definitions,
  skills, context files, memory, messages, tool results, summaries and free
  space, with the largest contributors and the auto-compaction threshold. In
  Tern the TUI renders it as a native sheet whose meter matches the composer's
  context meter (click the meter to open it); the status-bar gauge and composer
  meter also use the measurement for resumed sessions before their first run.
  All surfaces read the new read-scoped `sessions.context` control-plane method;
  category splits are estimates scaled to the provider-reported total.

### Changed

- **Lemon Web sign-in uses the operator token.** Every page now requires the
  control-plane operator token (the launcher-managed token by default) through
  a login page; `lemon web` signs in automatically via the URL fragment. The
  separate `LEMON_WEB_ACCESS_TOKEN`, `?token=` login, the optional unauthenticated
  chat route and the `/manage/*` pages are removed. Without a token the UI fails
  closed unless tokenless loopback compatibility is explicitly enabled and the
  peer is loopback; failed logins are throttled.

- Anthropic OAuth sign-in no longer runs `claude setup-token` or copies Claude
  Code's credentials; a pasted setup token is still accepted.
  `LEMON_ANTHROPIC_CLAUDE_PATH` is removed.

- **Plan mode works like omp's `/plan`.** `/plan` toggles plan mode in the TUI
  and in ACP chat (`/plan <request>` enters it and sends the request). While on,
  only read-only tools run; the agent drafts `<slug>-plan.md` in a
  session-private plan directory and calls `propose_plan`, which asks
  **Approve and execute** / **Refine plan**. Approving turns plan mode off and
  the agent implements the plan in the same turn; `/plan` again exits without
  approving. The TUI status line shows `plan` while active. ACP no longer
  advertises Code/Plan session modes or a `mode` config option, so Tern shows no
  plan-mode selector; `session/set_mode`, `/approve-plan`, `/discard-plan` and
  the `sessions.plan` `approve`/`discard` actions are removed (`exit` replaces
  discard). Sessions saved with the previous reviewed-plan lifecycle keep their
  plan mode or approved plan when loaded.

- **`lemon` opens the TUI in Tern.** Plain `lemon` in a Tern pane now opens the
  Lemon TUI on Tern's native surfaces, as `lemon tui` does, instead of
  redirecting to `tern acp lemon`. The native ACP chat stays available with
  `tern acp lemon` (or any ACP client running `lemon acp`). `lemon tern install`
  no longer turns on Tern's `agents.auto_acp`, which only wraps Tern's built-in
  agent CLIs (`claude`, `codex`, `copilot`); an existing value is left as is.

### Fixed

- `sessions.patch` tool policies (web picker, TUI `/toolpolicy`) now reach runs;
  the router previously merged the whole policy row instead of its tool policy.
- Usage is recorded: `usage.status`/`usage.cost` were always zero because
  finished runs were never added to a ledger. `logs.tail` now returns recent
  runtime log lines from a bounded in-memory buffer.

- The TUI no longer rewrites `~/.lemon/config.toml` with a deprecated `[agent]`
  table when you pick a default model (Ctrl+G / **Make default**) or run
  `/theme`. That rewrite dropped `[defaults]`, `[runtime]`, `[gateway]` and
  `[tui]`, and the `[agent]` table then stopped the runtime, `lemon setup` and
  every test run from starting. The TUI now edits only `[defaults]
  provider`/`model` and `[tui] theme` in place.
- A config with a legacy `[agent]` table loads again: it is read as
  `[defaults]`/`[runtime]`/`[tui]` with a warning (log, `lemon doctor`,
  `lemon config validate`) instead of failing boot.
- Fresh `lemon setup` no longer leaves an `[providers.anthropic]` reference to
  a credential that does not exist when you sign in to another provider, and
  non-interactive setup without `--model` no longer writes the model
  `<provider>:fallback`.
- Config edits by setup match table headers written with quoted keys
  (`[providers."openai-codex"]`) instead of appending a duplicate table.
- Umbrella tests run with an isolated `HOME`, so a personal
  `~/.lemon/config.toml` can no longer fail or skew them.

- Document reads (PDF and other converted formats) no longer report
  "Cannot start document backend" when the converter exits while its port is
  being closed; the real result or size/time-limit error is returned.
- Durable project-fact capture no longer skips a finished turn as busy or
  unavailable in the moment after an earlier capture for that project or
  another one ends; a worker that has exited no longer holds its project or
  one of the eight capture slots.

---

## [2026.10.2]

### Fixed

- **ChatGPT model discovery.** Codex requests and model discovery send client
  version 0.159.0 (matching omp). With 0.153.0 the ChatGPT backend omitted
  GPT-6 Luna, GPT-6 Sol and GPT-6.1 Sol, so they never appeared as available.

### Removed

- **Retired ChatGPT models.** `openai-codex` no longer lists `gpt-5.5`,
  `gpt-5.4`, `gpt-5.4-mini` or `gpt-5.3-codex-spark`, matching omp and the live
  ChatGPT model list. Configs that pin them should switch, for example to
  `openai-codex:gpt-6.1-sol` or `openai-codex:gpt-6-luna`. Sim and eval
  defaults now use the GPT-6 models.

---

## [2026.10.1]

### Added

- **Current model catalogs.** Bundled catalogs gain the latest models from
  each provider shared with the oh-my-pi reference catalog, including
  ChatGPT/Codex GPT-6 Luna, GPT-6 Sol and GPT-6.1 Sol, Claude Sonnet/Haiku 5.5,
  and current Grok, Gemini (Antigravity), GLM, Kimi, MiniMax, DeepSeek,
  Mistral, Fireworks, Copilot, OpenCode and aggregator entries. Existing model
  ids are unchanged; earlier ChatGPT models stay selectable for existing
  configs.

### Fixed

- **Setup model picker.** `lemon setup` lists models newest first and
  defaults to each provider's current flagship instead of an alphabetical,
  oldest-first list. Model pickers no longer treat snapshot dates, parameter
  counts or vendor prefixes as version numbers.
- **Quiet setup.** `lemon setup` no longer prints runtime log lines, such as
  the config reloader noticing setup's own config write.

---

## [2026.10.0]

### Added

- **`mix lemon.new --hex`.** The generator can emit `~> 0.2` Hex requirements
  for `lemon_core`, `lemon_ai`, `lemon_agent` (and `lemon_memory` with
  `--memory`) instead of path dependencies, so a project needs no checkout of
  this repository. It resolves once 0.2.0 is on hex.pm. `--hex --channel` is
  refused with an explanation, since `lemon_channels` is not published. The
  `installer/` package (`lemon_new`) now carries Hex package metadata, a
  license and a changelog so it can be published; an installer built outside a
  checkout generates the `--hex` form by default. Path mode and
  `--packages-path` are unchanged.

- **Tern integration.** `lemon acp` is a runtime-attached ACP stdio agent and
  `lemon tern install` registers Lemon as a native Tern chat agent plus a
  managed plugin ("New session in split", "Focus existing session"). In a Tern
  pane, `lemon` opens the native chat (`lemon tui` keeps the terminal UI).
  ACP sessions are durable and forkable, stream rich tool cards, diffs, plans,
  thoughts, usage and subagent updates, run bash in native client terminals,
  bind client MCP servers to the session, support plan mode with reviewed
  revision approval, `ask` forms via `elicitation/create`, and exact-preview
  permissions. The TUI emits Tern-native surfaces (prompt/reply marks, Run
  controls, working/approval states, Carly delegation, `/fork` in a split) and
  file links that open at the exact line.
- **Non-interactive coding.** `lemon -p`/`lemon run` take stdin prompts, emit
  text/JSON/stream-JSON, continue sessions, select model/cwd, control tool
  approvals, report usage and budgets, and use automation-friendly exit codes.
- **Subagents.** Parallel fan-out with live progress, optional git-worktree
  isolation, named personas (`.lemon/agents/*.md`; built-in scout, reviewer,
  task-executor), configurable model roles, schema-validated results, scoped
  `agent_message` messaging, first-result waits, and dependency-aware
  `task(action="swarm")` DAGs.
- **Sessions.** Checkpoint-backed `/rewind` (preview-bound, with explicit
  consent for partial restore across shell effects), `/tree`, `/name`, search,
  independent forks, plan mode (`/plan`, `/approve-plan <revision>`),
  `/compact <focus>`, context-budget snapshots, and bounded per-repository
  project memory recalled as labelled background context.
- **Coding tools.** Snapshot-anchored edits, bounded directory/archive/PDF/
  notebook/image reads, optional ast-grep structural search/replace, native
  plans, `skill://` and session-scoped `artifact://` URLs with ranged recovery
  of complete shell output.
- **TUI.** Image drafts and `@` file mentions, fuzzy command/skill/prompt
  palette, live subagent tree, full tool/diff inspector, faster bytecode
  startup (first frame ~48 ms), and fixed shutdown/editor handoff hangs.
- **Providers.** Opt-in import of an existing Codex CLI login, per-account
  Codex model discovery, refreshed GPT/Claude/Gemini catalogs and pricing,
  Codex prompt-cache affinity, and per-run/per-session token and cost budgets.
- **MCP.** `lemon mcp add|list|remove|test`, session-owned connections,
  capability-aware discovery and per-tool approvals; omp/Claude-compatible
  skill layouts are discovered.
- **Automation.** Goals, cron and kanban dispatch repository-targeted coding
  runs with persisted results; opt-in reviewed kanban workflows (isolated
  worktree, independent read-only review, exact-tree commit, explicitly
  configured publication; never pushes by default); channel notifications and
  exact-preview Telegram/Discord approvals; `/manage/work` web dashboard with
  live sessions, tool output and subagent trees.
- **Operations.** `lemon update` with verified daemon restart and rollback,
  build identity in `--version` and doctor, image input on
  `chat.send`/`profile.chat`, and an opt-in 12-task live coding benchmark
  (`mix lemon.eval.coding`) with omp comparison and token profiling.
- **Secrets master-key rotation.** `lemon secrets rotate-key` previews how
  many stored secrets will be re-encrypted and prints a confirmation token;
  `--confirm <token>` generates a new master key, re-encrypts every secret, and
  replaces the key in the Keychain entry or key file. It refuses stale tokens,
  changes nothing if any secret does not decrypt, never touches external
  sources or environment fallback, refuses while a runtime is running, and
  keeps every secret readable if interrupted at any step. A key file is
  rotated only where the host can flush the rename synchronously (GNU
  coreutils); on macOS keep the master key in the Keychain. Secret writes and
  OAuth token refreshes report a held secrets lock instead of claiming success.

### Fixed

- TUI cancellation keeps its interrupted marker when a notice has already
  sealed the current text segment.

- `lemon doctor`'s `skills.directory` check inspects the global skills
  directory Lemon actually installs into (`~/.lemon/agent/skill`, or
  `LEMON_AGENT_DIR`), not the unused `~/.lemon/skills`. The check now lives in
  `lemon_skills` and the memory check in `lemon_memory`; both register with the
  doctor through `config :lemon_core, :doctor_checks`.

- Accepted runs always receive durable, ordered terminal receipts across
  admission, queue retirement, cancellation and crash recovery; cancelling
  drains in-flight events so tool output and partial prose persist with honest
  unknown/not-started outcomes; uncertain admissions keep their fixed run ID.
- WebSocket clients no longer disconnect on streamed tool results, encoding
  failures, or after 60 s of inbound idle time (server keepalive pings).
- Transient transport errors (closed/reset/timeout) retry inside the agent
  loop using structured error metadata; permanent failures and exhausted quotas
  do not.
- Coding tools reject ambiguous edits, bound reads, refuse binary content,
  keep long shell output retrievable, and kill shell process trees on forced
  cancellation.
- Source startup is faster, reuses healthy daemons, preserves the caller's
  directory and keeps CLI JSON stdout clean; setup selects usable defaults and
  doctor diagnoses unreadable credentials and port conflicts.
- Wire usage counts native cache read/write tokens; session restores preserve
  provider identity and costs; cold checkpoint reads no longer create atoms.

### Changed

- The agent `cron` tool moved from `lemon_gateway` to `lemon_automation`, which
  registers it with `LemonAgent.ToolRegistry` at boot; the gateway no longer
  references automation. The tool's name, schema and results are unchanged. As
  with every registered tool it is now subject to session tool policy and
  approval (so cron-run prompt sessions, which block `cron`, no longer see it).
- Source and packaged launchers now share command dispatch, help, completion,
  and lifecycle semantics. Running `lemon` in a terminal opens the TUI;
  `lemon start` starts the foreground runtime. Non-interactive
  no-argument calls return usage with exit code 2. `send`, `media`, `models`,
  `policy`, `skill`, `usage`, and `migrate hermes` also work without Mix in
  runtime releases.
- Native coding sessions no longer stop at an incidental default turn cap.
  Explicit limits remain available; retries, thinking state, and tool results
  survive the appropriate session transitions.
- Durable memory is recalled automatically into the next user message using
  agent-scoped full-text search and the selected workspace's `USER.md`.
  Recall is bounded to 2 KiB, stays out of the cached system prompt, and can
  be disabled with `[memory] auto_recall = false`. The model-facing memory
  tools are now `remember` and `recall`.
- Heartbeats use cron rather than a second session scheduler. Reminder and
  proactive jobs preserve their originating delivery target.
- Shared credential redaction now covers session, profile, memory, config,
  diagnostic, webhook, and Web surfaces while preserving their stricter
  content allowlists and output bounds.
- Standalone packaging is limited to `lemon_ai`, `lemon_core`, `lemon_agent`,
  `lemon_memory`, and `lemon_platform_test`. Version 0.2.0 tarballs are locally
  installable; these packages have not been published by this change.
- Consolidated contributor and architecture guides; removed duplicate
  walkthroughs and generate machine-readable documentation during site builds
  instead of committing copies.

- Refreshed the public website, README, and onboarding docs with a shared Lemon
  visual identity, clearer task navigation, and current feature guidance.

- `CodingAgent.Session` keeps automatic-compaction and overflow-recovery
  bookkeeping in subsystem-owned state structs. The persisted session format
  is unchanged.

### Removed

- The duplicate `clients/lemon-web` application, `coding_agent_ui`, and
  `lemon_tcg`; the supported clients are the Bun TUI and Phoenix LiveView Web.
- `execute_code`, `python_repl`, their persistent Python/RPC bridge, the MCP
  server surface, and obsolete agent factories. Native tools and the MCP
  client remain; browser actions use explicit browser-tab tools.
- Unused control-plane methods: the built-in registry is reduced from 188 to
  79 methods used by retained clients. Retired device, proof/readiness,
  heartbeat, and other unsupported APIs have no compatibility aliases.
- Long-tail simulation arenas, generated proof/readiness machinery, orphaned
  modules, and duplicate or implementation-only tests. LemonSim's product
  focus is Werewolf, Poker, and VendingBench.
- The `memory_topic`, `session_search`, and `search_memory` tool names. Use
  `remember` and `recall`; no deprecated aliases are retained.

- The built-in `x_api` satellite, its X/Twitter tools and channel adapter,
  OAuth helpers, credential registry entries, release wiring, and developer
  authentication script. Vendor-specific social integration now belongs in an
  external package that registers through Lemon's existing channel and tool
  extension points.

### Fixed

- Requests to the `opencode_go` provider (OpenAI-completions and Anthropic
  transports) now send the `x-opencode-session` header OpenCode Go requires
  since 2026-09, avoiding `400 MissingSessionID`. The id is
  `StreamOptions.session_id` (LemonSim sets one per game and player), with a
  stable per-system-prompt fallback. Other providers are unaffected.

- Finished LemonSim spectator games now display `COMPLETED`, rather than
  `STOPPED`, after their runner exits. Live Werewolf playback keeps its
  playback indicator until the final scene has been shown.

- Router callback defects now reach callers or OTP supervision instead of
  being acknowledged as success. Durable replay/admission and cancellation
  fences remain intact; rejected final deliveries remain retryable.
- Channel delivery no longer replays an external write after an adapter crash
  or lost acknowledgement. A failed Telegram update does not stop the rest of
  its fetched batch; WhatsApp acknowledgement timeouts report unknown outcome.
- File edits handle normalized whitespace and Unicode without damaging
  original UTF-8, BOM, line endings, or surrounding content. Read freshness
  and mutation locks prevent stale or concurrent overwrites.
- Provider handling preserves Retry-After delays, image tool results, and
  usage/cost accounting. Telegram access checks remain fail-closed, including
  pairing, group policy, and attachment-size refusal.
- LemonSim replay verification checks artifact integrity and replays recorded
  batches; seeded randomness makes retained offline arenas reproducible.
- Removed unreachable and unused Elixir paths rather than suppressing
  compiler diagnostics.
- Hermes migration now treats omitted confirmation/overwrite flags as false:
  declining confirmation writes nothing, and conflicts fail closed rather
  than raising.
- Source and packaged `--json` commands keep application-startup logs out of
  machine-readable stdout. The duplicate-test checker resolves nested module
  names, avoiding false collisions between independently scoped helpers.
- Updated locked Bandit, Mint, LiveView, LazyHTML, Gun, and Cowlib releases
  after Hex reported upstream security advisories; refreshed the vendored
  LiveView browser client to match. Cowlib's
  [structured-header](https://cna.erlef.org/cves/CVE-2026-43966.html) and
  [cookie-encoder](https://cna.erlef.org/cves/CVE-2026-43969.html) advisories
  still have no fixed Hex release and remain tracked upstream.

- Bash streaming previews retain the most recent 50,000 output bytes plus an
  omission marker, preserving UTF-8 boundaries without retaining discarded
  source binaries. Final results and full-output files are unchanged.

- Restricted tool profiles deny alternate hashline editing, memory writes,
  and task delegation through `hashline_edit`, `remember`, and `task`.
  Full-access and orchestrator profiles are unchanged.

- Tool approval failures now block execution on exceptions, exits, throws,
  malformed replies, and unsupported approval scopes without exposing raw
  service error payloads. Approval timeout results also render safely when
  the configured wait is infinite.
- Session reset and termination now cancel both automatic-compaction and
  overflow-recovery workers, clear their monitors and timeout refs, and ignore
  late task messages from the previous session identity.
- The LemonSim UI test-only `lazy_html` dependency now uses a bounded
  compatible-version requirement instead of accepting every future release.
- A2A message replays now return the original task without duplicate router
  submission, webhook idempotency storage failures fail closed with retryable
  503 responses instead of reporting acceptance, and exact synchronous webhook
  responses have an independent durable replay receipt. Ambiguous goal-loop
  submissions retain their fixed run ownership until reconciliation or an
  explicit hard stop.
- Fixed run IDs now have durable semantic admission claims and compact permanent
  accepted/aborted outcome fences; only safe never-enqueued claims and volatile
  caches expire. Replays cannot cross session, content, or execution identity,
  transport-local attachment paths do not create false conflicts, and surviving
  run ownership is indexed without probing unrelated run processes. Exact
  webhook response receipts are swept together with their completed primary
  reservation after the replay horizon using transactional or fence-last
  exact-snapshot deletion, and raw webhook idempotency keys are hashed before
  any durable key, receipt, router request, or run metadata is built. Legacy
  raw webhook receipts migrate behind the hashed fence without reopening
  execution, invalid payload idempotency values are rejected before hashing,
  released pending receipts without run identity return a permanent,
  non-retryable duplicate ambiguity receipt, and
  failed cleanup scans do not advance their watermark. Store diagnostics also
  sanitize nested idempotency-key context, and sensitive multi-delete failures
  return bounded error categories instead of backend payloads. Legacy router
  receipts are compacted and abort reasons sanitized during replay and
  background cleanup; goal hard stops persist abort intent before dispatch.
- Telegram memory-reflection and per-chat abort helpers no longer collapse
  router mutation failures into success-like results. Ambiguous cancel and
  keepalive callbacks now direct users to check run status before retrying,
  retain their inline controls, and log only bounded failure classes.
- Gateway webhooks now acknowledge ambiguous router submissions with an
  explicit non-retry-safe receipt instead of a redelivery-triggering 5xx,
  profile chat preserves a reconciliation run ID without retrying or exposing
  raw failures, and goal-loop hard stops report sanitized one-shot abort
  outcomes.
- Email webhooks now reserve a hashed provider Message-ID and stable run
  reference before router submission. Definite rejection remains safely
  retryable, while an ambiguous handoff returns a truthful non-retrying receipt
  and retains dedupe state so provider redelivery cannot create a second run.
  Telegram and WhatsApp busy-query fallbacks no longer log raw session keys or
  exception terms.
- MCP configuration validation now rejects non-boolean OAuth token-persistence
  flags and empty token secret names consistently before HTTP or SSE sources
  reach runtime startup.
- `LemonCore.RouterBridge` query calls now distinguish an idle router from an
  unavailable one: `session_busy?/1`, `active_run/1`, and
  `list_active_sessions/0` return explicit result tuples/errors, and command
  callbacks accept only `:ok` or `{:error, reason}`. All channel, web, A2A,
  control-plane, and portable-command callers were migrated atomically;
  user-facing run controls no longer report success for a request the router
  did not accept.
- Run finalization no longer reports success when session indexing fails.
  Retrying the same immutable summary repairs the derived index without
  incrementing `run_count` twice; conflicting summaries fail closed, and
  finalize hooks document their at-least-once delivery contract.
- Hermes skill install/update requests no longer block their own control-plane
  WebSocket while waiting for approval or Git work. Approval events and
  liveness probes remain deliverable, and the TUI keeps the correlated skill
  mutation request open long enough for human approval and installation.
- Hermes imports now report security-audit refusals directly, and escaped
  Markdown examples such as `curl ... \\| bash` no longer trigger the
  executable-pipeline rule. Real unescaped remote-script pipelines remain hard
  blocks, but operators can accept an exact audited bundle through a separate,
  conspicuous security-override approval that cannot be satisfied by ordinary
  install approval or reused after content changes.
- Telegram, Discord, and WhatsApp tool-status bubbles now omit fixed internal
  engine provenance and reasoning-only actions, so step counts reflect
  user-relevant tools. Automatic filesystem checkpoint lifecycle events remain
  auditable internally and available through explicit `/checkpoint` and
  `/rollback` commands without being pushed into ordinary channel chats.
- Source `./bin/lemon start` detects and reuses a healthy local control plane
  before compilation or Erlang distribution startup, avoiding duplicate
  `lemon@host` registration.
  Web health probes tolerate bounded slow responses and trailing whitespace,
  and the quality lane exercises both direct-launch and `web --no-open` reuse.

### Added

- Background shell execution with session-owned `bash_output` and
  `kill_process` tools, explicit millisecond timeouts, and preserved partial
  output on timeout or cancellation.
- Structured TUI tool cards with real-line-number edit diffs, bounded command
  output, and reasoning display; LiveView chat improvements for streaming,
  Markdown, and tool approvals.
- A keyless `mix lemon.sim.demo` Werewolf spectator demo and offline
  Werewolf/Poker run bundles for local replay verification.

- `mix lemon.eval --output <path> --revision <full-sha>` writes versioned,
  redacted contract reports with check outcomes and explicit revision metadata,
  including when completed checks fail. The manually dispatched Live Eval
  workflow retains these reports for 14 days without uploading raw details.
- `LemonCore.Store.Table` ownership metadata for incremental generic-store
  migrations. The architecture gate now analyzes generic Store calls from the
  AST across every supported operation and default/explicit server arity,
  resolving aliases, module attributes, direct and `apply/3` forms, and every
  table in multi-entry operations while rejecting dynamic or cross-table access
  from an owner module. The metadata is non-operational in this change; backend
  registration, retention, and domain migrations remain separate.
- `LemonCore.PolicyStore` now declares the four existing policy tables it owns.
  This is metadata-only; policy access still uses the specialized Store API and
  its public functions are unchanged.

- `LemonCore.ChatStateStore` now adopts that ownership contract for the cached
  `:chat` table and its existing `:expires_at` retention policy without moving
  TTL, expiry, sweep, or cache behavior out of the specialized Store runtime.
- `LemonCore.RunStore` now declares ownership of the `:runs` and
  `:sessions_index` tables through `LemonCore.Store.Table`, with cache and
  persistence policy recorded explicitly. The existing run lifecycle and
  finalization behavior is unchanged.

- Configured engine runtimes are now checked against
  `LemonCore.EngineRuntime` when the router starts. Invalid wiring is reported
  once and disabled while preserving router-only boot and the existing
  unavailable-runtime handling.
- Persistent source and packaged launchers now provision a private,
  port-scoped control-plane operator credential under `~/.lemon/run`, allowing
  later TUI processes to attach automatically without exposing the bearer in
  argv or enabling tokenless loopback access. Explicit operator tokens remain
  caller-managed and are never persisted by this handoff.

- Bidirectional A2A v1.0 peer interoperability for durable Lemon-Hermes
  conversations: Agent Card discovery, authenticated JSON-RPC and SSE,
  persistent context/session mapping, peer-scoped task lifecycle and
  cancellation, untrusted-content boundaries, and a built-in `peer` tool that
  resumes one long-running default conversation per configured agent.

- Bun TUI portable-blueprint management over the authenticated shared catalog:
  content-free `/blueprints` browsing and `/blueprint` inspect/validate/preview,
  exact fresh-digest activation, stale/refused-plan clearing with preserved
  profile drafts, nonqueueable offline mutation, and duplicate-safe replay.
  The terminal retains and renders only bounded IDs, counts, actions, booleans,
  and digests; real Bandit/Bun proof verifies planted manifest prose, prompts,
  skill bodies, commands, environment values, paths, tokens, and secrets stay
  out of terminal state and proof output.
- Token-required Web durable-memory management at `/manage/memory`, backed by
  a shared `LemonMemory.Lifecycle` over the canonical SQLite/FTS store. The
  responsive browser supports bounded search and safe scope/agent/workspace
  digest/kind filters, Safety-redacted run and learned-source previews,
  digest-only provenance, and exact single-record delete preview/confirmation.
  Deletion binds the document ID to a deterministic revision of every
  persisted field, compares it in constant time inside the same transaction
  that removes the document and FTS row, and fails stale/forged/malformed
  requests without mutation. Memory updates now replace their prior FTS row,
  preventing duplicate search hits for an updated document ID.

- Source and packaged `lemon learn` plus authenticated `learn.review` /
  `learn.confirm` control-plane methods for auditable learning from existing
  bounded file, folder, URL, diff, document, and redacted-session references.
  Review is non-mutating and content-free; confirmation is bound to an exact
  fresh digest and writes only canonical durable memory plus an audited skill
  draft, with traversal/SSRF defenses, redaction, collision checks, and
  idempotent re-review. Exact create-if-absent writes prevent stale destination
  overwrites, provenance-bearing records remain removable through their
  existing stores, and selected source content never enters LLM audit.

- Registry-driven source/packaged `lemon update check|plan|apply|history|rollback`
  with non-mutating manifest/current-bound plans, exact fresh-digest apply,
  serialized checksum/size-authenticated staging, pre-extraction archive
  confinement, verified private checkpoints, atomic pointer recovery,
  content-free receipts, and exact receipt/digest rollback. Source checkouts
  keep binary mutation fail-closed; schema-2 publisher-signing and exact
  in-flight `:httpc` byte cancellation remain explicitly documented residuals.
- Explicitly enabled, read-only 1Password, Bitwarden Secrets Manager, and
  argv-only command secret sources integrated behind the encrypted Lemon store,
  with exact schema validation, supervised time/output bounds, minimal child
  environments, fail-closed fallback behavior, optional bounded in-memory
  caching, and source/packaged `lemon secrets sources status|test` diagnostics
  that expose readiness/provenance only.
- Source and packaged `lemon blueprints` catalog list, sanitized inspect and
  validate, non-mutating default preview, and exact-digest activation over the
  existing authenticated control-plane/`CronManager` path, with stable redacted
  JSON/exit codes, registry-driven help/completion, duplicate-safe results, and
  real source plus assembled minimal-runtime proof.
- Token-required Web blueprint management at `/manage/blueprints`, backed by
  the shared `LemonAutomation.Blueprint.Catalog` service. The responsive page
  lists only safe IDs/counts, validates bundles, previews profile-local skill
  and schedule actions without mutation, requires the exact fresh digest, and
  reports create-once or unchanged replay without retaining manifest prose,
  prompts, skill bodies, paths, commands, environment values, or secrets.
- Authenticated Web provider-routing management at `/manage/providers`, with
  redacted effective status, ordered fallback controls, credential-pool and
  credential-reference lifecycle, preview-first writes, exact confirmation for
  destructive changes, and stale-preview rejection through opaque config
  revisions. Credential references are password-masked, filtered from logs,
  re-entered for apply, and never retained or rendered by the LiveView.
- Source and packaged `lemon sessions` commands for bounded list/search/show,
  exact redacted aggregate statistics with capped agent/origin breakdowns,
  and redacted history, title/pin/archive lifecycle, always-redacted
  JSON/Markdown export, exact-candidate preview-confirm prune, and verified
  exact-key delete; plus registry-generated `lemon completion bash|zsh|fish`
  scripts that preserve source and release launcher-specific commands.
- Bun TUI session lifecycle parity over the same authenticated control-plane
  service: live `/sessions` search/filter/picker UX; `/session` inspect, resume,
  title, pin, archive, redacted preview/export, exact-candidate guarded prune,
  and verified export-before-delete. Destructive mutations are never queued
  offline, refused/stale results do not discard drafts, and list/status/error
  rendering omits paths, prompts, credentials, and unredacted content.
- Source and packaged `lemon providers` readiness and routing management with
  comment-preserving fallback and credential-pool reference edits, stable
  redacted JSON/exit codes, exact confirmation for destructive changes, and a
  matching admin-scoped `providers.configure` control-plane method.
- A client-independent `LemonCore.Context` preview/resolve contract and
  packaged `lemon context` command for bounded `@file`, `@folder`, `@git-diff`,
  `@url`, and redacted `@session` references. PDF, DOCX, XLSX, PPTX, notebook,
  and text content is format-sniffed with explicit byte/page/item/depth/time
  limits, archive-bomb/traversal and symlink defenses, SSRF-safe pinned URL
  fetching, sensitive-value redaction, and structured omission metadata.
- Versioned portable skill + automation bundles with bounded manifest and
  filesystem policy, deterministic source-and-stage audit, profile-local skill
  enablement, content-free control-plane list/inspect/validate/preview, exact
  digest confirmation, and create-once idempotent cron activation.
- An authenticated Lemon Web session-management shell with runtime and live-node
  status, durable search/resume, title/pin/archive controls, redacted structured
  run/tool inspection, bounded JSON/Markdown export, and exact-candidate guarded
  prune. Query-token bootstrap redirects server-side to a clean URL before
  rendering, and named chat routes reconstruct durable history before resuming.
- A shared `LemonCore.SessionLifecycle` service and control-plane
  `sessions.metadata.patch`, `sessions.export`, and `sessions.prune` methods.
  Export fails closed against raw run/event payloads and secrets; prune commits
  canonical history last, verifies deletion, and binds confirmation to exact
  parameters and stable candidate state.
- Source and packaged `lemon backup contract|create|list|verify|restore`
  commands backed by a versioned `~/.lemon` data contract, atomic private
  directory bundles, exact file-set and SHA-256 verification, credential
  exclusions, permission-widening rejection, target-bound overwrite
  confirmation, staged restore, rollback receipts, stable JSON, and documented
  exit codes.
- First-class user-managed profiles over the existing router agent plane, with
  atomic/comment-preserving create, list, show, clone, rename, credential-safe
  export, and guarded recoverable delete; isolated profile workspaces for
  bootstrap/memory/skills; stable `agent:<id>:main` chats; node-aware rosters;
  packaged `lemon profile` commands; matching control-plane methods; and TUI
  `/profiles` roster/picker plus `/profile` inspection, canonical-chat, and
  guarded lifecycle commands. Normal TUI prompts in an opened profile route
  through `profile.chat`, preserving derived workspaces and named nodes. The
  authenticated Web shell now adds a responsive `/manage/profiles` roster and
  preview-first create/clone/rename/recoverable-delete journey with stale
  revision refusal, exact delete confirmation, canonical-chat links, and no
  profile paths or system prompts retained in LiveView state.
- `lemon web [--no-open]` in source and full packaged launchers, with daemon
  auto-start, exact Web health polling, browser opening, and actionable profile
  or startup errors.
- A shared `LemonCore.Setup.Readiness` contract plus a fail-closed Web first-run
  guide, live config/secret refresh, active-run stop control, and accessible
  responsive status/composer states.
- Cron-backed TUI `/heartbeat`/`/hb` commands and channel `/remind` scheduling
  reuse the automation scheduler rather than retaining session heartbeat
  state or a `sessions.heartbeat` API.
- Portable Hermes-compatible slash-command discovery metadata for channel and
  interactive clients, exposed through the read-only `commands.catalog`
  control-plane method while preserving Lemon's router/session ownership and
  active-run-only `/stop` semantics.
- End-to-end Hermes-compatible `/queue`/`/q`, `/steer`, `/reset`, `/reasoning`,
  `/stop`, `/status`, `/usage`, `/agents`/`/tasks`, `/compress`, `/commands`,
  `/help`, `/bg`, and `/btw` support across Telegram, Discord, the TUI, and the
  control plane. Background runs are isolated full-tool sessions; side
  questions use bounded no-tools transcript snapshots without changing parent
  history.
- Channel `/bg` receipts now retain the complete durable job id and Telegram and
  Discord expose `/bg list`, `/bg status <id>`, `/bg result <id>`, and `/bg
  cancel <id>`. Discord portable slash commands also enforce configured
  guild/channel and binding policy before execution, and channel command errors
  no longer render arbitrary internal runtime reasons. Background lifecycle
  access is scoped to its originating channel session so foreign ids are hidden
  as not found, and Discord now applies the same policy gate to every application
  command before reset/reasoning/cancel or other command dispatch.
- Hermes-compatible `/bg` backend sessions with durable lifecycle ids,
  isolated full-tool execution, status/result/list/cancel APIs, and
  restart-safe lost-run reporting; plus bounded `/btw` no-tools queries over
  immutable live snapshots or durable channel session-key history without
  mutating the parent conversation.
- Extensible capability-aware web search/extraction providers with deterministic
  fallback, provider isolation, request-level selection, extension registration,
  keyless DuckDuckGo, configurable SearXNG, Exa search/highlights and batch
  contents extraction, and concurrent
  single-flight request coalescing
- Backend-neutral multi-tab browser control with stable target IDs, safe
  attached-browser lifecycle semantics, authenticated single-use controller
  tickets, and a bundled token-gated Manifest V3 relay for existing signed-in
  Chrome tabs
- Hosted browser lifecycle adapters for Browserbase, Browser Use Cloud,
  Firecrawl, and Camofox; explicit public/local hybrid routing; bounded
  `browser_exec` programs with developer-gated raw CDP; and cross-platform
  `computer_use` backed by exact-session cua-driver state
- Redaction-safe live leadership acceptance harnesses covering real
  `gpt-5.6-luna`/`xhigh` search fallback, multi-source synthesis, multi-tab and
  stale-target browser control, screenshot analysis, extension relay ownership,
  and fail-closed controller consent boundaries
- Named execution nodes can now pair with a Lemon controller through
  `./bin/lemon node join`, advertise live presence under a unique name, and
  run native delegated `CodingAgent.Session` work selected by the `agent`
  tool's `node` parameter. Pairing persists a private, controller-bound token
  on the destination machine; remote runs keep credentials and default working
  directories destination-local and support targeted cancellation plus
  invocation-bound steer/redirect with authenticated destination
  acknowledgement and fail-closed terminal races.
- The control-plane chat surfaces and TUI now preserve redirect as a distinct
  active-run mode. The TUI exposes `/redirect` and cycles queue, steer,
  redirect, and interrupt without conflating redirect with non-canceling steer.
- Lemon Web now discovers an already-active session run and presents explicit,
  responsive follow-up, steer, and redirect choices. The text-only controls
  recheck run eligibility at submit time, keep stop bound to the real active
  run, preserve a refused draft, and report bounded user-facing outcomes
  without rendering internal node/runtime errors.

### Changed

- Lemon AI's 25 provider-module literal catalogs now live in 26 JSON resources
  under `apps/lemon_ai/priv/models/` and are embedded at compile time by
  `LemonAi.Models.Catalog`. Google uses a base catalog plus Antigravity extras;
  the Google Antigravity registry derives from both, while OpenAI Codex derives
  from the direct OpenAI catalog plus OAuth-only IDs. Provider modules retain
  their existing names and `models/0` APIs, catalog files are registered as
  external resources for recompilation, malformed entries fail compilation
  with their model key, and atom-valued API/provider/input/compatibility fields
  accept only explicit allowlists.
- Packaged and Mix `secrets check` output now reports only `present` and source
  category counts; it no longer reveals credential prefixes or suffixes.
- Lemon Web now ships compiled CSS inside the release instead of loading
  Tailwind from a runtime CDN, so the local chat shell works offline.
- Vendored Phoenix and LiveView browser clients now match the locked server
  dependencies, removing the live asset-version mismatch warning.
- Lemon Web declares and serves a bundled favicon instead of logging a missing
  route on each new browser session.
- Background and side-query public APIs now use stable content-free failure
  classifications; their control-plane RPCs allowlist lifecycle fields and
  return fixed bounded error codes/messages without provider terms, persisted
  errors, filesystem paths, or credential details.
- Background and durable side-query launches now normalize string-valued
  reasoning policy to the native atom contract before provider execution.
- Packaged and Mix secrets check/import commands now share one ordered
  environment-credential catalog instead of maintaining three copies
- LemonSim scenarios now share one bounded model/provider/credential resolver;
  unknown provider input no longer creates BEAM atoms, while scenario-specific
  setup errors and provider aliases remain intact
- LemonSim Mix tasks now share ordinary runtime, option, and bounded
  provider/model helpers instead of maintaining two dozen private copies;
  arbitrary provider CLI input no longer creates atoms
- Fifteen LemonSim scenario logs now share one JSONL lifecycle and encoding
  implementation while retaining their existing public APIs and domain fields
- XMTP and WhatsApp now share one supervised Node bridge port lifecycle while
  retaining their adapter-specific `PortServer` callback/process identities,
  scripts, event tags, and module-scoped warning logs
- Documentation quality checks now use a compact catalog with shared defaults,
  explicit lifecycle/visibility metadata, and Git-index-based coverage that
  ignores untracked local drafts
- Pull-request client quality now exercises Lemon Web startup from clean
  generated artifacts, and release smoke evaluates the MCP library contract
  inside both packaged runtime profiles and their release tarballs
- Local coding-agent patches now preflight every hunk before mutation, reject
  duplicate paths and destructive move overwrites, revalidate each operation,
  exclusively create new targets, and report any committed prefix or partial
  current operation when a later mutation fails. Local writes canonicalize the
  path used for both validation and mutation, then reject symlink redirection
  and special-file targets by default.
- Skill manifests now reject unsafe or oversized prompt metadata, relevance
  searches use cached excerpts/status views outside the Registry server, and
  prompt listings expose bounded source/trust provenance with deterministic
  ordering.
- Turn-specific skill relevance no longer changes the cacheable system prompt;
  missed-skill introspection uses turn-local keys, and local file/search/shell
  plus community skill results are fenced as untrusted data before model calls.
- Skill discovery now invalidates content-addressed caches after file, directory,
  lockfile, environment, or disabled-config changes; malformed typed metadata is
  rejected without crashing. Pre-LLM tool fencing ignores spoofed trust metadata,
  bounds hostile text, avoids double-fencing web output, and attests builtin skill
  content against the bundled release copy before granting instruction trust.
- Product releases can now be cut and published from one manual Release
  workflow dispatch; the workflow derives CalVer, consumes the Unreleased
  notes, commits and tags the release, verifies every artifact, publishes the
  GitHub Release, and only then promotes mutable container channel tags
- Lemon Web shared/server `dist` directories are generated by their build
  commands instead of being tracked as source.

### Fixed

- Redirect acknowledgement now waits until the correction is queued and the
  active model request is signaled, preventing a fast completion from silently
  racing ahead of an accepted redirect.
- Persistent Python kernels now preserve parent/child stdout and stderr ordering
  instead of allowing block-buffered parent output to appear after child-process
  output.
- MCP HTTP transports now supervise the protocol server and Bandit listener as
  one lifecycle and track live node-local instances through supervised members,
  preventing stale or orphaned processes across child failures, concurrent
  starts, and transport shutdowns
- Lemon Web now builds its ignored shared/server entrypoints before clean-checkout
  `npm run dev` and `npm start`; the client quality lane exercises that
  clean-artifact startup contract
- Authenticated TUI control-plane handshakes now send the token in the server's
  `params.auth.token` envelope
- Packaged minimal and full runtimes now assemble the MCP client library, so
  configured MCP tools are discoverable without starting a no-op application
  supervisor
- Named execution nodes now recover the same durable identity after their
  seven-day session expires, survive controller-side renames, revoke older
  sessions on rotation, and provide an explicit repair path for legacy local
  credentials. Non-loopback plaintext controller connections now fail closed
  unless development or a verified encrypted overlay is explicitly selected.
- Named-node challenge exchange and per-identity credential replacement are now
  atomic. Rotation closes stale live sockets, binds result settlement to the
  authorized connection generation, retains a monotonic generation floor
  against delayed handshakes, and withholds ID-based recovery material unless
  the exact stored controller is supplied.
- Closed unauthenticated named-node operator access on the control-plane
  WebSocket: non-loopback operators now fail closed, configured operator tokens
  use constant-time validation, unknown session identities cannot escalate, and
  node pairing reports credential problems without exposing secrets. Tokenless
  loopback operator access is now a default-off explicit compatibility opt-in,
  and browser clients keep operator credentials out of WebSocket URLs.
- The source TUI launcher now gives a fresh launcher-owned daemon and client the
  same high-entropy process-scoped operator token, keeps it out of arguments and
  disk, stops every daemon it starts with the TUI regardless of whether the
  token was generated or preconfigured, and fails closed when attaching to an
  existing runtime without its configured token.
- Named execution nodes now cancel destination work when callers time out,
  disappear, reconnect, or lose their controller socket; bind stored tokens to
  the paired node identity; persist fast results without racing dispatch; and
  resolve relative/default working directories from the joining shell. Node
  sockets now send idle keepalives, pairing resumes safely after approval or a
  lost challenge response, bounded JSON request/result limits prevent
  unbounded worker output, and durable status/events retain only redacted
  result summaries while private source delivery remains intact.
- Router and gateway launch lifecycle now bounds pre-start runtime submission
  and run-launch retries, emits one structured terminal failure before queue
  cleanup, deduplicates tokenized scheduler requests, preserves engine-lock
  exclusivity for live owners, and observes over-age live locks without stealing
  them. Gateway cwd fallback also accepts mixed-key proplists without crashing.
- Async task lifecycle, event retention, and join-followup suppression are now
  serialized and terminal state is first-writer-wins. Run-budget usage and
  child admission are atomic, repeated child completion aggregates once, and
  RunGraph finishes DETS recovery before accepting live calls.
- Corrected context truncation ordering, hard bookends character limits, and
  atomic tool-call/result retention; made pending-compaction retries survive
  submit errors with injection-safe whole-entry history envelopes; and cleared
  stale session follow-up diagnostics/background compaction when turns end or a
  new prompt supersedes the snapshot.
- Automation submit-and-wait paths subscribe before submission through one
  fixed-run-id lifecycle, closing synchronous-completion races in cron,
  goal, heartbeat, and Kanban runs.
- Cron retries now persist due time and lineage across manager restarts, claim
  deterministic attempt IDs, and share one terminal policy path for normal,
  stale, aborted, start-failed, and crashed-worker outcomes. Cron work is
  monitored under the automation task supervisor, with unsupervised execution
  reserved for explicit standalone mode.
- Kanban board stop now hard-cancels owned workers and reclaims their exact
  leases immediately; lease-guarded completion rejects late results, and board
  restart reconciles unexpired leases from the prior dispatcher. Board-scoped
  mutation locks also prevent concurrent dispatchers from leasing the same task
  or racing a stale terminal write against a replacement lease. Goal-loop hard
  stop now claims the fixed run ID before submission, aborts that authoritative
  router run once, and prevents another tick. Router abort tombstones close the
  accepted-before-callback window without delaying stop; graceful stop still
  lets the bounded loop finish and API deadlines enclose configured
  judge/continuation waits.
- Async subagent launches now fail and terminalize their bookkeeping when the
  supervised worker cannot start, completed task/agent followup delivery
  contains router exits, and lane-scheduled jobs no longer process a duplicate
  normal monitor event after every result. Delegated agent runs now participate
  in the run graph used by `agent action=join`, and explicit joins suppress the
  redundant automatic completion followup.
- Child `ask_parent` requests now wake idle parent sessions and release parents
  blocked in task/agent joins so clarification cannot deadlock. Parent-question
  creation and terminal transitions are serialized, resolver authorization is
  exact to both session and agent, and terminal lifecycle events emit once.
- Multi-task `wait_any` joins now suppress automatic followup only for the
  completed winner; failed, aborted, crashed, and restarted joins release
  transient suppression.
  Lane queues discard abandoned callers and contain per-job admission failure,
  while delegated watcher timeouts preserve still-running router authority and
  reconcile late completion from a `tracking_lost` state.

### Removed

- Breaking: top-level engine selection and custom Gateway engine extensions
  were removed. Every conversation now uses the native `CodingAgent.Executor`;
  `LemonGateway.Engine`, `EngineRegistry`, Echo, vendor gateway adapters,
  `LemonCore.EngineCatalog`, and `LemonPlatformTest.EngineCase` no longer
  exist.
- The `engine_id`, `default_engine`, `preferred_engine`, and
  `[gateway.engines.*]` configuration/API selectors are rejected with migration
  guidance. Delegated `task` runs use the native in-process `internal` engine
  only; vendor CLI task runners and `[runtime.cli.*]` configuration were removed.

---

## [2026.08.1]

### Added

- First-run onboarding in packaged `lemon_runtime_min` and
  `lemon_runtime_full` releases, including interactive provider/model setup,
  setup-readiness gating before TUI startup, and installer handoff to the
  setup wizard
- Packaged runtime CLI parity for setup, model, gateway, configuration,
  secrets, channels, and diagnostics commands
- Telegram and Discord gateway setup flows with encrypted credential storage
  and verification
- New Bun/`pi-tui` terminal client with streaming transcripts, tool cards,
  approvals, queue/steer/interrupt controls, multiple sessions, themes, mouse
  support, resolved-model display, and per-run usage
- Persistent supervised Python kernels for `execute_code`, with authenticated
  RPC, bounded requests and execution, cancellation, lifecycle cleanup, and
  redacted telemetry

### Changed

- Installation and onboarding documentation now describes the packaged
  first-run flow and distinguishes installed-runtime commands from source
  wrappers
- Release verification now proves packaged onboarding, source setup
  dispatch, readiness isolation, credential scrubbing, and release artifact
  summaries

### Fixed

- Closed an argument-injection path in packaged doctor dispatch
- Hardened persistent Python kernel ownership, teardown, timeout, spill
  cleanup, and late-frame handling
- Preserved installer `--modify-path` behavior while adding setup handoff
- Corrected provider routing circuit-breaker iteration and hermetic channel
  credential handling
- Made stream-result subscription synchronous so user cancellation cannot be
  miscounted as a provider circuit-breaker failure
- Made the live coding-repair release eval specify the patch tool contract
  explicitly, preventing model-dependent shell-edit detours
- Cleaned cached release assembly directories before packaging so artifacts
  cannot retain stale application or dependency versions
- Corrected secret error type specifications and unreachable CLI config
  branches so the allowlisted `lemon_cli` Dialyzer gate remains clean

---

## [2026.08.0]

### Added

**Distribution — prebuilt install story**
- Prebuilt release tarballs for `linux-x86_64`, `linux-arm64`, and
  `darwin-arm64` (`lemon_runtime_min`/`lemon_runtime_full` everywhere,
  `sim_broadcast_platform` on Linux), each boot-verified on its native
  runner before publication, described by a schema-2 `manifest.json`
- One-line installer (`install.sh`): checksum-verified install into
  `~/.lemon/versions/<version>` with an atomic `current` symlink, plus an
  offline CI verification harness (`scripts/verify_install_script`)
- `bin/lemon` launcher shim shipped inside every release
  (start/daemon/stop/status/version/update/doctor and friends)
- Stage-2 self-update: `lemon update` checks the published manifest,
  stream-downloads with mandatory sha256, stages, flips atomically, and
  supports `--rollback`; the control-plane `update.run` method now rides
  the same code path
- Multi-arch container image `ghcr.io/z80dev/lemon` (amd64 + arm64),
  smoke-tested in CI before tagging; a failed image blocks the release

**Platform (since 2026.05.0)**
- Platform split: 12 packages published to Hex, one native top-level executor,
  delegated CLI runners, and standalone `lemon_browser`/`lemon_skills`
  packages
- Always-on model arenas (werewolf, space station, stock market, survivor,
  poker) with leagues, ratings, and spectator UI
- Provider resilience: failover classifier, unified routing fallback,
  multi-key credential pools with health/cooldown
- Redirect-style interruption end to end, including Telegram/Discord
  `/redirect`
- Learning loop on by default: session search (scoped), routing feedback,
  scheduled skill synthesis
- Tool-search tiered disclosure, programmatic tool calling
  (`execute_code`), cron monitor mode/chaining/drift guard/preflight
- Channel delivery observability, hermetic Telegram test API, and the
  three-tier product verification stack

### Changed
- `lemon_runtime_full` releases now ship digested static assets for both
  web endpoints (previously booted with a static-manifest warning)
- Release artifact naming switched to runner-agnostic platform tags

### Fixed
- Control-plane `update.run` no longer buffers downloads in memory or
  skips checksum verification on unrecognized prefixes
- Sim UI Dockerfile references the post-rename app paths and the shared
  `hex_package.exs`

---

## [2026.05.0]

### Added

**M8 — Documentation and release**
- Condensed root README to 5-minute orientation
- New user-guide docs: `setup`, `skills`, `memory`, `adaptive`
- Architecture overview doc (`docs/architecture/overview.md`)
- CONTRIBUTING.md, SECURITY.md, LICENSE, CHANGELOG.md
- GitHub issue/PR templates
- `product-smoke.yml` CI: packaged runtime boot, control-plane HTTP/WebSocket health, full-profile web health, release support-bundle generation, skill lint, adaptive eval gates
- `release.yml` CI: CalVer tag validation, multi-profile artifact build, manifest.json, GitHub Release publication
- `scripts/bump_version.sh`: coordinated CalVer version bump across mix.exs and client package.json files
- VitePress docs site (`docs/.vitepress/config.js`, `docs/package.json`): optional generated site from repo markdown
- `docs-site.yml` CI: docs build, markdown link checking, and GitHub Pages deployment on push to main
- Lemon 1.0 mainstream readiness ledger, launch website scaffold, install/demo/support pages, comparison page, interface proof pack, fresh-install proof, and release-artifact proof docs
- Linux `x86_64` release support policy for `lemon_runtime_min` and `lemon_runtime_full`, including rollback and downloaded-artifact verification steps
- `scripts/verify_release_artifacts`: verifies release `manifest.json` file names, sizes, and SHA-256 checksums against downloaded or assembled artifacts
- Source and clean Docker install proof on Elixir 1.19.5 / Erlang/OTP 28 with `mix deps.get`, `mix compile`, and redacted doctor bundle generation
- Web operations UI proof for `/ops`, run detail pages, support-bundle download, runtime health, sessions, approvals, cron, skills, channels, memory/log activity, and core config controls
- Telegram source-runtime proof for `/cwd`, progress rendering, prompt round trip, bare `/cancel`, approval-button resolution, and concise invalid-model failures
- TUI source-runtime proof for deterministic echo, rendered tool failure, and real-run cancellation
- Launch-focused safety coverage for web fetch output, inbound email prompts, skill prompt rendering, and extension-style untrusted tool results

**M7 — Adaptive routing and skill synthesis**
- Skill synthesis draft pipeline: candidate selector, draft generator, draft store, orchestration pipeline
- `mix lemon.skill draft` subcommands: `generate`, `list`, `review`, `publish`, `delete`
- Task fingerprinting for routing and synthesis (`LemonCore.TaskFingerprint`)
- Routing feedback store (`LemonCore.RoutingFeedbackStore`)
- Explicit run outcome model (`RunOutcome`: `:success`, `:partial`, `:failure`, `:aborted`)
- Offline evaluation and feedback reporting (`mix lemon.feedback`)

**M6 — Memory and feedback**
- Durable memory store and ingest pipeline (`LemonCore.MemoryStore`)
- Session search API and `search_memory` tool
- Memory management tasks and retention controls
- Memory performance and correctness guardrails

**M5 — Session memory**
- `LemonCore.SessionStore` — JSONL-backed session persistence
- `LemonCore.SessionSearch` — full-text search across past runs
- Memory management and pruning

**M4 — Skill quality**
- Skill audit engine with 5 rules (`LemonSkills.Audit.Engine`)
- Skill install policy with trust tiers
- Official registry namespace and trust policy
- `mix lemon.skill` expanded: `inspect`, `check`, `browse`, `update`

**M3 — Progressive skill loading**
- Unified skill prompt view and activation logic
- Stop inlining full skill bodies in prompts
- Upgrade `read_skill` to structured partial loads
- Prompt/token regression tests

**M2 — Skill installer and registry**
- Manifest v2 parser and validator
- Expanded `LemonSkills.Entry` with lockfile storage
- Source abstraction and source router
- Refactored installer and registry around inspect/fetch/provenance
- Legacy skill migration path

**M1 — Runtime and tooling**
- First-class OTP releases (`lemon_runtime_min`, `lemon_runtime_full`)
- `mix lemon.setup` with interactive subcommands
- `mix lemon.doctor` diagnostics framework with redacted source-dev and release-runtime support bundles
- Staged `mix lemon.update`
- Gateway setup adapters (Telegram, Discord)
- Release smoke tests and packaging docs

**M0 — Foundation**
- Ownership model and CODEOWNERS
- Feature flags and rollout config scaffolding (`LemonCore.Config.Features`)
- Frozen shared schemas and invariants

### Changed

- Root README condensed from 3127 lines to 184 lines (deep content moved to `docs/`)
- CI and docs now target Elixir 1.19.5, Erlang/OTP 28.5, and Node.js 24 LTS.
- Setup docs and config examples now include an OpenAI-compatible endpoint path.
- Public docs now clearly distinguish source install, local artifact proof, and bounded 1.0 support claims.

### Fixed

- Untrusted tool output can no longer bypass the external-content wrapper simply by including both boundary markers.
- Inbound email prompts are wrapped as external untrusted content before router submission.
- Telegram bare `/cancel` now aborts active runs even when the command is not a reply to a progress message.
- Telegram invalid model/config errors now render concise failure text instead of exposing BEAM stack traces.

---

## Release Channels

| Channel | Cadence | Stability |
|---|---|---|
| `stable` | Monthly | Fully tested |
| `preview` | Weekly | Feature-complete, light testing |
| `nightly` | Daily | Automated, may be broken |

See [`docs/release/versioning_and_channels.md`](docs/release/versioning_and_channels.md).
