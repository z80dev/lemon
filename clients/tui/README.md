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
set. For a persistent daemon, start `../../bin/lemon --daemon` separately with
the token, then launch the TUI with the same token; the launcher never stops an
already-running runtime.

To attach to a persistent or already-running daemon, set the same
`LEMON_CONTROL_PLANE_OPERATOR_TOKEN` in both launch environments. The launcher
cannot recover an existing process's secret and fails closed when it is absent.
The client sends the token only inside the WebSocket `connect.auth` envelope
and does not include it in debug frame summaries. `LEMON_WS_TOKEN` remains a
legacy client-side alias; it does not configure the daemon.

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
- Ctrl+O model picker (two-stage, draft-preserving), capability-aware slash commands with
  autocomplete, `!cmd` shell escape, `{!cmd}` inline interpolation,
  Ctrl+G `$EDITOR` handoff.
- `/skills` live official Hermes catalog browser: category drill-down, fuzzy
  filtering, descriptions, installed markers, and Space-toggle multi-select
  import through Lemon's normal audit/approval flow.
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
gallery; no daemon or credentials are needed for either.

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
