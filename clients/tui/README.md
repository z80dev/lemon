# lemon-tui

The lemon terminal client: a Bun application built on
[`@oh-my-pi/pi-tui`](https://www.npmjs.com/package/@oh-my-pi/pi-tui)
(differential terminal renderer with native-scrollback streaming) that talks
to a running lemon daemon over the control-plane WebSocket
(`ws://127.0.0.1:4040/ws` by default).
When a token is configured, the handshake sends it in the control plane's
`params.auth.token` envelope.

Installed users get this client as a compiled per-platform binary
(`~/.lemon/versions/<v>/tui/bin/lemon-tui`); plain `lemon` in an interactive
terminal launches it, auto-starting the daemon first. See `docs/install.md`.

The source launcher `../../bin/lemon-tui` securely bootstraps a fresh local
runtime: when no runtime is listening and no token is configured, it generates
a high-entropy process-scoped `LEMON_CONTROL_PLANE_OPERATOR_TOKEN`, passes the
same value to the daemon and TUI through their environment, and stops that
launcher-owned daemon when the TUI exits. The token is not written to disk,
placed in command arguments, or printed.

Every runtime started by `../../bin/lemon-tui` is launcher-owned and stopped
with the TUI, including when `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` was already
set. The source `../../bin/lemon daemon` and installed `lemon daemon` launchers
instead create a port-scoped operator credential at
`~/.lemon/run/control-plane-<port>.token`, with a mode-0700 parent and mode-0600
file, and pass it to the persistent runtime. A later TUI validates the file is
regular, owned by the current user, mode 0600, and a full 256-bit token before
loading it automatically.

Explicit `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` values remain caller-owned and
are never written to the managed credential file. Attaching to a runtime
started with an explicit token therefore still requires the same environment
value. The client sends credentials only inside the WebSocket `connect.auth`
envelope and does not include them in debug frame summaries. `LEMON_WS_TOKEN`
remains a legacy client-side alias; it does not configure the daemon.

## Features

- Streaming markdown using pi-tui's native Tern surface or bounded terminal
  frame provider with semantic scrollback retirement and grapheme-safe reveal.
  Separate chronological text segments around thinking and tools keep later
  answers below tool history. Ordinary chats run in the directory where the
  TUI was launched; canonical profile chats retain their daemon-owned workspace.
- Tool cards with per-tool formatters for Lemon's native tools (read, write,
  edit, patch, bash incl. background runs / `bash_output` / `kill_process`,
  grep, find, ls, todo, task/agent, `browser_*`, webfetch/websearch; anything
  else gets a generic card), lifecycle states, and shelf merging of
  consecutive completed tools. Operator clients receive each tool's bounded
  full result (~32 KB) and structured details, so edits render the tool's own
  diff with real file line numbers. Against an older daemon that only sends
  500-char previews, cards fall back to the preview and to unnumbered diffs.
  Native patch receipts use their actual changed-file list (including Lemon's
  `*** Update File` format). Child task progress has one independently updated
  card per task, separate from the completed parent launch receipt.
  Elapsed time freezes when completion is observed and survives session switches
  and transcript rebuilding. Historical receipts without authoritative timing
  omit duration instead of measuring their age as tool runtime.
  Saved tool calls and results pair by native call ID, retaining arguments,
  output and details. Cancelled receipts stay terminal (distinct from failed)
  with captured partial output available on expansion. Saved calls without a
  terminal result say “outcome unknown”; history never starts a spinner or
  invents elapsed time, and only a recorded duration is shown.
- The model's thinking is its own dimmed transcript block, collapsed to its
  first line (up to 16 KB of reasoning is available when expanded).
  Native Tern rendering uses a semantic thinking block and Markdown body, not
  a row-fallback badge; collapsed/expanded/hidden state stays intact.
- Ctrl+R expands/collapses the latest tool card or thinking block (a merged
  shelf line opens into a full card); Ctrl+T cycles detail for the whole
  transcript: collapsed → expanded → per-kind default.
  Alt+O toggles all tool output between collapsed and expanded without changing
  Ctrl+O's model-picker binding. `/output` opens a scrollable complete tool receipt;
  Alt+D or `/diff` opens the latest edit diff. Use arrows, Page Up/Down, or Home/End
  (`g`/`G`) to navigate and `d` to switch between diff and raw output. The viewer
  preserves the daemon's bounded receipt rather than silently stopping at card height.
