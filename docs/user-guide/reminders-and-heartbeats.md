# Reminders, heartbeats, and the daily brief

Lemon can reach out to you instead of waiting to be asked. Scheduled proactive
features are ordinary cron jobs run by the agent:

- **Reminders** — one-off or recurring messages you set from Telegram with
  `/remind`, or by asking the agent.
- **Heartbeats** — a recurring check-in where the agent works through a
  checklist and only messages you when something needs attention.
- **Daily brief** — an opt-in morning heartbeat, configured by `lemon setup`.

Scheduled work needs Lemon running. On restart, an enabled job catches up once
if its stored slot is within half the gap to its next occurrence, clamped to
2 minutes–2 hours. Catch-up runs have `catch_up: true` in history. Older slots
are audited as skipped; expired one-off reminders are retired, not moved to
next year. Paused jobs stay paused. Set `[automation] catch_up_missed = false`
to disable catch-up.

A paired chat is needed only for chat delivery. Run history retains the latest
100 terminal runs per job, cleaned up hourly; active attempts and pending
retries are never pruned. Configure `automation.run_retention_per_job` to change
that limit.

---

## Where results go

When a scheduled job finishes, Lemon sends the result to one chat, chosen in
this order:

| Job | Delivered to |
|---|---|
| `deliver_to = "none"` | Nowhere. The run is still recorded in run history. |
| `deliver_to = "telegram:<chat_id>[:<topic_id>]"` or `"discord:<channel_id>[:<thread_id>]"` | That chat, topic, or thread. |
| Created from a Telegram or Discord conversation | The chat (and topic/thread) it was created in. |
| Created anywhere else (TUI, browser, CLI) | Your **paired owner chat**: the first `gateway.telegram.allowed_chat_ids` entry when Telegram is enabled, otherwise `gateway.discord.default_channel_id` when Discord is enabled. |
| No owner chat configured | Nowhere. |

The message is the job name followed by the agent's reply. A failed or
timed-out run sends `<job name> (<status>): <reason>` instead.

Most people only need the owner chat. Pair Telegram once and every reminder,
heartbeat, and brief reaches your phone:

```bash
lemon gateway setup telegram
lemon restart
```

