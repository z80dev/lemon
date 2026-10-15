# Use Lemon in a Browser

Last reviewed: 2026-10-13

The full Lemon runtime includes Lemon Web: a browser workspace for coding
sessions plus every operator surface (automation, skills, memory, MCP, nodes,
models, usage, diagnostics and settings). It talks to the same control-plane
methods and events as the TUI, so both clients always show the same sessions,
approvals and plan state.

```bash
lemon web            # start the runtime if needed, open the browser signed in
lemon web --no-open  # only print the address
```

The default address is `http://127.0.0.1:4080/`. Set `LEMON_WEB_PORT` before
launch to choose another port. A source checkout uses `./bin/lemon web`.
`lemon web` requires the `lemon_runtime_full` release profile; reinstall with
`LEMON_PROFILE=full` if the launcher reports the minimal profile.

## Sign in

Lemon Web uses the control plane's operator token, the same credential the TUI
uses (`LEMON_CONTROL_PLANE_OPERATOR_TOKEN`, normally the launcher-managed
token). `lemon web` opens `/login#token=…`: the token travels in the URL
fragment, which browsers never send to a server, and the page removes it from
history before signing in. Otherwise paste the token on the login page.

- The server checks the token and keeps only a derived marker in a signed,
  encrypted, httpOnly cookie. Rotating the operator token signs every browser
  out.
- Every page requires sign-in. Without a configured token the UI returns 503,
  unless `LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK=true` is set and the
  browser connects directly from loopback.
- Repeated wrong tokens from one address are throttled for a minute.
- Sign out from the bottom of the navigation rail or **Settings → Operator**.

`LEMON_WEB_ACCESS_TOKEN`, `?token=` URLs and the `/manage` pages were removed;
use the operator token and the pages below.

## Layout, themes and keyboard

The navigation rail groups **Workspace** (Chat, omp, Sessions), **Automate**,
**Knowledge**, **Runtime** and **System**. On phones it becomes a drawer behind
the menu button. Choose light, dark or system theme at the bottom of the rail or
in **Settings** (⌘⇧L / Ctrl+Shift+L cycles it).

| Keys | Action |
| --- | --- |
| ⌘K / Ctrl+K | Command palette: pages, actions, sessions; Tab or a leading `/` searches everywhere (session content, memory, cron jobs) |
| `?` | Every shortcut, grouped |
| `g` then a letter | Go to a page (`g c` chat, `g s` sessions, `g a` automation, `g m` models, …) |
| ⌘/ | Focus the composer |
| ⌘. | Stop the active run |
| ⌘⇧O | New session |
| ⌘⇧P | Toggle plan mode |
| ⌘⇧M | Model picker; Shift+Tab in the composer cycles thinking level |
| ⌘B / ⌘I | Toggle the sessions sidebar / inspector |
| ⌘\\ | Split view |
| Alt+↑ / Alt+↓ | Previous / next session |
| Alt+O / Alt+R | Expand all tool output / the latest tool or thought |
| `/` | Focus the filter on list pages; `j`/`k`, Enter on the session manager |

Ctrl replaces ⌘ off macOS. The palette's chat actions (fork, compact, plan,
stop, inspector, split, pickers) appear only on a chat page.

**Notifications:** the bell lists recent run completions and approval requests
from sessions other than the one in front of you. Enable desktop alerts there
or in **Settings**; they appear only while the tab is in the background.

## Chat

**Chat** (`/`) starts a session: describe the task, choose the workspace folder
(recent folders are one click) and optionally a profile. The page lists active
and recent sessions. If setup is incomplete it explains what is missing and
keeps sending disabled; run `lemon setup`, then **Check again**.

A session opens at `/chat/<session-key>`:

- **Sidebar:** search, new, rename, pin, archive, fork, open in split, and a dot
  on sessions with a running agent.
- **Header:** inline rename, run status, plan indicator, context gauge, split,
  fork and a menu with exports and the session manager. The toolbar holds the
  model, thinking-level and tool-policy pickers ("Ask before commands & edits"
  requires approvals).
- **Transcript:** answers stream as Markdown with highlighted, copyable code.
  Thinking is collapsible. Tool cards show shell commands with live output, exit
  status and duration; file reads with line ranges; edits as diffs; searches with
  match counts; todo checklists; subagents with status and links. Each run ends
  with model, duration, tokens and cost.
- **Composer:** Enter sends, Shift+Enter adds a line, attachments (up to five
  files of 20 MB; paste or drop images). Images can total up to 10 MiB
  (10,485,760 bytes, shown as “10 MB” in upload errors) per message. While Lemon works, choose **Follow-up**
  (queued for after the run), **Steer** (guidance for the current run; ⌘Enter)
  or **Redirect** (new direction, finished tool work kept), or **Stop**.
- **Approvals** appear in the conversation: Approve once, for the session,
  always, or Deny. Answers given in the TUI or another tab clear the card.
- **Plan mode** (⌘⇧P) keeps the agent read-only. Its proposal appears as a plan
  card: **Approve & execute** runs it, **Refine** sends it back and focuses the
  composer for your feedback. Leaving plan mode never approves a plan.