- Alt+A or `/tasktree` opens session-scoped child progress with real parent/child
  lineage, role, current activity, elapsed time, and independent terminal states.
  Arrow keys scroll the bounded panel; Escape returns to the draft. Completed
  launch receipts never imply that their children have finished.
- Alt+M or `/omp` opens the omp delegate panel: live and recent omp (oh-my-pi)
  processes the daemon runs, with status, activity, tools, todos, subagents,
  usage/cost/context and their latest text; Enter shows detail, `s`/`f` steer or
  follow up, `c` cancels the turn, `x` closes, `r` refreshes, `d` resumes a stored
  session for this directory. `/omp run <prompt>` starts one in the chat's working
  directory and `/omp status` summarises them; the status line shows `omp N▶`
  while any run. Mutations are never queued offline and report refusals or
  unknown outcomes honestly; omp text is rendered as inert plain text.
- Exec approval panel (allow once / session / always / deny, number
  quick-pick, wrapped command preview, expiry countdown).
- Four submission modes while the agent is busy: `queue` (client-side,
  editable), `steer`, `redirect`, `interrupt` — with graceful fallbacks. Redirect
  replaces pending model direction while preserving completed tool work. Interrupted
  replies keep their partial text. Authoritative cancellation receipts render
  as interrupted, not as a generic failed run; real failures retain their error.
  The busy status line shows `enter:<mode>` and `esc:stop`; Escape interrupts
  without discarding a correction in the editor (autocomplete gets Escape first).
  Shift+Enter inserts a newline. Up/Down recall prompts, and discarded large
  pastes remain recoverable after later submissions.
  Ctrl+V accepts clipboard images where the platform provides them, and pasted
  or dragged local image paths attach actual PNG, JPEG, GIF, or WebP bytes.
  Up to five images totaling 10 MiB may accompany a prompt, including an image-only
  prompt. Attachment chips stay with their session; Ctrl+Shift+Backspace removes
  the last one. Refusal or a disconnected connection retains both draft and images.
  Queued images remain editable; an uncertain failed send requires explicit review
  rather than automatic replay. Non-image dropped files become quoted `@` references,
  and `@` completion navigates files without reading their contents into the prompt.
- Multi-session: Ctrl+X switcher (live + recent, debounced server-side search
  across stored sessions, new-with-prompt, close), per-session drafts, unread
  badges, history hydration. Search results are not restricted to the initially
  loaded recent sessions; failed searches never leave stale rows selectable.
  Picker filters accept bracketed paste as text, including copied model names
  and session searches.
- Durable session lifecycle: `/sessions` adds server-backed text, agent,
  pin, and archive filters to the draft-preserving picker; `/session` can
  inspect, resume, title, pin, archive, preview, privately export, prune, and
  delete through the authenticated server-owned lifecycle. Prune and delete
  are preview-confirm workflows, and offline mutations never claim success.
- `/tree` inspects active and preserved branches and is the entry point for
  branching: selecting an entry opens its actions — inspect it, switch the
  active branch to it (optionally summarizing the abandoned branch), set or clear
  a bookmark label, or fork a new session from it. A switch is non-destructive
  (the old branch stays in `/tree`), is refused while a run is active, reloads the
  session, and recalls a selected user prompt into the editor without sending it
  (the prompt is shown instead when the editor already has a draft). Labels show
  as `[label]` in `/tree`; `/tree label <entryId> <text>` and
  `/tree unlabel <entryId>` set them directly. The abandoned-branch summary is
  generated in the background by a loaded session only; a stopped session just
  switches. `/rewind` picks an earlier
  active user prompt, previews the change, then requires confirmation bound to
  that exact preview. History-only rewind leaves files untouched and does not
  list files as restoration targets. `--files` requests checkpoint restoration;
  non-restorable effects block confirmation by default. When the daemon permits
  partial restoration, explicitly choosing “Allow partial restoration” obtains
  a fresh preview: “restore N checkpointed files; effects of M shell commands
  are not reverted,” followed by the command list. Only checkpointed files are
  restored. Cancel is the default; changing consent requires another preview.
  Success reloads the active branch and recalls the selected prompt into the
  editor without sending it. `/name` gives the current session a durable title.
  Before the first turn, a fresh local session is explicitly persisted through
  `sessions.create` before naming; this sends no prompt and enters no plan.
