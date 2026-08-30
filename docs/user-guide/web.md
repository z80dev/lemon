# Use Lemon in a Browser

Last reviewed: 2026-08-30

The full Lemon runtime includes a local browser interface. The launcher starts
the daemon when needed, waits for the Web UI to become healthy, and opens the
page:

```bash
lemon web
```

For scripts, SSH sessions, or when you only want the address:

```bash
lemon web --no-open
```

The default address is `http://127.0.0.1:4080/`. Set `LEMON_WEB_PORT` before
launch to choose another port. A source checkout uses the same command with the
repository wrapper:

```bash
./bin/lemon web
```

`lemon web` requires the `lemon_runtime_full` release profile. If the launcher
reports that the Web UI is unavailable in the minimal profile, reinstall with
`LEMON_PROFILE=full`.

## First run

The page uses the same setup-readiness contract as `lemon setup` and the TUI.
It checks for:

1. a Lemon config;
2. secure secret storage; and
3. a matching default provider/model with a usable credential.

When any item is missing, the page explains exactly what is pending and keeps
the prompt and file-upload controls disabled. It does not persist uploads or
start a doomed agent run. In a terminal, run:

```bash
lemon setup
```

Then choose **Check again** in the browser. Config and secret changes made by a
running Lemon process also refresh the check automatically. If setup still does
not become ready, run `lemon doctor` and follow its recovery guidance.

## Chat and active runs

Once the page shows **Ready**, enter a prompt or attach up to five files (20 MB
each). Responses and tool activity stream into the page. While a run is active,
the composer switches to text-only active-run controls:

- **Follow-up** queues a separate turn after the current run finishes.
- **Steer** adds guidance to the current run without replacing its direction.
- **Redirect** replaces the pending direction while preserving tool work that
  has already completed.

The page discovers active work when a named session is opened, rechecks the
same shared router state before submitting guidance, and keeps the draft if the
run ended in the meantime. A successful message confirms what was requested;
a refused request uses a bounded explanation and never displays node
credentials, remote paths, or internal runtime terms. Choose **Check status**
to reconcile the controls manually or **Stop** to request cancellation of the
actual active run. Session and run identifiers remain hidden during ordinary
use and are available under **Session details** only when debugging.

Each browser tab gets its own stable session in `sessionStorage`. Use
`/sessions/<session-key>` only when deliberately attaching to a known Lemon
session. Named routes reload durable prompt, tool, and answer history before
subscribing to new streaming events, so an existing conversation can be
continued rather than merely reused as an empty routing key.

## Manage durable sessions

Set `LEMON_WEB_ACCESS_TOKEN`, launch the full runtime, and open `/manage` with
the token once:

```text
http://127.0.0.1:4080/manage?token=<your-token>
```

The server validates the token, stores only a derived signed-session marker,
and redirects to the same address without `token` before rendering the page.
The management page then shows local runtime health, live named-node names, and
durable-session counts. From there you can:

- search session keys, titles, prompts, and answers, then filter active,
  archived, or all sessions;
- add a title, pin important work, archive completed work, and resume a chat;
- inspect redacted prompts, answers, and structured tool activity;
- download bounded, redacted JSON or Markdown exports; and
- preview and confirm pruning of archived, unpinned sessions older than a
  chosen threshold.

Prune never accepts a count-only confirmation. The preview token binds the
threshold and exact candidate identities plus their current lifecycle state.
If any candidate changes, no deletion occurs and the page asks for a fresh
preview. Export and inspection omit raw run records, raw event payloads,
credentials, and secret values and report any size-bound run omissions.

This is the first management vertical, not yet a complete machine dashboard.
Provider credentials/fallback pools, approvals, automation, skills/MCP, memory,
logs, and configuration still use their existing CLI/TUI/control-plane
surfaces.

## Access control

The Web UI binds to localhost in the supported local launch path. To require a
token for chat as well, set a high-entropy `LEMON_WEB_ACCESS_TOKEN` before
starting Lemon. The management surface always requires this token and returns
HTTP 503 when it is not configured. `lemon web` passes URL-safe configured
tokens to the browser for the one-time login; the server consumes the query
parameter with an immediate token-free redirect after the authenticated
session cookie is established.

For a remote deployment, terminate TLS in front of Lemon and require the token.
Do not expose an unauthenticated HTTP listener to an untrusted network.

## Recovery

| Symptom | What to do |
| --- | --- |
| `Setup needed` | Run `lemon setup`, then choose **Check again**. |
| Provider or model remains pending | Run `lemon setup provider`; use `--skip-verify` only when deliberately offline. |
| Web UI does not become healthy | Run `lemon status`, inspect the launcher log, then run `lemon doctor`. |
| Port 4080 is occupied | Set `LEMON_WEB_PORT` to an unused port and rerun `lemon web`. |
| Minimal-profile error | Reinstall with `LEMON_PROFILE=full`. |
| Browser did not open | Use `lemon web --no-open` and open the printed URL manually. |
| HTTP 401 | Launch through `lemon web` with the same `LEMON_WEB_ACCESS_TOKEN`, or supply the token once as `?token=...`. |
| Management HTTP 503 | Set a non-empty `LEMON_WEB_ACCESS_TOKEN`, restart Lemon, and authenticate once. |
| Active-run choices disappeared | The run finished or is no longer eligible. Send the preserved draft as a new message, or choose **Check status** if the run is still active elsewhere. |

The UI ships its CSS and Phoenix client assets inside the Lemon release. It
does not require a JavaScript or CSS CDN at runtime. The page includes a skip
link, labeled status regions, keyboard focus states, responsive layouts, and
live announcements for streamed activity and errors.
