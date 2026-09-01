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
set. The source `../../bin/lemon --daemon` and installed `lemon daemon`
launchers instead create a port-scoped operator credential at
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

- Streaming markdown transcript committed to native terminal scrollback
  mid-stream (pi-tui `FinalizableBlock` seam), 30fps grapheme-safe reveal.
- Tool cards with per-tool formatters (bash, read, edit + diffs, grep, write,
  patch, find/glob/ls, web, todo, task, process), lifecycle states, shelf
  merging of consecutive completed tools, and collapsible reasoning sections.
- Exec approval panel (allow once / session / always / deny, number
  quick-pick, wrapped command preview, expiry countdown).
- Four submission modes while the agent is busy: `queue` (client-side,
  editable), `steer`, `redirect`, `interrupt` — with graceful fallbacks. Redirect
  replaces pending model direction while preserving completed tool work. Interrupted
  replies keep their partial text.
- Multi-session: Ctrl+X switcher (live + recent, fuzzy filter, new-with-
  prompt, close), per-session drafts, unread badges, history hydration.
- Durable session lifecycle: `/sessions` adds server-backed text, agent,
  pin, and archive filters to the draft-preserving picker; `/session` can
  inspect, resume, title, pin, archive, preview, privately export, prune, and
  delete through the authenticated server-owned lifecycle. Prune and delete
  are preview-confirm workflows, and offline mutations never claim success.
- Ctrl+O model picker (two-stage, draft-preserving), capability-aware slash commands with
  autocomplete, `!cmd` shell escape, `{!cmd}` inline interpolation,
  Ctrl+G `$EDITOR` handoff.
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
- Progressive-disclosure status bar (model + context gauge pinned), git
  branch, connection state, session counters.
- Dark/light themes with OSC 11 terminal-background auto-detection; mouse
  support in overlays.

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
| `/agents`, `/tasks` | Show the Lemon agent directory and active/recent subagent tasks. |
| `/compress` | Compact the current session through `sessions.compact`. |
| `/heartbeat every 10m <prompt>`, `/hb ...` | Persist one recurring prompt in the current conversation; `/heartbeat status`, `pause`, `resume`, and `clear` manage it through `sessions.heartbeat`. Due ticks wait for idle and queued user input wins. |
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
| `/blueprints [bundle-id filter]` | Browse bounded catalog IDs/counts, then inspect the selected entry through the shared authenticated service. |
| `/blueprint [help\|list\|inspect\|validate\|preview\|activate] …` | Inspect and validate content-free metadata, preview one profile without mutation, or activate only after a fresh exact digest match. Refused/stale plans preserve the profile draft and never queue offline. |

Use `/quit` (or the existing keyboard exit binding) to leave the TUI. `/clear`
remains visual-only: it clears terminal scrollback and the rendered transcript
without resetting daemon-side session history. Use `/reset` when history should
also be forgotten.

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

Session list, status, picker, and error views intentionally render lifecycle
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
scripts/         build-binary.ts (bun --compile, per-platform artifacts)
```

### Render-contract notes

pi-tui's append-only scrollback contract is unforgiving; before editing
components read `~/dev/oh-my-pi/docs/tui-core-renderer.md` (or the pi-tui
README) and keep to the house rules: return the same array reference from
`render(width)` when unchanged; never exceed `width` (measure with
`visibleWidth`, never `.length`); never declare a settled row that could
still change; animate via `requestComponentRender` only; `initTheme()`
before constructing any component.

### Releasing

The release workflow cross-compiles `lemon_tui` artifacts for linux-x86_64,
linux-arm64 and darwin-arm64 via `scripts/build-binary.ts` and ships them in
`manifest.json` alongside the runtime tarballs; `install.sh` and
`lemon update` stage both atomically. The three `@oh-my-pi/*` packages are
exact-pinned and must be bumped together (upstream releases in lockstep).