- Ctrl+O model picker (two-stage, draft-preserving, provider-qualified routing),
  Shift+Tab thinking picker (`/think` or `/reasoning` also opens it),
  capability-aware slash commands with
  autocomplete, `!cmd` shell escape, `{!cmd}` inline interpolation,
  Ctrl+G `$EDITOR` handoff. Captured shell escapes have a bounded deadline and
  terminate their complete POSIX process group on timeout so descendants cannot
  outlive the command or hold the TUI's capture pipes open.
  Ctrl+P, `/palette`, or `/` in an empty editor opens one fuzzy command palette
  for command names, aliases, descriptions, local skills, and prompt templates.
  Ctrl+P and `/palette` keep destructive selections and argument-taking actions
  as drafts rather than sending them. When typing `/` directly, Enter executes
  an exact command or alias; a space after a recognized command returns its full
  text to the editor for arguments. Escape preserves the typed slash query.
  Templates are discovered from `.lemon/prompts`, `.claude/prompts`, and
  `$LEMON_AGENT_DIR/prompts` (default `~/.lemon/agent/prompts`), with project names
  taking precedence. Local skills insert an explicit `read_skill` request; the
  palette does not claim that a remote daemon or selected profile installed them.
- `/skills` live official Hermes catalog browser: category drill-down, fuzzy
  filtering, descriptions, installed markers, and Space-toggle multi-select
  import through Lemon's normal audit/approval flow. A blocked bundle opens a
  conspicuous `SECURITY OVERRIDE` panel whose choices say that acceptance is
  limited to the exact audited bundle; ordinary install approval cannot satisfy
  it. Skill mutations use a six-minute request window so the approval panel and Git fetch can complete
  without inheriting the ordinary 15-second RPC deadline; the connection stays
  live for approval events and health probes throughout.
- `/profiles` live profile roster with current-chat, model, named-node, and
  availability context; `/profile` opens stable canonical chats and exposes
  guarded create/clone/rename/export/delete lifecycle commands. Ordinary
  prompts in an opened profile use `profile.chat`, preserving the server-owned
  derived workspace and named-node route.
- `/blueprints` bounded catalog picker plus `/blueprint` content-free inspect,
  validate, profile preview, and exact-digest activation. The TUI re-previews
  before every mutation, never queues activation offline, preserves the profile
  draft after refusal, and reports create-once or unchanged replay without
  retaining manifest prose or executable/source content.
- Progressive-disclosure status bar: model and context gauge stay pinned;
  last-run token usage and reported USD cost are separate from context size,
  followed by git branch, connection state, submission mode and session counters.
  Unknown cost is omitted, never estimated. A focused session with stored history
  but no run usage yet is measured once through `sessions.context`, and `/context`
  refreshes the gauge with the daemon's measurement; a later run's usage supersedes it.
- `/context` (or `/ctx`) opens a scrollable breakdown of the focused session's
  context window: a 100-cell usage grid colored per category with free space dimmed,
  per-category tokens and share of the window (system prompt, tools, skills, context
  files, memory, messages, tool results, summaries), free space, auto-compaction
  headroom, the largest contributors, and how the figures were measured. Splits
  are ≈4 chars/token estimates scaled to the provider-reported total. In Tern the
  panel is a native sheet whose meter matches the composer's context meter, split
  by category, and clicking the composer meter opens it. It needs a daemon that
  advertises `sessions.context`, is never queued offline, and says "No context
  recorded yet" for a session that has not run a prompt.
- Dark/light themes with OSC 11 terminal-background auto-detection; mouse
  support in overlays.
