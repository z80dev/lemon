# Agent Client Protocol

Lemon can be launched as an ACP stdio agent by Tern and other ACP clients:

```bash
lemon acp
# Source checkout:
./bin/lemon acp
```

The launcher probes the local control plane and reuses a healthy daemon. If
needed, it starts the daemon using the same managed credential and lifecycle
path as the TUI. The stdio process is only a duplex client of that runtime: it
never starts a second router, scheduler, or session store. Runtime logs stay in
the daemon log; launch diagnostics go to stderr. Stdout contains only ACP JSON.

See [Lemon in Tern](../user-guide/tern.md) for native chat registration.

## Configure a client

Use a command and argument array, not a shell command string:

```json
{
  "command": "lemon",
  "args": ["acp"]
}
```

Launch in the project directory. ACP `session/new` takes an absolute `cwd`; if a
client omits it, Lemon supplies the original launcher directory rather than the
source checkout. A Tern launch sends the pane directory explicitly. Model keys
and OAuth state are resolved by the existing runtime from Lemon's configuration
and encrypted secret store, not by the spawned stdio process.

`LEMON_CONTROL_PLANE_PORT` selects the runtime (default `4040`). Managed
launchers load the port's operator credential; explicitly managed runtimes can
use `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` or `LEMON_WS_TOKEN`. Credentials are not
passed in argv or ACP messages. The internal `GET /acp/ws` duplex endpoint
requires operator read/write/approval authorization. Tokenless access is
available only under the existing explicit direct-loopback compatibility policy.

## Framing and lifecycle

ACP uses newline-delimited JSON-RPC 2.0. Each nonempty stdin line is one request,
notification, or response to an agent-to-client request. Responses and live
`session/update` notifications are one JSON document per stdout line. Empty
lines are ignored and malformed JSON receives `-32700`.

For example, this negotiates capabilities against the real runtime:

```bash
printf '%s\n' \
  '{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":1}}' \
  | lemon acp
```

Interactive clients keep stdin open. `session/prompt` streams updates before
its final response. Clients answer `session/request_permission` and filesystem
requests with ordinary JSON-RPC responses carrying the request's id. A pending
permission does not prevent receiving cancel or other control messages.

Prompt turns wait up to ten minutes by default; clients can override the bounded
wait through `_meta.lemon.timeoutMs`. The `/compact [instructions]` command
compacts the idle native session, retaining the durable transcript. Session
load/resume replay persisted native messages and tool history; close cancels an
active turn and retains the session for later resume. Fork creates a durable
branch rather than a new empty chat.

Lemon advertises `/plan`, `/compact`, `/context`, file-defined slash commands
for the session's cwd, and `/skill:<key>` for workspace skills through
`available_commands_update`. `/name args` is submitted verbatim and expanded by
the native executor; `/skill:<key> task` asks the agent to load that skill and
is rejected if the skill is not available in the workspace.

Session configuration exposes model selection (from the runtime's availability
catalog, honoring credential and provider-health constraints), thinking level and
approval policy. Lemon advertises no session modes: plan mode is a `/plan`
command, not a selectable mode. Approval choices cannot override administrator
restrictions. Existing local provider credentials
use the `agent` authentication method. Image/audio/embedded resources and
client-provided MCP transports are rejected unless actually supported by the
negotiated capabilities.

### Plan mode

Plan mode follows omp's `/plan` workflow. `/plan` toggles it for the native
session; `/plan <request>` turns it on (if needed) and sends the request as the
first planning turn. Toggling is refused while a turn is running.

While plan mode is on the working tree is read-only: only read-only tools run
(read, search, web fetch/search, questions), and every other tool returns a
plan-mode error. The agent drafts `<slug>-plan.md` in a session-private plan
directory outside the project—the only place `write`/`edit` may change, always
on the Lemon host rather than through client filesystem methods—and calls
`propose_plan` when the plan is decision-complete.

The proposal arrives as a `session/request_permission` card titled
**Approve plan: …** showing the plan Markdown (Tern shows it as a dialog), with two
options: **Approve and execute** turns plan mode off, restores full tool access
and lets the agent implement the plan in the same turn; **Refine plan** keeps
plan mode on so you can reply with feedback. Approval is never remembered for
the session. The approved plan stays in the native session's context through
restarts and compaction. Sending `/plan` while planning exits without approving
or executing anything.

An explicitly configured `[model_roles] plan = "provider:model"` (or another
`@role` alias) selects the planning model on entry. Without that mapping, plan
mode keeps the current model. Approval or an explicit exit restores the model
that entered planning, including after a saved session is resumed; in-run
approval uses that restored model for the next execution response.

### Connection-owned tools

When the client advertises terminal support, foreground non-PTY bash can use
its `terminal/create`, `output`, `wait_for_exit`, `kill`, and `release` methods
with an explicit shell argument vector. PTY and background processes remain
in Lemon's local process manager. Client terminal snapshots are bounded to
1 MiB; a truncated tail is identified as such, not presented as a complete
artifact. Fully retained output can use Lemon's existing artifact spill path.