See [Setup › Optional Telegram or Discord](setup.md#optional-telegram-or-discord)
for pairing details.

---

## Telegram reminders

In a paired Telegram chat:

```text
/remind 9am stand-up
/remind in 20m check oven
/remind every weekday 8:30 daily brief
```

Lemon replies with the schedule, the next run time, and the reminder id. When
the reminder fires, the agent writes the message (doing any lookup the reminder
asks for) and sends it back to the same chat or forum topic.

Supported `<when>` forms:

| Form | Examples | Repeats |
|---|---|---|
| Relative delay | `in 20m`, `in 2h`, `in 1h30m`, `in 3d` (up to 364 days) | once |
| Time of day | `9am`, `9:30pm`, `21:15`, `at 9am`, `noon`, `midnight` | once — today, or tomorrow if that time has passed |
| Tomorrow | `tomorrow 9am` | once |
| Every day | `every day 8:30`, `daily at 8:30` | daily |
| Weekdays / weekends | `every weekday 8:30`, `every weekend 10am` | weekly pattern |
| Day of week | `every monday 9am` | weekly |
| Interval | `every 30m`, `every 2h`, `every hour` | minutes must divide 60, hours must divide 24 |

A bare number is not a time: `/remind 5 things` is rejected. Use `5am` or
`05:00`. Any unrecognized form replies with the usage text.

Manage reminders for the current chat:

```text
/reminders          # list this chat's reminders, soonest first
/unremind <id>      # cancel one (ids come from /remind and /reminders)
```

`/reminders` and `/unremind` only see reminders created in the same chat or
topic. One-off reminders are removed automatically after they fire.

**Times are the server's local time** — the clock of the machine running
Lemon, including daylight-saving changes. If Lemon runs on a server in another
timezone, write times in that server's zone.

---

## Asking the agent

You can also ask in plain language from any interface: "remind me at 3pm to
call the bank", "every Friday at 5pm summarise this week's commits". The agent
uses its `cron` tool, which supports:

- `schedule: "in 30m"` — a relative one-shot delay (`m`, `h`, or `d`, positive
  integer). The delay is pinned to an absolute instant when saved, not restarted
  when Lemon restarts.
- `schedule: "2027-01-15T09:30"` — an ISO local timestamp in the job's timezone,
  optionally including seconds (`2027-01-15T09:30:45`). Past timestamps are
  rejected. Relative delays and timestamps automatically set `once: true`.
- `once: true` — a one-shot job that runs at its next scheduled time and is then
  removed.
- `timezone` — `"UTC"` by default, `"local"` for the server's local time, or an
  IANA timezone name such as `"America/New_York"` or `"Europe/Paris"`. Named
  zones use Lemon's bundled timezone database, including daylight-saving rules.
  Unknown names or an unavailable database are rejected, not treated as UTC.
- `deliverTo` — override the destination (`"none"`, `"telegram:<chat_id>"`,
  `"discord:<channel_id>"`, or `"auto"` to restore the default).

Jobs created from the TUI or browser are delivered to your paired owner chat.
Ask the agent to list, pause, or remove its scheduled jobs the same way.

Pause, resume, run, remove, and update accept an `id`/`jobId`, or a `name` when
no id is supplied. Names match exactly, ignoring case. Unknown or duplicate
names return an error listing candidates; Lemon never chooses among duplicates.
For an update selected by name, put a new name in `patch.name`.

### Quiet scheduled checks

Any prompt job can finish successfully with exactly `[SILENT]` (surrounding
whitespace is ignored) to record its run with `suppressed: true` without sending
a chat message or forwarding a session summary. For example, ask a build check
to reply `[SILENT]` when everything is healthy and explain failures otherwise.
Failures are never suppressed, and output such as `Build says [SILENT]` is
delivered normally. This does not apply to operator shell-command output.
Heartbeats also keep their existing exact `HEARTBEAT_OK` convention.

### Timezones and daylight-saving changes

The schedule's fields match the chosen zone's calendar and wall clock. For
example, `0 9 * * *` in `America/New_York` runs at 09:00 New York time:
13:00 UTC in summer and 14:00 UTC in winter. Next-run timestamps represent
the actual UTC instant, not a wall clock mislabeled as UTC. Changing only a
job's timezone also recomputes its next run.

When clocks jump forward, a missing scheduled time is skipped for that day;
a 02:30 job does not run at 03:30 instead. When clocks fall back, a repeated
scheduled time runs only at its first occurrence. The second occurrence is
never scheduled, even if the first has already passed or Lemon starts between
the two. These rules also apply to server-local schedules. Lemon does not
change the server's timezone or `TZ` environment variable to evaluate jobs.

An ISO one-shot in a missing spring-forward time is rejected rather than moved
to another time. A repeated fall-back timestamp resolves to its first instant;
if that instant is already past, validation rejects it. Saved one-shot
timestamps are absolute instants, so changing their timezone does not move them.

Telegram `/remind`, heartbeats, and the daily brief keep using server-local
time unless their underlying job is explicitly changed.

### Product routine admission

An operator can attach a private admission callback to a profile-backed agent
job. The existing cron scheduler checks it before every scheduled, manual,
wake, or retry dispatch. This lets a product enforce the creator's current
account status, workspace governance, bot availability, and spending policy
without creating another scheduler or trusting browser credentials.

First allow the backend's exact origin when starting Lemon:

```bash
export LEMON_CRON_ADMISSION_ALLOWED_ORIGINS=https://bot.example.com
```

Multiple origins are comma-separated. HTTPS is required outside loopback.
For local development, an explicitly allowlisted `http://127.0.0.1:<port>` or
`http://[::1]:<port>` is also allowed. `localhost`, other loopback addresses,
wildcards, HTTP DNS hosts, and redirects are not accepted. The callback URL
cannot contain userinfo, a query, or a fragment. The allowlist is checked again
for each dispatch; removing trust prevents later launches.

The trusted backend provisions a dedicated per-routine token with the
admin-only `cron.admission.set` RPC, then sets the job's private `admission`
configuration using `cron.add` or `cron.update`. That token is stored encrypted
on the controller and read only from its secret store, never environment or
external fallback. No token, secret reference, or callback configuration is
returned by job lists/events/audits or copied into run history. Public job
responses expose only `admissionConfigured`.

The backend receives a read-only admission request bound to the actual job,
profile, routine, creator, workspace, and fixed cron/router run IDs. It must
authenticate the dedicated token, independently check that context, and echo
the exact request context with its decision. A denied decision records a
failed run with outcome `denied`. A timeout, disconnect, malformed/mismatched
reply, missing secret, or untrusted origin records `admission_unavailable`.
Neither outcome submits a router run or creates automatic retries. The next
ordinary scheduled occurrence checks admission again. Jobs without a callback
keep their existing execution behavior.

For a shared Team bot, the backend can project the scheduled creator's current
connector consent and tool policy in the authenticated allow receipt. Lemon
uses that creator's connector list for this invocation—not the profile owner's
default credentials—and intersects tool access with the current profile floor.
An explicit empty connector list attaches none. Only destination-side encrypted
secret references are accepted; the controller never resolves connector tokens.
Execution and private memory keys follow the normal native isolation path.
Every projected invocation needs a fresh core proof bound to its fixed router
run ID; borrowed proofs, missing memory scope, and shared-memory grants fail
closed. The shared native factory validates/stamps the actual profile-built
request before launch. This projection is never accepted from job prompts or
public client metadata.

See the [controller admission API](../../apps/lemon_control_plane/README.md#private-cron-admission)
for the exact integration schema.

## Coding goals and scheduled coding jobs

Goals and prompt cron jobs execute real native coding sessions, with the same
file and shell tools as interactive work. From the CLI or TUI, ask the agent to
create and control them using its `goal` and `cron` tools. Use a concrete task
and verification command, for example:

> Set a goal in this repository: fix the addition bug in arithmetic.py, run
> `python3 -m unittest`, and summarize the change. Start a bounded two-tick loop.

### A bounded goal

The `goal` tool manages the current session's durable objective:

- `set` stores `objective` and `cwd`; cwd defaults to the current coding
  session's directory.
- `start` launches a bounded loop; `max_ticks` limits judge/continuation cycles.
  `run_once` starts one cycle. An optional `model` pins the coding model.
- `status` shows the objective, target directory, loop state, active/last run,
  and last result. `meta.lastResult` records completion status and output.
- `pause` or `stop` disables automatic continuation and cancels the owned run.
  `resume` makes the objective active again; use `start` to execute more work.

The judge checks progress in the goal's directory with read-only tools.
Continuation runs use that same directory. A failed or ambiguous run does not
silently start another editor: unknown completion remains under reconciliation
until the original run is terminal. Loops do not enable automatic restart by
default.

### A scheduled coding task

Ask for a `cron` job with `prompt`, `schedule`, and an optional `cwd` and `model`.
For example:

> Create a disabled cron job in this repository to fix arithmetic.py and run
> its Python tests. Use gpt-6.1-sol and no chat delivery, then run it once now.

The tool's `add` action inherits the current coding directory unless `cwd` is
specified. The directory is persisted, so daemon cwd and future interactive
sessions do not redirect the job to another repository. You can update it
explicitly. Prompt jobs run in separate conversation sub-sessions; their
completed summaries and router run IDs remain in `cron` → `runs` history.

- `run` executes a job immediately, including a disabled job.
- `pause` disables future scheduled launches; `resume` enables them again.
- `abort` takes the **cron run ID**, not the job ID, and stops an active run.
  Pausing a schedule alone does not cancel work already in progress.
- `runs` reports progress, output, and the underlying router run ID.

`maxRetries` applies to definite scheduled-run failures with bounded backoff.
Manual runs are single-shot. A timeout or lost acknowledgement is not proof of
failure: Lemon retains the fixed run ID and reconciles completion rather than
launching a duplicate coding session.

These jobs edit the target directory directly; they do not create or merge Git
worktrees automatically. Point `cwd` at a dedicated worktree when other agents
or people are editing the same repository.

---

## Heartbeats

A heartbeat is a recurring job for an agent's main session: the agent runs the
prompt you give it and reports back only when something needs attention. Keep
the checklist in `HEARTBEAT.md` in the assistant workspace
(`~/.lemon/agent/workspace/HEARTBEAT.md`), one line per thing worth checking —
failing CI, unanswered messages, tomorrow's calendar — and point the prompt at
it.

The reply rule (the default `HEARTBEAT.md` template spells it out for the
agent):

- If nothing needs your attention, the agent replies exactly `HEARTBEAT_OK`.
  That run is marked **suppressed**, kept in run history, and **not** sent.
- Any other reply, and any failed run, is delivered like any other job result.

Set a heartbeat from the TUI (`/hb` is an alias):

```text
/heartbeat every 30m check HEARTBEAT.md and tell me only what needs attention
/heartbeat status
/heartbeat pause
/heartbeat resume
/heartbeat clear
```

Setting a heartbeat again updates the agent's existing heartbeat job. It runs
in the server's local time and is delivered to your paired owner chat.

Intervals must be cron-exact: minutes that divide 60 (`1m` … `30m`), hours that
divide 24 (`1h`, `2h`, `3h`, `4h`, `6h`, `8h`, `12h`), or `1d` (daily at 09:00).
Values such as `90m` or `5h` are rejected, and the minimum is `1m`.

---

## Daily brief

The daily brief is a heartbeat that runs once a day in the default agent's main
session. The agent follows `HEARTBEAT.md` if present, then sends a few bullets:
today's reminders and scheduled jobs, anything due from memory, and open
follow-ups. On a day with nothing worth saying it replies `HEARTBEAT_OK`, so
you get no message.

`lemon setup` offers it (default: off) and asks for a time. For scripted
installs:

```bash
lemon setup --non-interactive --daily-brief 07:30
```

Either way the choice is written to your config:

```toml
[automation]
daily_brief = "08:00"   # HH:MM, 24-hour, server-local time
```

The brief is reconciled when Lemon boots, so a change takes effect at the next
start (`lemon restart`). To turn it off, remove the `daily_brief` key and
restart; the job is removed. See [Configuration](../config.md#automation).

---

## See Also

- [`docs/user-guide/setup.md`](setup.md) — setup wizard and Telegram/Discord pairing
- [`docs/config.md`](../config.md#automation) — the `[automation]` section
- [`docs/user-guide/cli.md`](cli.md) — CLI and session commands