- `/theme <name>` and the model picker's **Make default** (Ctrl+G) persist to
  `~/.lemon/config.toml` as `[tui] theme` and `[defaults] provider`/`model`.
  Only those keys are edited in place; comments and every other table are
  kept, and the edit is refused if the result would not parse.
- Native terminal integration: Tern pane detection, prompt/reply navigation
  marks (OSC 133), clickable URL and file references (OSC 8, including `#L42`
  line anchors), a session/status title, turn-completion and approval desktop
  notifications, and an indeterminate progress indicator while working.

### Tern and modern terminals

Plain `lemon` (or `lemon tui`) in a Tern pane opens the terminal client; Tern's
native ACP chat is separate (`tern acp lemon`). The TUI detects `TERN_PANE` or
`TERM_PROGRAM=tern` and negotiates pi-tui's Tern Surface Protocol (TSP).
Prompts, replies, tool calls and the composer are semantic nodes, not painted
cell screenshots. This gives Tern reply navigation, native markdown/code blocks,
and Carly's agent start/ask/wait/transcript operations. A delegated prompt waits
until the connected composer is ready, submits atomically, and preserves any
human draft in recall history. Configure Carly's agent command as `lemon tui`
for this path.
The final reply is published before the terminal is marked idle, so Carly's
`wait` observes the complete answer rather than the last streaming fragment.

In Tern the composer carries what the status line shows elsewhere, as omp's
does: a context meter along its top edge (per-session context only), image
attachments as chips with a remove control, and a bar with the model chip
(click: model picker, as Ctrl+O), the thinking-effort chip (click: `/think`,
as Shift+Tab), the session's status facts (clicking sessions/unread, queued,
the submission mode or approvals opens the switcher, edits the queue, cycles
the mode or runs `/approvals`), the last run's usage (click: `/cost`), and
Send — Stop while the run is live, which aborts like Esc. An empty composer
shows the session's title as its placeholder. No separate status strip is
drawn; the row renderer keeps its status line.

Tern's native **Run** button on shell fences in replies executes in the pane's
working directory and displays the output below the fence; **Stop** interrupts
that command. Execution belongs to Tern and always requires the user's Run
gesture. The client reports its working directory using OSC 7.
Native file-tool targets open Tern's editor block with **⌘-click** (**Ctrl-click**
on PC), at the reported changed line or read offset. They share their location
with row-renderer OSC 8 links; a normal click folds the card and tools never
open editor panes automatically. Patch cards target the first surviving changed
file. `lemon tern install` also provides palette actions to open a native TUI
split in the focused pane's cwd or focus an existing Lemon pane; see the
[Tern guide](../../docs/user-guide/tern.md).

Transcript chrome uses omp's shared Tern roles. Prompts show their send time,
attached images and a steered/redirected/interrupted badge. A finished turn has
a footer with Copy, duration, tokens and cost as reported by the daemon. Failed
runs and error notices are error frames with **Copy error** (and **Switch model**
for runs). Thinking is a live spinner section that folds to "Thought for Ns".
Compaction results render as a compaction divider. While a run works, the dock
shows a working row whose **Stop** takes Esc's abort path. Queued prompts are
pills with an **Edit** control, and approvals offer clickable decision buttons
with the full action and a countdown. The Alt+A task tree is a card of subagent
nodes. Copy writes the clipboard over OSC 52.

Tool calls are omp's semantic tool cards rather than painted text: shell calls
are run boxes (command, tail-following output, `Done`/`exit N` foot), edits and
patches are native diffs with `+N −M` stats, reads are numbered code, grep,
find and ls are file rows, web searches list linked sources, todos are a
checklist and tasks are subagent rows. Cards fold to a short preview; open one
from its head (or Ctrl+R), or all with Alt+O or Ctrl+T. Consecutive reads
fold into one `Read N files` row group whose files open at the read offset.
The tool inspector (`/output`, `/diff`) shows the full receipt as a native
diff or output block.

