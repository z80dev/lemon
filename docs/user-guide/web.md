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
choose **Stop** to request cancellation. Session identifiers are available
under **Session details** when debugging, but are hidden during ordinary use.

Each browser tab gets its own stable session in `sessionStorage`. Use
`/sessions/<session-key>` only when deliberately attaching to a known Lemon
session.

## Access control

The Web UI binds to localhost in the supported local launch path. To require a
token as well, set a high-entropy `LEMON_WEB_ACCESS_TOKEN` before starting
Lemon. `lemon web` passes URL-safe configured tokens to the browser for the
one-time login; the client removes the query parameter after the authenticated
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

The UI ships its CSS and Phoenix client assets inside the Lemon release. It
does not require a JavaScript or CSS CDN at runtime. The page includes a skip
link, labeled status regions, keyboard focus states, responsive layouts, and
live announcements for streamed activity and errors.