- **Inspector** (⌘I): **Context** (window usage by category, largest items,
  auto-compaction threshold, Compact), **Plan**, **Changes** (git status of the
  session folder with unified or split diffs), **Subagents** and **Details**.
- **Split view:** ⌘\\ or "Open in split" shows two sessions side by side
  (`/chat/<key>?split=<other-key>`); each pane runs independently.

After a reconnect the page re-checks the active run and continues streaming
without repeating the final answer. Controls that change state are disabled
while the connection is down; nothing is queued offline.

## Sessions and profiles

**Sessions** (`/sessions`) searches titles, keys, prompts and answers, with
Active/Archived/All tabs, a pinned filter and an agent/profile filter (all kept
in the URL). Rows open in chat or inspection and offer rename, pin, archive,
fork, JSON/Markdown export and delete; bulk select pins or archives. **Working
now** shows live runs. Delete and **Prune** always preview the exact sessions
first and refuse if anything changed since. Exports and inspection are redacted.

**Profiles** (`/profiles`): create, clone and rename preview first; delete
requires typing the profile ID and moves its home to trash; Export downloads a
credential-safe JSON file; **Open chat** goes to the profile's stable session.

## omp

**omp** (`/omp`) lists live and recent [omp](omp.md) sessions with status,
activity, todos, tokens and cost, and lets you start, resume, steer, queue a
follow-up, cancel a turn and close a session. When `omp` is not installed the
page says so.

## Automation and blueprints

**Automation** (`/automation`, keys `1`/`2`/`3` switch tabs):

- **Kanban:** boards in their configured column order with result, attempt and
  retry state; start a board or stop its dispatcher.
- **Goals:** progress, loop status and verdicts; start, pause, resume, stop; set
  a new goal for a session.
- **Cron:** schedules in plain words with next/last run; run now, pause/resume,
  stop the exact active run, recent runs, create and edit (cron syntax or
  "every 15m", "weekdays at 09:30", with the next three run times shown).

Every action previews against the current revision and is refused if the item
changed. Prompts and objectives are write-only in the browser. An unknown
outcome is never retried automatically.

**Blueprints** (`/blueprints`) shows the catalog with validate and preview;
activation requires retyping the fresh digest.

## Knowledge

- **Skills** (`/skills`): installed skills with source and trust level, and the
  Hermes catalog with install.
- **Memory** (`/memory`): search bounded, redacted summaries with provenance;
  delete requires the exact digest.
- **MCP** (`/mcp`): configured servers with connection status and tools.
- **Nodes** (`/nodes`): paired execution nodes and pending pairing requests.

## Runtime and settings

- **Models** (`/models`): model catalog with context window, output limit and
  price; set the default model (preview then apply). **Providers** shows whether
  each provider has a usable credential (add them with `lemon setup provider`);
  **Routing** edits fallbacks and credential pools with previews, and typed
  confirmation for destructive changes. Credential references are entered in
  password fields and never stored in the page.
- **Usage** (`/usage`): spend and tokens for today, 7 and 30 days (UTC), by
  model, provider and top sessions. Usage is recorded when a run finishes.
- **Diagnostics** (`/diagnostics`): health, versions, capacity, channels, setup
  readiness, the same read-only checks as `lemon doctor`, and the last 200 log
  lines with secrets and paths hidden. Use `lemon doctor --bundle` for a
  support bundle.
- **Settings** (`/settings`): theme, notifications, default model and thinking
  level for new sessions (written to `[defaults]` in `config.toml`), the
  shortcut reference and the operator section. Theme and notification choices
  are stored in this browser only.

## Remote access

Lemon Web binds to localhost in the supported launch path. For remote use,
terminate TLS in front of Lemon (the session cookie is marked `Secure` on HTTPS
requests) and keep the operator token private. Never enable tokenless loopback
compatibility behind a reverse proxy.

## Recovery

| Symptom | What to do |
| --- | --- |
| Login says no operator token is configured | Start Lemon through `lemon web`/`lemon daemon` (managed token) or set `LEMON_CONTROL_PLANE_OPERATOR_TOKEN`, then restart. |
| Token not accepted | Use the token of this runtime; rerun `lemon web` to sign in automatically. |
| "Too many attempts" | Wait a minute before trying again. |
| `Setup needed` | Run `lemon setup`, then choose **Check again**. |
| Web UI does not become healthy | Run `lemon status`, inspect the launcher log, then `lemon doctor`. |
| Port 4080 is occupied | Set `LEMON_WEB_PORT` and rerun `lemon web`. |
| A preview became stale | Review the refreshed state and preview again; nothing was changed. |
| Active-run choices disappeared | The run finished; send the preserved draft as a new message. |

The UI ships its CSS, JavaScript and syntax highlighter inside the release and
needs no CDN. It includes a skip link, labeled controls, visible focus,
keyboard access to every action, live regions for streaming status, and
responsive layouts down to phone width.