Pickers open as Tern's native picker sheets over the transcript rather than a
painted full-screen box: the session switcher (cards with title, key, busy dot,
unread/archived badges, model and age; **New session** / **Close session**
buttons), the model picker (one list grouped by provider with provider marks,
context column and the current model marked; **Make default** mirrors Ctrl+G),
the command palette (grouped by kind, with the global key beside commands that
have one), `/output` and every slash-command picker. Keys behave exactly as in
the row renderer; a row click selects, a second click or the primary button is
Enter, and Close is Esc. The startup banner becomes Tern's welcome card.

Other terminals, or `PI_TUI_NATIVE=0`, use the row renderer. OSC 133 marks stay
attached to prompt/reply rows as they enter scrollback. Markdown URLs,
inline-code file references such as `src/app.ts:42`, and file tool-card titles
are clickable through OSC 8. File targets are absolute `file://` URLs with an
optional `#L42` fragment; spaces and special characters are URL-encoded.

The title shows the focused session name (or key) and current status. `lemon_session`
and `lemon_status` are exported as base64 OSC 1337 SetUserVar markers; this
terminal client intentionally does **not** claim `tern_acp_session`, which is
reserved for native ACP chats. Tern receives OSC 7501 program status:
working, blocked for approval, done, or error. Cancelled turns return to neutral
idle instead of reporting success or failure. Its pane glow, inbox, completion
banners and Carly waiting state follow those transitions. Other terminals
receive generic OSC 9 or OSC 777 notifications (including “Turn interrupted”
for cancellation), never prompts, answers, commands, or tool arguments.

pi-tui negotiates kitty keyboard support with a capability query rather than
assuming it from environment variables, preserving the parent keyboard flags.
Exit and external-editor handoff restore the keyboard, cursor and raw mode,
clear the progress indicator and remove the session markers. The title is
restored where the terminal supports the xterm title stack, otherwise cleared
so an exited client never leaves a stale working/approval status.
`LEMON_TUI_NOTIFICATIONS=0` disables OSC 9/777 notifications; Tern's program
status inbox and banners follow Tern's own notification settings.
`LEMON_TUI_TERMINAL_INTEGRATION=0` disables Lemon's terminal side channels and
row transcript marks. `PI_TUI_NATIVE=0` disables native surfaces, and
`PI_NO_HYPERLINKS=1` disables row-renderer links. pi-tui's multiplexer
capability policy remains authoritative. Non-TTY and `TERM=dumb` output do not
emit Lemon's side channels.

## Hermes-compatible commands

The TUI accepts familiar Hermes command names while keeping Lemon's runtime
and control plane authoritative:

