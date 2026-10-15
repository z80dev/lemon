# User questions: `ask`

`ask` requests a real user decision. It is advertised only when a session has a
bound prompt surface, or the run's ACP client negotiated form elicitation and is
still connected. Headless sessions do not silently choose an answer.

```json
{
  "questions": [
    {
      "id": "approach",
      "question": "Which approach should I use?",
      "options": [{"label": "Small change"}, {"label": "Full refactor"}],
      "recommended": 0
    }
  ],
  "timeout_ms": 120000
}
```

A call accepts 1–8 questions with unique IDs. Each question has `id`, `question`
and `options`. An empty options list requests free text. Optional `header` and
option `description` supply explanatory text. `multi: true` allows multiple
choices. `recommended` is a zero-based hint, never permission to auto-select.
`timeout_ms` is an optional positive deadline; native prompts otherwise wait
until answered, cancelled or disconnected. ACP retains its existing default
five-minute client-request deadline when no override is supplied.

The tool returns actual selected labels and/or custom text in `details.results`,
with `status: "answered"`. Decline, cancellation, deadline, unavailable surface
and invalid answers return error results with no fabricated selections.
Do not use `ask` to request credentials or secrets.

## TUI

The TUI binds its authenticated live connection to the logical session before
submitting a native chat. Questions arrive in a focused panel for that session:

- **Single choice:** arrows move the cursor; Enter selects it explicitly.
- **Multiple choice:** Space toggles choices; Enter advances after a selection.
- **Custom answer:** press `o` to type a custom answer, then Enter.
- **Free text:** an empty options list opens the text input directly.
- **Decline:** Escape or Ctrl+C declines the entire call, including any earlier
  answers in a multi-question form.

Timeouts do not send an answer. The server dismisses the panel on resolution or
cancellation. A refused or unconfirmed answer remains actionable instead of
silently hiding a still-blocked tool. Prompt bindings and pending UI are not
restored across daemon/connection loss; loss cancels the wait without answering.
A later chat binds the new connection again. Nothing is queued offline.

## Runtime port and control plane

`CodingAgent.Session.UserPrompt` is the session-level port. Bind a live surface
with `bind(session_key, connection_pid)`, call
`request(session_key, run_id, questions, timeout_ms: ..., signal: ...)` from a
tool, and resolve against the exact prompt/session/run/connection identities.
The owner monitors both surface and waiter processes and serializes terminal
transitions. Repeated or stale answers cannot consume another prompt. This
state is volatile; it is neither a second session journal nor an approval store.

The authenticated WebSocket methods are `sessions.prompt.bind` (optional
`enabled: false` unbinds) and `sessions.prompt.resolve`. Both require operator
write authority and use the actual `ctx.conn_pid`, never a request-supplied PID.
`session.prompt.requested` and `session.prompt.resolved` use the normal event
bridge, like execution approval events. Requested events include the question
form; resolution events include identities/status only, not answer text.
This does not install once/session/global tool approval grants.

ACP continues to use negotiated `elicitation/create` without depending on the
native prompt port. Telegram and Discord were intentionally not changed:
their execution-approval replies carry approval decisions, not generic bounded
question answers, so neither adapter binds a question surface. Channel and
unattended sessions remain unavailable unless a real surface is explicitly bound.