Supported client-provided stdio/HTTP/SSE MCP servers are bound to the ACP
connection's session. Their command arguments, environment values and headers
are not persisted with durable session metadata. Close or disconnect cleans
up the connection-owned clients; load/resume/fork can supply fresh server
configuration.

Human permission requests use the approval's lifetime, rather than a generic
60-second machine-RPC deadline. Turn timeout, requester cancellation or
disconnect withdraws pending client requests with `$/cancel_request` so native
dialogs cannot remain stranded. Permission cards share the native tool id and
bounded preview data with their corresponding tool call.

`session/cancel` cancels the session's active turn. `$/cancel_request` maps the
original prompt request id to its session and cancels that turn, waking any
pending client callbacks. Stdin EOF closes the connection and cancels active
turns, without stopping the daemon or deleting durable sessions. Short piped
requests are drained before exit. Transport failures exit `1`; invalid CLI
arguments exit `2`; clean EOF exits `0`.

Session creation/fork bootstrap updates are delivered after their result so
clients know the session id before processing updates. History replay on load
is delivered before the load result. Use the capabilities returned by
`initialize` as the authoritative supported feature set.

## Rich session updates

Lemon maps runtime events to ACP text/thought chunks and tool calls. Tool calls
begin with `tool_call` and advance through `tool_call_update`; editor locations
use absolute paths. Small complete file changes use typed ACP diff content
(up to 16 KiB per side); larger changes use a bounded textual preview. Tool
text previews are bounded to 4 KiB and raw previews share a 32 KiB bound.

Usage with a known context window is exposed as `usage_update`; accounting
without a known window uses vendor metadata instead of inventing a context
percentage. The context gauge measures the latest request's input, cached
tokens and output—not the sum of every request in a tool-heavy turn. Turn usage
and cost totals aggregate the assistant responses separately. Context limits
are model- and provider-surface-specific; the Codex and direct OpenAI versions
of a model need not have the same window.

`/context` shows the session's context-window usage by category—system prompt,
tool definitions, skills, context files (AGENTS.md/CLAUDE.md and assistant-home
files), memory (USER.md/MEMORY.md, contributed context, automatic recall),
user/assistant messages, tool results and summaries—with free space, the
auto-compaction threshold and the largest contributors. It uses the same
`sessions.context` accounting as the TUI and CLI and also emits a `usage_update`
carrying the breakdown under `_meta.lemon.context`. The total is the
provider-reported size of the latest request (plus estimates for newer
messages); category splits are ~4 characters/token estimates scaled to it.

Plans preserve task priorities and completion state and come only from the
selected branch's todo journal, including on load, resume and fork. An unreadable
journal plan emits a warning without clearing the last known plan; historical
tool receipts, reminder events and auto-clear hints cannot replace journal truth.
A successful empty journal write clears a nonempty plan. Native subscriptions
initialize from existing journal plans (including explicitly cleared plans), but
pristine branches do not enqueue an empty snapshot and unchanged lists do not
produce duplicate live plan events.

Retry, compaction and subagent lifecycle events use native notices, compaction
and subagent updates. The runtime preserves message and tool ids so a client can
append streams and update cards rather than duplicating them.

Cancelled tools retain their actual terminal receipt and any real partial output
in ACP, terminal and web history. Unknown mutation outcomes stay explicitly
unknown; a missing receipt is not replayed as a successful operation or as a
new live tool. Retained finalized answers can fill a missing native transcript
suffix only when the exact prompt and recorded turn interval match uniquely.
Recovery stays within that turn and never rewrites the native journal.

Clients advertising `clientCapabilities.elicitation.form` receive an `ask` tool
while their run's client bridge is connected. It issues the native
`elicitation/create` form request with `requestedSchema`, choices and an optional
custom answer. Accepted answers are the user's actual selections; decline,
cancel, disconnection and timeout never select a recommendation automatically.
ACP clients without form support do not advertise `ask` unless a separate
session-level prompt surface is bound. The TUI uses that native prompt port;
see [user questions](ask.md).

Negotiated client filesystem support lets model-facing coding tools read and
write editor-managed text buffers through the existing ACP client bridge. Raw
client capability blobs and editor contents are not copied into management
projections. Unsupported media or MCP capabilities must not be inferred from
registration: inspect the negotiated capabilities.

## HTTP integration

`POST /acp` remains a single request/response endpoint for JSON-RPC requests or
batches. It cannot round-trip client requests or stream notifications; use
`lemon acp` for interactive integrations.

The HTTP endpoint's optional `LEMON_ACP_API_TOKEN` (or application setting
`:acp_api_token`) is independent of the internal runtime operator credential.
When configured, send it as `Authorization: Bearer <token>` or `x-api-key`.

The obsolete `scripts/lemon_acp_stdio.exs` runtime-boot script is removed. Client
configurations must use `lemon acp`; there is no second runtime or fake runtime
mode in the stdio agent.