| Command | Lemon behavior |
| --- | --- |
| `/queue [prompt]`, `/q [prompt]` | With a prompt, use queue mode for that submission; without one, inspect and edit the pending queue. `/q` is intentionally queue, not quit. |
| `/steer <prompt>` | Send one steering submission without changing the default submission mode. |
| `/redirect <prompt>` | Replace the active run's pending model direction without changing the default submission mode. |
| `/reset` | Reset the current session through `sessions.reset` and clear its local transcript. |
| `/reasoning [level]` | Alias for Lemon's `/think` reasoning-effort control. |
| `/stop` | Alias for `/abort`; partial output remains visible and is marked interrupted. |
| `/status`, `/usage` | Show control-plane health/runtime and usage/quota summaries. |
| `/think`, `/reasoning`, Shift+Tab | Pick a thinking level without losing the current draft; an explicit level still applies directly. |
| `/agents`, `/tasks` | Show the Lemon agent directory and active/recent subagent tasks. |
| `/compact [focus instructions…]`, `/compress [focus instructions…]` | Manually compact the current session through `sessions.compact`, with optional instructions about what context to preserve. |
| `/context`, `/ctx` | Show the focused session's context-window breakdown from `sessions.context`: usage grid, per-category tokens, free space, compaction headroom and largest contributors. Esc closes. |
| `/plan [request…]` | Toggle plan mode for the focused session: the agent plans read-only, then asks for approval before executing. With a request, enter plan mode (if needed) and send it as the planning prompt. |
| `/heartbeat every 30m <prompt>`, `/hb ...` | Create or replace the focused agent's heartbeat cron job (`heartbeat-<agent>`, runs in `agent:<agent>:main`) through `cron.list`/`cron.add`/`cron.update`. Intervals must be cron-exact: minutes dividing 60, hours dividing 24, or `1d` (daily, 09:00 server-local). Results reach your paired Telegram chat; a reply of exactly `HEARTBEAT_OK` is suppressed. `/heartbeat status`, `pause`, `resume`, and `clear` use `cron.list`, `cron.pause`, `cron.resume`, and `cron.remove`. |
| `/bg <prompt>` or `/bg start <prompt>` | Start background work through `background.start`, inheriting the TUI's durable session key, cwd, model, and reasoning level. The full returned id is displayed intact for lifecycle commands. |
| `/bg list [status]` | List durable background runs, optionally filtered by lifecycle status. |
| `/bg status <id>` | Inspect one background run without truncating its id. |
| `/bg result <id>` | Fetch the completed answer, or report that it is not ready yet. |
| `/bg cancel <id>` | Cancel a queued or running background task. |
| `/btw <question>` | Ask an isolated side question through `session.btw` when advertised. |
| `/commands [command]` | Prefer the daemon's `commands.catalog`; fall back to the TUI's local registry during rolling upgrades. |
| `/help [command]` | Show the local TUI command and key reference, including unavailable capability annotations. |
| `/profiles` | Browse the live node-aware profile roster and open the selected `agent:<id>:main` chat. |
| `/profile [current|show|open|chat|create|clone|rename|export|delete] …` | Inspect or manage profiles through the authenticated `profile.*` / `profiles.*` APIs. Create/clone accept only server-supported profile fields such as `--model` and `--node`; delete requires `--confirm <same-id>`. |
| `/sessions [query…] [--pinned\|--unpinned] [--archived\|--active] [--agent <id>] [--limit <n>]` | Search and filter the durable server roster, then type to refine in the accessible picker. With no arguments, open the merged live/recent session switcher. |
| `/session current\|show\|search\|open\|resume\|title\|pin\|unpin\|archive\|unarchive …` | Inspect safe lifecycle metadata, resume durable history, open an exact key, or update title/pin/archive state without a client-side metadata store. |
| `/session preview\|export …` | Read a bounded redacted preview or write a digest-verified JSON/Markdown export through a private atomic file operation. Use `/session help` for exact syntax. |
| `/session prune --older-than <cutoff> …` | Preview the complete exact candidate set and receive its confirmation token; repeat with `--confirm <token>` to prune only an unchanged set. Archived, unpinned sessions are the safe default. |
| `/session delete [key] …` | Preview one exact durable session, then repeat its key with `--confirm`; optionally use `--export json\|markdown` to verify a redacted export before verified deletion. |
| `/tree [label <entryId> <text>\|unlabel <entryId>]` | Browse the paginated native session tree, including preserved branches, labels and bounded redacted user/assistant previews. Selecting an entry offers: inspect, switch the active branch here (optionally summarizing the abandoned branch), set/clear its label, or fork a new session from it. Switching is refused while a run is active. |
| `/rewind [--files]` | Select an active user prompt, preview history-only or checkpointed-file rewind, then explicitly confirm the exact preview. Refused or stale confirmation preserves the local draft and transcript. |
| `/name <title…>\|--clear` | Set or clear the current session's durable title through `sessions.metadata.patch`. |
| `/blueprints [bundle-id filter]` | Browse bounded catalog IDs/counts, then inspect the selected entry through the shared authenticated service. |
| `/blueprint [help\|list\|inspect\|validate\|preview\|activate] …` | Inspect and validate content-free metadata, preview one profile without mutation, or activate only after a fresh exact digest match. Refused/stale plans preserve the profile draft and never queue offline. |

Use `/quit` (or the existing keyboard exit binding) to leave the TUI. `/clear`
remains visual-only: it clears terminal scrollback and the rendered transcript
without resetting daemon-side session history. Use `/reset` when history should
also be forgotten.

Fresh startup and `/session new` sessions use canonical local channel-peer keys:
`agent:default:tui:local:dm:<UUID>`. Separate launches get distinct keys, so
automation goals and session views can validate and route them consistently.
Explicit `--session` keys and resumed legacy `tui-…` sessions remain unchanged.

