# Session heartbeats

A session heartbeat runs one recurring instruction inside an existing Lemon
conversation. Use it for work that should retain the current transcript and run
only when that session is otherwise idle—for example, "review the build queue
and report meaningful changes every ten minutes."

This is not cron. Cron owns independently scheduled jobs and normally launches
an isolated run. A session heartbeat belongs to one live, durable coding session
and uses that session's current provider, model, tools, approvals, transcript,
compaction policy, and provider prompt-cache path.

## TUI commands

```text
/heartbeat every 10m review CI and open pull requests
/heartbeat 2h summarize meaningful project changes
/heartbeat status
/heartbeat pause
/heartbeat resume
/heartbeat clear
```

`/hb` is an alias. `off` and `stop` are aliases for `clear`. Supported interval
units are seconds, minutes, hours, and days; the minimum interval is 60 seconds.
Setting a heartbeat replaces the previous instruction and resets its fire
count.

## Runtime behavior

- The heartbeat is persisted in the session JSONL file and restored when that
  exact session is reopened.
- A due tick waits for the agent to become idle. Real queued user input wins.
- Multiple elapsed ticks coalesce into one turn rather than flooding the queue.
- Lemon persists the fire count and timestamp before provider dispatch.
- Pausing keeps the prompt. Resuming starts a fresh interval from the resume
  time, so old elapsed time does not fire immediately.
- Clearing writes a durable tombstone. Reset clears the old heartbeat before
  rotating to a new session identity, and refuses to rotate if that tombstone
  cannot be saved.
- The injected turn explicitly tells the agent not to invent work when nothing
  meaningful changed.

Heartbeat prompts are ordinary user turns and therefore appear in the session
history once fired. The admin status API also returns the configured prompt;
do not put credentials or secret values in it.

## Control-plane API

`sessions.heartbeat` requires the `admin` scope. It accepts the logical session
key used by the TUI; the runtime also accepts a persisted session ID. If more
than one live session claims a logical key during handoff or recovery, the call
fails with a conflict.

```json
{
  "sessionKey": "agent:default:project",
  "action": "set",
  "intervalSeconds": 600,
  "prompt": "review CI and report meaningful changes"
}
```

Actions are `status`, `set`, `pause`, `resume`, and `clear`. `status` is the
default. The response includes `configured`, `status`, `prompt`, interval and
fire-count fields, plus the next scheduled time for an active heartbeat.

## Elixir API

```elixir
{:ok, status} = CodingAgent.Session.heartbeat_set(session, "review CI", 600)
{:ok, status} = CodingAgent.Session.heartbeat_status(session)
{:ok, status} = CodingAgent.Session.heartbeat_pause(session)
{:ok, status} = CodingAgent.Session.heartbeat_resume(session)
{:ok, status} = CodingAgent.Session.heartbeat_clear(session)
```

Frozen/ephemeral context sessions reject heartbeat mutations because they have
no durable session file to restore.

## Verification

Run the deterministic live path from the umbrella root:

```bash
MIX_ENV=test mix run scripts/live_session_heartbeat_smoke.exs
```

The smoke starts real Lemon OTP applications, restores an overdue session,
proves that the logical TUI key resolves a different persisted ID, dispatches
one recurring user turn through the normal agent/provider stream, exercises the
control-plane lifecycle, and reloads the JSONL file to prove the clear
tombstone. Its proof is written under `.lemon/proofs/` and contains hashes and
status metadata rather than prompts, provider responses, or credentials.