### Plan mode

`/plan` toggles the focused session's native plan mode. While it is on, the
agent can only read the project and write its own plan file (a session-private
`<slug>-plan.md` outside the working tree), and the status line leads with an
accent-coloured `plan` segment (in Tern's native composer chrome it is the
first composer fact). There is no separate TUI plan store: the indicator is re-read
through `sessions.plan` on connect, on session switch, after each `/plan`, after
a plan proposal is answered, and when the focused session's run completes.

`/plan <request…>` enters plan mode first when it is off (and only once the
daemon confirms it), then sends the request intact through the ordinary prompt
submission path; when plan mode is already on it just sends the request.

When the plan is decision-complete the agent calls `propose_plan`. The approval
panel shows `Plan proposal · <title>`, the plan file path and the first lines of
the Markdown (the rest is counted), with exactly two choices — numbered keys in
the row renderer, clickable buttons in Tern's native approval chrome:

- **Approve and execute** (`approve_once`) turns plan mode off, restores the
  full tool set and lets the agent implement the plan in the same run.
- **Refine plan** (`deny`, also Esc) keeps plan mode on; the agent ends its turn
  and waits for your feedback, which you send as a normal prompt.

No session, agent or global scope applies to a plan proposal, and `/approve`
refuses one. Running `/plan` while plan mode is on exits it without approving
or executing anything; when the plan file already has content a cancel-default
`Exit plan mode?` confirmation comes first. Stop an active run before toggling
plan mode. Plan operations require a daemon advertising `sessions.plan` and are
never queued offline.

### Manual compaction

Use `/compact` or `/compress` to explicitly compact the focused session, even
when automatic compaction has not reached its threshold. Optional text is
forwarded intact (including inner whitespace and quotes) as focus instructions:

```text
/compact Preserve the public API decisions, test failures, and remaining tasks
```

The command sends the session key, project cwd and optional `focus` to
`sessions.compact`; the native service uses that text as `custom_instructions`,
not as a replacement summary. Canonical profile workspace resolution remains
server-owned. The receipt reports success and available token counts, never
the private summary or raw server exception. Manual compaction is not queued
offline.

### Forking a session

`/fork` asks the authenticated daemon's `sessions.fork` method to create an
independent durable branch of the current native session; the original remains
unchanged. The `/tree` action “Fork a new session from here” does the same with
history ending at the selected entry (inclusive) instead of the current leaf. The command is unavailable on daemons that do not advertise it and
is never queued while offline.

Inside Tern, the child opens in a right-hand split beside the originating pane,
using the same Lemon source entry point or compiled binary, working directory,
and control plane. Outside Tern, the current client switches to the child.
An explicit launch key (including a fork) restores its saved conversation,
active run, model, and pending approvals before Carly can send the next prompt.
The operator credential travels through a private one-shot handoff (mode-0700
directory, mode-0600 file), consumed and removed before connecting and installed
in the child's environment; it is never placed in command arguments.

The source transcript reports the new session key before opening it. If the
split cannot launch, the durable child is retained: use the displayed
`/session open <child-key>` command to recover it. A fork does not start a second
daemon; if the original source launcher owns the daemon, that launcher's lifetime
still controls the shared connection.

## Development

Requires Bun >= 1.3.14 (pinned in `.bun-version`).

```sh
bun install               # exact-pinned @oh-my-pi/{pi-tui,pi-utils,pi-natives}
bun src/main.ts --ws-url ws://127.0.0.1:4040/ws   # run against a daemon
../../bin/lemon-tui       # same, with daemon auto-start (repo dev launcher)

bun test                  # unit + fake-server integration suites
bun run check             # tsc --noEmit
bun run lint              # biome
bun run gallery           # headless render of every component/state
```

The fake control plane (`src/dev/fake-server.ts`) powers the tests and the
gallery; no daemon or credentials are needed for either. Profile and session
lifecycle verticals also have authenticated real-Bandit proofs that launch the
production typed Bun client against isolated server-owned state:

```sh
cd ../..
MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/tui_profiles_wire_e2e_test.exs --seed 1
MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/tui_sessions_wire_e2e_test.exs --seed 1
MIX_ENV=test mix test apps/lemon_control_plane/test/lemon_control_plane/tui_blueprints_wire_e2e_test.exs --seed 1
```

Profile commands deliberately do not accept a profile home or workspace path.
The daemon derives that boundary from the validated profile ID. The only path
accepted by the profile UX is the output destination for the credential-safe
`/profile export` operation, matching the control-plane export contract.

Session roster, status, and lifecycle error views intentionally render lifecycle
metadata only—never prompts, responses, credentials, raw server details, or
local paths. Export content comes from the server's redacted contract; the TUI
then verifies its key, format, byte count, and SHA-256 before a private write.
Delete only forgets the local transcript after the server returns a verified
receipt. Prune confirmation binds the cutoff, flags, and exact candidate set.

Blueprint picker, status, preview, and receipt views intentionally render only
bounded IDs, counts, actions, booleans, and digests. Free-form manifest names or
descriptions, prompts, skill bodies, schedules, commands, environment values,
paths, URLs, tokens, secrets, and raw daemon errors are discarded before TUI
state. Activation re-previews through `blueprints.preview`, requires its exact
fresh digest, then calls nonqueueable `blueprints.activate`; replay with the new
unchanged digest leaves one scheduler job.

### Layout

```
src/protocol/    WS client: frames, reconnect+liveness, correlation, typed methods
src/store/       plain mutable stores; controllers are the only writers
src/ui/          components (pi-tui Component impls) + controllers + theme
src/commands/    slash-command registry (capability-gated via hello-ok)
src/formatters/  pure per-tool formatters -> {summary, details[]}
src/dev/         fake server, gallery, fixtures
src/terminal/   terminal capabilities, status/marks/links, secure split launching
scripts/         build-binary.ts (bun --compile, per-platform artifacts)
```

### Render-contract notes

pi-tui's append-only scrollback contract is unforgiving; before editing
components read the [pi-tui README](https://www.npmjs.com/package/@oh-my-pi/pi-tui)
and keep to the house rules: return the same array reference from
`render(width)` when unchanged; never exceed `width` (measure with
`visibleWidth`, never `.length`); never declare a settled row that could
still change; animate via `requestComponentRender` only; `initTheme()`
before constructing any component.

All three pi packages are pinned to 18.10.3. The product frame provider owns the
row renderer's main/dock split and semantic retirement; Tern's native backend
uses `describeSurface()` and the same component tree. Native descriptions must
retain stable node references while unchanged. Chat roles `omp.user`,
`omp.assistant`, composer `omp.editor`, and surface `omp.session` are the shared Tern/Carly vocabulary,
not an assertion that the client is omp. Never emit `omp_session_file` or
`omp_restore`: Lemon sessions are daemon-owned, not omp JSONL files.

### Releasing

The release workflow cross-compiles `lemon_tui` artifacts for linux-x86_64,
linux-arm64 and darwin-arm64 via `scripts/build-binary.ts` and ships them in
`manifest.json` alongside the runtime tarballs; `install.sh` and
`lemon update` stage both atomically. The three `@oh-my-pi/*` packages are
exact-pinned and must be bumped together (upstream releases in lockstep).

Release binaries contain precompiled bytecode plus syntax/whitespace-minified
JavaScript, with component identifiers preserved and linked source maps for
original stack locations. Startup measurements end at the first real frame,
not at a placeholder or readiness timer.

The checked-in Bun patch for pi-tui narrows its thinking-level import to the
public leaf module, avoiding eager provider/catalog initialization. It also
restores saved POSIX terminal attributes with `TCSANOW`: Bun's `TCSADRAIN`
restore otherwise waits indefinitely when a PTY reader stops consuming output.
App cleanup runs before the terminal output pump closes, and already-restored
terminals are not restored again through unbounded direct writes. Keep these
fixes when updating the pinned pi packages until equivalent upstream fixes
are included; use `bun install --frozen-lockfile` to apply the patch reproducibly.
