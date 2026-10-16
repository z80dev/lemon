# Lemon command-line reference

The source checkout (`./bin/lemon`) and packaged releases (`lemon`) share the
same command surface. The launcher handles lifecycle commands; all other
commands are dispatched by the CLI registry.

## No-argument behavior

This behavior is identical in source checkouts and packaged installs:

- In an interactive terminal (stdin and stdout are TTYs), including a Tern pane, `lemon` opens the TUI, the same as `lemon tui`. Tern's native ACP chat is opened explicitly with `tern acp lemon` after [registration](tern.md).
- Without a TTY, `lemon` fails immediately with status 2 and points to `lemon -p`, `lemon daemon`, and `lemon --help`. It does not compile, initialize HOME state, or start a daemon.
- `lemon start` starts the runtime in the foreground; `lemon run` runs a prompt.
- `lemon -c` (`--continue`) opens the TUI on the most recently updated TUI session started from this directory (a new session when there is none); `lemon -r [key]` (`--resume [key]`) opens it on `key`, or on the session switcher without a key. `lemon tui --continue`/`--resume`/`--session KEY` are equivalent, and the three are mutually exclusive. Inside the TUI, `/retry` resends the last failed or aborted prompt after a history-only rewind. `lemon run --continue` is separate: it continues the latest *CLI* session for `--cwd`.

Exact TUI resume checks the durable lifecycle key, not a truncated search page.
Local TUI sessions are directory-bound: reopen them from their original directory;
foreign or untagged local TUI keys are safely refused instead of starting fresh
native history under the old key. `/retry` keeps its recovery draft until the
resend is acknowledged. If its outcome is unknown, inspect the session and
explicitly review the fixed request/run identity in Ctrl+Q before sending again;
it is never automatically replayed.

Use `./bin/lemon` instead of `lemon` in the examples below when running from a
source checkout.

Launch from the repository you want to work on. Source compilation runs in the
Lemon checkout, but the TUI and project-scoped CLI commands retain the calling
directory, including on a cold daemon start.
Source build and bootstrap diagnostics, including waits for another compiler,
go to stderr; concurrent JSON commands keep stdout reserved for their result.

### Recent runs in the TUI

`/runs` reads recent terminal run history from `runs.recent.list`. Status is
`completed`, `aborted`, `error`, or `crashed` (abnormal termination without a
completion). If both terminal events exist for one run, the completion wins.
Error labels are redacted and limited to 256 bytes. Unavailable storage produces
`internal_error` with “Run history is unavailable”, not “no runs”.

The API accepts `status`, `agentId`, `sessionKey`, and `limit` (default 50,
maximum 200). Filters apply before the response limit, within the newest 1,000
events of each terminal kind matching the agent/session scope. Summary
`statusCounts` includes crashes; `errorCount` counts only `error`, not aborts or
crashes.
The newest 1,000 scoped `run_started` events supply missing start times (notably
for crashes, which do not carry a duration).

Rows also include nullable `tokens` (`input`, `output`, `total`), `costUsd`,
`priceKnown`, `model`, and `provider`. `/runs` displays available usage without
estimating missing prices. Usage is grouped by run ID from one query over the
returned rows' known time windows, capped at 500 occurrences. If the window
exceeds that cap, usage fields are null rather than partial totals. Missing
records or an unknown start time also produce null fields; mixed models/providers
have a null model/provider, and any unpriced occurrence makes the run's cost null
and `priceKnown` false.

Use `/runs <runId>` for the same per-run timeline as `lemon runs show <runId>`;
`/runs` and `/runs <count>` retain the active/recent list. Run IDs are nonnumeric;
a numeric argument continues to select a list count.

## Channel pairing

```bash
lemon pairing list
lemon pairing approve telegram <CODE>
lemon pairing approve discord <CODE>
lemon pairing deny telegram <CODE>
lemon pairing revoke telegram <CHAT_ID>
```

For channels configured with `unauthorized_dm_behavior = "pair"`, unknown human
DMs receive a single-use code valid for one hour. Confirm the sender's identity
out of band, then approve from the local operator CLI. `list` displays platform,
masked chat ID, name and age, never codes. `deny` consumes without adding access.
Wrong-platform, expired and already-used codes fail without changing config.

These commands reuse/start the local runtime and require operator pairing access
over direct loopback. Approval appends to the user gateway allowlist using the
same patcher as `gateway setup` and applies it to the running adapter, so the
sender's next message is accepted without restarting Lemon. `revoke` removes the
chat from the same allowlist and the running adapter, so its next message is
rejected, including after a supervised adapter restart or daemon restart. An
emptied Discord `allowed_channel_ids = []` stays deny-all; remove the key to
leave channels unrestricted. Project overrides still win after a restart. If the running
adapter cannot be updated, the command exits 1 and says so. Success exits 0,
operation failures exit 1, and usage errors exit 2. No code is echoed in output.
See [channel configuration](../config.md#telegram-and-discord-dm-pairing-codes)
for default behavior, rate limits and lost-code handling.

## Connect an iPhone to Lemon Bot

```bash
lemon connect iphone --backend http://127.0.0.1:8787
# Optional explicit public origin:
lemon connect iphone --backend http://127.0.0.1:8787 \
  --origin https://bot.example.ts.net
```

This is a terminal pairing client for an **already-running Lemon Bot backend**,
not a backend installer or service launcher. `--backend` is required and selects
the intended configured backend; same-machine loopback HTTP is allowed for that
connection. `--origin` must be the exact public HTTPS `publicUrl` configured on
that backend and otherwise defaults to the authenticated descriptor's value:
the backend, not the CLI, chooses the QR origin. Loopback and HTTPS aliases must
prove the same instance and workspace identity. The examples are illustrative,
not a claim that a live origin has been provisioned or verified.

Configure Tailscale HTTPS for the Bot public origin first. The client reuses the
product's HTTPS/public-origin preflight before issuing a link; fix any reported
DNS, certificate, routing, or backend-identity mismatch rather than bypassing
preflight. This command neither configures Tailscale nor starts the Lemon daemon.

If the workspace is uninitialized, complete initial setup and create the local
owner account through the existing Lemon Bot product UI first. At the terminal,
sign in with that existing owner's email and **hidden password**. The client uses
the product login endpoint, keeps its product session only in memory, and attempts
revocation of only that temporary session on exit, leaving other logins and optional
OIDC provider sessions untouched. If revocation cannot be confirmed, revoke that
temporary login in Account → Sessions (normal bounded expiry still applies). Managed sign-in policies
that cannot use this local login must be
handled through the existing product UI/account mechanism, not bypassed. Never
enter an operator/control-plane token. Passwords and sessions must never be put
in command arguments, environment variables, shell history, or persistent files;
there are no credential, authentication-bypass, or automatic-approval flags.

Use a real interactive terminal with stdin, stdout, and stderr attached. Do not
pipe, redirect, record, or run this flow noninteractively: the one-use paste link
printed for the iPhone is sensitive. Paste it only into the intended iPhone's
Lemon Bot connection flow. Review the pending request and compare its exact
request identity, device name and verification code with the phone, then type
`approve <the displayed six-digit code>` to authorize that exact request.
`deny`, an empty line, or any other answer denies it; interrupted input never
approves. Deny unexpected requests. Issuing a link or seeing an approved request
is not success: pairing succeeds only after the phone completes and the request
reaches **consumed** status on the same verified backend/workspace.

Source checkouts run the Bot pairing TypeScript entrypoint using Bun without
requiring the caller's working directory to be the Lemon repository. Packaged
Lemon uses the independently installed standalone `lemon-bot` executable from
`~/.lemon/lemon_bot/current/bot/bin/lemon-bot`, or from `PATH`. Install that Bot
package separately if unavailable; this command never launches its server.

## Commands and availability

### Launcher lifecycle commands

The registry defines their help and completion; the launcher executes them:

| Command | Source checkout | Packaged release | Purpose |
| --- | --- | --- | --- |
| `tui [args]` | Yes | Yes | Reuse a healthy runtime; otherwise run `setup --if-required` in an interactive terminal, start the daemon, and open the TUI. |
| `web [--no-open]` | Yes | Full profile only | Start the daemon if needed, wait for Web UI health, and print its URL; open a browser unless `--no-open` is set. |
| `start` | Yes | Yes | Run the runtime in the foreground. |
| `daemon` | Yes | Yes | Start the runtime in the background and wait for health. |
| `stop`, `restart`, `status` | Yes | Yes | Manage an owned foreground/background runtime, or probe local runtime health. |
| `remote`, `eval EXPR`, `rpc EXPR` | No | Yes | Use release VM remote/eval/RPC tools. |

Source runtime options go after `start`, `daemon`, or `restart`:
`--debug`, `--port N`, `--web-port N`, `--sim-port N`, `--name name@host`,
`--sname name`, `--cookie C`, and `--no-distribution`. For example,
`./bin/lemon start --no-distribution`. Runtime options are accepted after the
relevant lifecycle command, not as bare launcher flags.

All three ports must be integers from 1 through 65535. Environment defaults are
`LEMON_CONTROL_PLANE_PORT=4040`, `LEMON_WEB_PORT=4080`, and
`LEMON_SIM_UI_PORT=4090`; source `status` and `stop` also accept the port flags.
Select the same control port and HOME for every lifecycle command.

`status` exits 0 only when Lemon's control-plane health check succeeds, including
foreground starts. Its first line includes the selected Lemon home; subsequent
lines show the selected web/sim ports and log location. Source daemon logs are
`~/.lemon/run/lemon-PORT.log` (`LEMON_RUNTIME_LOG_FILE` overrides this); release
daemon logs are in `$RELEASE_TMP/log`, defaulting to `tmp/log` under the release.
Foreground logs remain in the starting terminal. For an external runtime,
status labels the home as the launcher's selected home, not the runtime's home.
An unreachable control plane exits 1 even if the recorded process is still alive.

`stop` never signals an unowned process. If another HOME/runtime holds the
control port, `stop` and `restart` fail and ask you to stop it where it runs;
`restart` does not silently reuse it and claim success. Restarting a stopped
runtime starts it without an expected-stop error. A failed daemon health wait
terminates the attempted launch and removes its runtime records.

The authenticated `status` RPC additionally reports `server.profile` (the
launcher's runtime profile, or null when unknown) and `server.default_model`
(the configured model ID, or null when unavailable). It does not expose home
paths or resolve provider credentials.

Authenticated remote clients can call the admin-only `system.restart` and
`system.stop` control-plane methods. They return acceptance before acting; restart
uses the current `LEMON_LAUNCHER`, while stop gracefully shuts down the VM even
without a launcher. These methods cannot start an offline controller. Source
restarts preserve effective distribution name/cookie (or `--no-distribution`);
both launchers inherit the control-plane/web/sim port environment. See the
[system method reference](../reference/control-plane.md#systemrestart-and-systemstop)
for availability, single-flight behavior, and release/custom-launcher limits.


### Headless run and log inspection

```bash
lemon runs --status error --since 1h --limit 20
lemon runs list --session agent:operator:main --agent operator --json
lemon runs active
lemon runs show RUN_ID
lemon runs show RUN_ID --json
lemon cron status --json
lemon cron runs --job JOB_ID --status failed --since 2d
lemon logs -n 50 --level warning
lemon logs --follow --json
```

These commands do not start a runtime or submit work. Select its control port
with `LEMON_CONTROL_PLANE_PORT` and authenticate using the same operator-token
environment as other control-plane CLI clients. An unavailable runtime makes
run queries fail with exit 1 and a `lemon daemon` instruction, not an empty list.
Invalid arguments exit 2.

`runs` defaults to recent history; `active` lists in-flight sessions. Human
tables show UTC time, status, duration, model, cost, session/agent and a short
run ID, plus tokens and error labels when the runtime supplies them. Older
runtimes without usage/error fields display `-`. Recent statuses are
`completed`, `aborted`, `crashed`, and `error`; older runtimes may not report
crashes or correctly classify aborts. Recent client-side time filtering examines
at most the newest 200 history rows returned by the runtime, not an unbounded
archive. `--since` accepts positive integer minutes (`30m`), hours (`1h`), or
days (`2d`), relative to invocation time; list limits are 1–200 (default 50).

`runs show <runId> [--json]` shows what one run did: loop/turn and answer-finalize
events, tool calls paired with their completion, and child subagents. Human output
uses times relative to the first displayed entry, recorded durations and
`[ok]`/`[fail]` markers; an unmatched tool dispatch stays `[pending]`, not successful.
Available run usage is included. The latest 500 entries are shown chronologically
from a bounded 1,000-event history window, with an explicit truncation notice.
Labels exclude tool arguments/results and private conversation content.
Unknown/expired runs and failed storage queries are errors, not empty timelines.
See the [timeline method reference](../reference/control-plane.md#runstimelineget).

`cron status` reports job totals, enabled jobs, and `failingJobs` (jobs with a
nonzero persisted failure streak). Use `--json` for the complete cron status
projection. See [cron failure alerts](reminders-and-heartbeats.md#failure-alerts-and-recovery).

`lemon cron list [--failing] [--json]` lists job IDs, names, schedules, enabled
state, next-run timestamps, failure streaks, and last statuses. `--failing` keeps
jobs with a nonzero failure streak. No cron command starts a runtime.

Use `lemon cron pause <id|name>`, `resume <id|name>`, or `run <id|name>` to
disable scheduled launches, re-enable them, or trigger a manual run through the
runtime's normal validation. Names match exactly, case-insensitively; duplicate
names are refused with candidate IDs. Exact IDs take precedence.

`lemon cron remove <id|name>` asks for confirmation. Non-interactive callers
must explicitly pass `--yes`; cancellation never removes the job. The TUI offers
the same management actions with `/cron` (list by default); `/cron remove`
opens a confirmation picker with Cancel selected first.

`cron runs` uses the cron status vocabulary: `pending`, `running`, `completed`,
`failed`, `timeout`, and `aborted`. Without `--job`, it queries each currently
configured job and returns the newest matching rows across those jobs. Deleted
jobs can still be queried by their exact ID. JSON excludes job prompts, command
text, run output, and arbitrary metadata.

`logs` reads the runtime's bounded 1,000-entry ring. If the connection cannot
be established, it reads the launcher log instead: source uses
`~/.lemon/run/lemon-PORT.log`; packaged releases use the newest `erlang.log.N`
under `$RELEASE_TMP/log` (default: the release's `tmp/log`).
`LEMON_RUNTIME_LOG_FILE` selects an explicit file. File reads seek from the end,
read at most 1 MiB, discard a cut first line, include a partial last line, and
credential-redact every returned line. The header names the source without
exposing its raw filesystem path. This is credential filtering, not removal of
all potentially private log text.

`--level` is a minimum severity. Offline, it recognizes bracketed log levels
and excludes lines without a recognizable level. `--follow` polls every two
seconds, uses a timestamp cursor with boundary deduplication online and
overlapping bounded file tails offline; Ctrl-C exits without stopping the
runtime (standard interrupt status 130). More than 1,000 new ring entries or 1 MiB of file data
between polls can be lost. Identical entries at the same millisecond are
deduplicated. JSON follow is a stream of one document per poll, each with
`source` and `logs`; one-shot mode emits one document. A connected runtime's
authentication/query failure remains an error, never an empty/offline success.

### CLI commands

These commands are dispatched by `LemonCli.CLI` in both source checkouts and
packaged releases:

| Command | Availability | Notes |
| --- | --- | --- |
| `run`, `-p`, `--print` | Source and release | Run a coding prompt non-interactively, reusing or starting the local daemon. |
| `setup` | Source and release | `setup --if-required` exits 0 if setup is complete; otherwise runs the wizard and exits 1 if setup remains incomplete. |
| `model`, `gateway`, `doctor`, `config`, `secrets`, `channels`, `providers` | Source and release | Configure or inspect Lemon and its integrations. |
| `blueprints` | Source and release | Starts the local runtime through the launcher if it is not healthy. |
| `profile` | Source and release | `profile chat` starts the local runtime through the launcher if it is not healthy. |
| `backup`, `context`, `sessions`, `learn` | Source and release | Manage backups, bounded context, durable sessions, and learning. |
| `runs`, `cron`, `logs` | Source and release | Inspect runs/logs and manage scheduled jobs; requires a running runtime except for the redacted launcher-log fallback. |
| `omp` | Source and release | Start, watch, steer, and resume omp coding-agent sessions owned by the runtime; starts the local runtime through the launcher if it is not healthy. |
| `update` | Source and release | Release: full managed-update commands; source: `check` and `history` only, while plan/apply/rollback fail closed. Bare or unknown source update forms do not forward to Mix. Use `mix lemon.update` directly for source configuration migration and bundled-skill sync. |
| `completion` | Source and release | Generate completion for the current launcher's available commands. |
| `migrate` | Source and release | Hermes audit/import commands are available under `migrate hermes`. The former Hermes-specific Mix tasks are deleted. |
| `node` | Source and release | `node capabilities --json --require-bot` inspects installed API compatibility without starting a runtime and fails closed when features are absent; `--expected-version VERSION` adds an exact CalVer check. `node join --invite-code-stdin` reads a bounded one-use enrollment or repair code without an operator token. The repository join script prompts with hidden terminal input and reuses a compatible pinned installation or invokes the existing installer. See [attaching a bot machine](attaching-a-bot-machine.md) for publication prerequisites, source/pinned builds, readiness and destination-local credentials. |
| `version`, `--version` | Source and release | `version` prints bare CalVer for scripts; `--version` or `version --verbose` also reports source/release, commit, and build channel. |
| `send`, `media`, `models`, `policy`, `skill`, `usage` | Source and release | Mix-free channel notifications, diagnostics, catalog, policies, and skill management; existing Mix tasks remain thin source adapters. |

The `runtime.build` doctor check reports the same build identity. Source builds
use the umbrella CalVer and current checkout commit. Packaged releases use
metadata stamped at assembly; an older artifact without metadata reports
`unknown` rather than guessing a commit or channel from the updater settings.

`lemon config validate` always lists its global and project configuration files
and finishes with a next step. Malformed TOML and removed settings fail with exit
code 1; `lemon config show` also reports these errors without a stack trace.
Use `lemon config migrate` for removed settings, or fix syntax and rerun
`lemon config validate --verbose`. Unset summary values appear as `(not set)`;
explicit `false` and zero values remain literal. A failing doctor check does not
abort the report; use `lemon doctor --verbose` for details.

`lemon doctor --live [--verbose] [--json]` opts in to bounded, non-generating
connectivity checks for the default provider and configured Telegram/Discord
bots. Without `--live`, doctor remains offline. Live checks run concurrently with
five-second request timeouts and a six-second overall deadline; unsupported
endpoints are skipped, failures exit `1`, and redacted results are included in
JSON and bundles. See [diagnostic details](../support.md#before-opening-a-bug).

Packaged version commands work before setup: they read build identity without
running the runtime configuration providers or creating HOME state.

Clients reusing an external daemon use its existing credential, not a newly
generated token. Set `LEMON_CONTROL_PLANE_OPERATOR_TOKEN` or use the HOME that
owns that daemon. An explicitly configured
`LEMON_CONTROL_PLANE_ALLOW_UNAUTHENTICATED_LOOPBACK=true` runtime can be used
without a credential; the launcher does not silently enable this compatibility
mode.

## Help and exit codes

`lemon <launcher-command> --help` and `lemon help <command>` print help.
Success exits 0, operational failures exit 1, and invalid commands or
arguments exit 2.

`--help`, `-h`, and `help` print command help without running the command body.
Source top-level and command help read the shared registry directly with Elixir,
without Mix compilation, runtime startup, or credential creation. Other source
commands require Elixir 1.19.5+, Erlang/OTP 28.5+, and Mix; lifecycle health checks
require curl. Missing prerequisites produce an installation hint rather than a
misleading stopped-runtime result.
Commands that document `--json` emit JSON on success. Redacted operational
error JSON is supported by the profile, session, blueprint, provider, learning,
and secret-source command families; other commands report errors as text on
stderr. Invalid arguments remain human-readable usage errors.

### Usage and cost reports

`lemon usage` reads the local usage store directly and starts only `lemon_core`,
not the runtime, router, or control plane. With no range or grouping options it
keeps the current diagnostics (today, summary, quotas, and providers).

```bash
lemon usage --days 7 --by model
lemon usage --since 2026-10-01 --until 2026-10-07 --by session
lemon usage --days 7 --by day --json
```

`--days N` includes today and the preceding N−1 UTC dates (1–366, default 1).
`--since` and `--until` are inclusive UTC dates; omitted `--until` is today,
and an omitted `--since` is the end date. Do not combine `--days` with date
boundaries. `--by day|provider|model|session` defaults to provider.
Range/group JSON is the same bounded projection used by `usage.cost`; default
diagnostics JSON retains its fields and adds `report` with that projection.

In the TUI, `/cost 7d --by day` renders daily rows; `/cost month --by model`
and `/cost --by session` show the other breakdowns. Existing `today`, `week`,
`month`, and `Nd` ranges remain supported. The TUI requires a running runtime.

Reports always show `incomplete` and omitted-session counts. Costs are known-cost
subtotals: when pricing is unknown or historical costs lack attribution, a zero
subtotal does **not** mean free execution. The wire projection cannot attribute
unknown pricing to individual breakdown rows, so incomplete reports label all
rows conservatively. Models are capped at 50 and sessions at the top 20 by cost;
session omissions also include the daily ledger's bounded-session omissions.
These summaries are for diagnostics, not exhaustive spend accounting.


## Setup

`lemon setup` prepares configuration and encrypted secrets, onboards a default
provider/model, and checks its credential. A rerun verifies the existing provider
rather than silently trusting the saved key. **Setup complete** requires a passing
live check; `--skip-verify` or an unsupported check is reported as not live-verified.
Declining onboarding leaves pending steps without reporting a failed step.

API-key prompts hide input and restore terminal echo afterwards. Without a TTY,
use explicit non-interactive commands:

```bash
lemon setup --non-interactive --provider openai --token "$OPENAI_API_KEY" \
  --model gpt-5 --set-default --daily-brief 07:30
lemon setup provider --non-interactive --provider openai --token "$OPENAI_API_KEY" \
  --model gpt-5 --set-default
lemon doctor
```

Onboarding's `--model` takes a bare model id, not `provider:model`.
`--daily-brief HH:MM` is opt-in and requires a Telegram chat paired with
`lemon gateway setup telegram`. `lemon setup runtime` re-prompts for invalid
interactive profiles or ports and rejects invalid flags; valid ports are 1–65535.
See [setup and onboarding](setup.md) for the full workflow.

## ChatGPT authentication and Codex CLI login import

`lemon model --provider openai-codex` offers browser OAuth (the default),
a headless device-code sign-in, an existing token, or an explicit **Import
existing Codex CLI ChatGPT login** choice. Lemon never discovers or imports CLI
credentials automatically.

`--auth device` needs no local callback port: it prints
`https://auth.openai.com/codex/device` and a one-time code, polls until you
approve it from any browser, and stores the same login as browser OAuth. It
also runs with `--non-interactive`, for example over SSH:

```bash
lemon model openai-codex --auth device --non-interactive --set-default --model gpt-6.1-sol
```

To copy an existing Codex CLI login instead:

```bash
lemon model --provider openai-codex --auth codex-cli --non-interactive \
  --set-default --model gpt-6.1-sol
# Optionally select a copied login file instead:
lemon model --provider openai-codex --auth codex-cli \
  --codex-auth-path /path/to/auth.json --non-interactive
# First-time setup can import too; defer its separate live verification if offline:
lemon setup --provider openai-codex --auth codex-cli --non-interactive --skip-verify
```

Import reads only the explicitly selected file, otherwise `$CODEX_HOME/auth.json`
when set, otherwise `$HOME/.codex/auth.json`. It requires a ChatGPT OAuth login
with an access-token JWT expiry, account ID, and non-empty refresh token;
API-key-only and incomplete logins are rejected. `codex_cli` is also accepted
as an auth label. `--codex-auth-path` is valid only with this import choice.
`--token` cannot be combined with browser OAuth, device sign-in or CLI import.
Other non-interactive provider setup still requires `--token`.

The copied credentials are encrypted in Lemon's secret store under
`llm_openai_codex_api_key` by default (`model --secret-name` overrides the name).
Config references that name with `auth_source = "oauth"` and `oauth_secret`;
tokens are never written to TOML. Import itself makes no HTTP requests and
never changes the CLI login file. Later credential resolution refreshes the
Lemon copy as needed and persists only Lemon's encrypted secret. A failed
refresh may reuse an unexpired token, but never returns an expired token as
successful authentication. This is a one-time copy, not ongoing synchronization.

## Claude subscription sign-in (Anthropic OAuth)

`lemon model anthropic` (or `lemon model --provider anthropic`) offers
**Sign in with Claude Pro/Max (browser)**, the default, or an API key. Sign-in
runs Anthropic's authorization-code flow with PKCE on `claude.ai`; Claude Code
does not need to be installed.

```bash
lemon model anthropic --auth oauth --set-default --model claude-sonnet-5-5
lemon model anthropic --status   # auth source, account, expiry, usable or not
lemon model anthropic --logout   # delete the stored login and its config keys
```

Lemon listens on `http://localhost:53692/callback` and captures the browser
redirect. If that port is busy, sign-in uses Anthropic's hosted code page
instead: paste the `code#state` value it shows. When the listener is running
but the browser cannot reach it (SSH, containers), wait for the two-minute
timeout and paste the full redirect URL from the address bar. A token printed
by `claude setup-token` may be pasted at the same prompt; it is stored as a
static credential without refresh.

The login is encrypted in Lemon's secret store under `llm_anthropic_api_key`
(`--secret-name` overrides it) and referenced by `auth_source = "oauth"` and
`oauth_secret`. Access tokens last about eight hours; Lemon refreshes them five
minutes before expiry and stores the rotated refresh token. Concurrent sessions
on one runtime share a single refresh. If Anthropic rejects the refresh, or
the rotated token cannot be stored, requests fail rather than falling back to
another credential; sign in again with `lemon model anthropic`. Anthropic ends
a login about 30 days after sign-in regardless of refreshes, so `--status`
shows an estimated re-sign-in date.

With `auth_source = "oauth"`, `ANTHROPIC_API_KEY` is ignored. With
`auth_source = "api_key"` or no auth source, the API key applies and the
subscription login is not used. `--logout` removes `auth_source` and
`oauth_secret`, so API-key resolution applies again. It does not revoke the
grant at Anthropic and does not touch Claude Code's own login.

Requests sent with a subscription token use Claude Code's request shape
(Bearer authorization, `claude-code-20250219` and `oauth-2025-04-20` betas,
the Claude Code user agent and system-prompt identity). Anthropic's terms
govern subscription use in third-party tools; see
[Use the Claude Agent SDK with your Claude plan](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)
and [Claude Code legal and compliance](https://code.claude.com/docs/en/legal-and-compliance).

As of October 2026, Anthropic bills Lemon's subscription requests to the
account's extra usage rather than the plan's included limits. Without extra
usage available, sign-in and `--status` succeed but model requests fail with
"You're out of extra usage. Add more at claude.ai/settings/usage". Lemon does
not forge Claude Code's billing attestation to change that classification.

claude.ai does not list individual OAuth grants. `--logout` deletes Lemon's
only copy of the tokens, and Anthropic ends the grant about 30 days after
sign-in. To revoke every session immediately, use **Settings → Account → Log
out of all devices** on claude.ai; this also signs out Claude Code and browsers.

## Other provider sign-ins

`lemon model <provider>` also offers sign-in for these providers; `--status`
and `--logout` work the same way as for Anthropic and never print credentials.

```bash
lemon model openrouter                 # browser sign-in (default) or paste a key
lemon model xai --auth oauth           # SuperGrok / X Premium+ device code
lemon model kimi-code                  # Kimi Code device code (default)
lemon model zai --auth oauth           # GLM Coding Plan sign-in
lemon model kimi-code --status
```

- **OpenRouter** opens `openrouter.ai/auth` and captures the redirect on
  `http://localhost:54549/callback`; otherwise paste the redirect URL. OpenRouter
  issues a durable API key, stored like a pasted key (`api_key_secret`). Pasting
  an existing `sk-or-` key at the same prompt checks it and stores it.
- **xAI** and **Kimi Code** show a verification URL and code. The refreshable
  login is stored under `llm_xai_api_key` / `llm_kimi_coding_api_key` and
  referenced by `api_key_secret` with `auth_source = "oauth"`; while that is set,
  `XAI_API_KEY`, `KIMI_API_KEY` and `MOONSHOT_API_KEY` do not override it. Lemon
  refreshes the token five minutes before expiry and when the provider rejects
  it. Kimi requests made with the login carry Kimi CLI identification headers.
- **Z.AI** opens `chat.z.ai`. The browser then tries to open ZCode
  (`zcode://zai-auth/callback?...`); copy the full address, including its `state`
  (or paste `code#state`), into the prompt. A bare code is rejected. Lemon
  exchanges it, then finds or creates an API key named `lemon` in your default
  Z.AI project and stores that key.

`--logout` deletes the stored login or minted key and its config references. It
does not revoke anything at the provider; delete minted OpenRouter or Z.AI keys
in their dashboards.

Multiple accounts can be stored under separate `--secret-name` values and
referenced by credential pools. `--status --secret-name NAME` inspects that
account rather than the current default; `--logout --secret-name NAME` deletes
only it and changes provider settings only when they select that exact secret.
Missing/deleted pool secrets are skipped. Sign-in errors report safe error
kinds rather than provider response bodies or credential payloads.

Status and logout distinguish a confirmed missing secret from an unreadable
login. If the encrypted store is unavailable, its journal is corrupt, or the
master key cannot decrypt the login, both commands fail with exit `1` and a
bounded error; they do not delete credentials or edit provider settings.
The selected OAuth authority remains in effect instead of falling back to an
ambient API key. Repair the store or restore its master key before retrying.
A confirmed missing secret still allows logout to remove stale settings for
that selected account; a missing named account never clears another account's
settings.

## Non-interactive coding

```bash
lemon -p "Explain this repository"
echo 'list files' | lemon -p --output stream-json
lemon run "Fix the failing parser" --cwd ./project --model openai-codex:gpt-6.1-sol \
  --approval-policy allow --output json | jq .
lemon run "Continue the fix" --continue
lemon run "Review the changes" --session agent:default:cli-SESSION
```

With no prompt argument, `run` reads stdin to EOF. A prompt argument is used
as-is (stdin is not read). Empty prompts and invalid options exit 2. A fresh
run creates a durable, isolated session. `--continue` resumes the most recently
updated CLI session for the current `--cwd`; `--session` selects an explicit
session key. The two flags are mutually exclusive.

`--output text` (default) prints only the final answer. `json` prints one
result document with `ok`, `answer`, `error`, `run_id`, and `session_key`.
`stream-json` prints newline-delimited JSON: an `init` record, run-scoped
`event` records containing control-plane event names and payloads, and a final
`result` record. Stdout and stderr use UTF-8 even under an ASCII shell locale,
so non-ASCII JSON strings remain valid. Startup diagnostics stay on stderr. Runs exit 0 only when the
agent reports success; submission, connection, provider, and execution failures
exit 1. Runs are bounded to ten minutes; timeout cancels the submitted run.
Protocol keepalive pings keep long-running tools connected without adding records
to stdout. A lost connection produces a failed result, not a successful fallback
or an automatic re-submission of the prompt.

### Token and estimated-spend stops

The canonical [`[budgets]` configuration](../config.md#cumulative-usage-budgets)
applies to print runs too. `--continue` and `--session` retain cumulative session
spend; each prompt starts a fresh run counter. Clear, rewind, compaction and fork
do not erase prior session spend.

A budget stop exits 1 with a readable `error`. Both `--output json` and the final
`stream-json` result include a `budget` object with `reason: "budget_exceeded"`,
`scope` (`"run"` or `"session"`), `metric` (`"tokens"` or `"cost_usd"`), `limit`,
`used`, `run_usage`, and `session_usage`. The accompanying `usage` includes actual
reported `total_tokens` and estimated `cost.total` for this run, including known
interrupted/retried usage rather than the configured allowance. Zero-cap stops
report zero run usage without calling the provider.

Costs are catalog estimates, not invoices. Final-only provider accounting means
an in-flight response can exceed a positive cap before Lemon stops; unreported
usage cannot be reconstructed. This is not a hard billing cap.
Counters cover the prompt agent loop and its reported retries. Compaction and
project-memory maintenance model calls are not counted; subagent sessions have
their own counters rather than spending the parent's allowance.

Non-interactive mode never waits for a human approval. `--approval-policy deny`
(default) denies requested approvals; `allow` approves each request once.
Existing tool policy still applies. Use `--allowed-tools read,grep,find` and/or
`--denied-tools bash,write,edit` to narrow the run's tool policy. These flags
do not provide OS-level sandboxing. The daemon is reused when healthy and is
started through the normal launcher when absent; the client does not boot a
second router or scheduler.


## Update lifecycle

Managed releases use an explicit preview-confirm flow:

```bash
lemon update check
lemon update plan
lemon update apply --confirm <exact-plan-digest>
lemon update history
lemon update rollback --receipt <exact-apply-receipt> \
  --confirm <exact-rollback-digest>
```

Planning does not mutate disk. Apply re-plans under an exclusive lock, verifies
the schema-2 manifest's exact size/SHA-256 metadata, rejects unsafe archives,
checks the staged launcher's reported version, and writes a private content-free
receipt only after the atomic pointer flip verifies. Rollback is receipt-bound;
it accepts no path and restores no config, credentials, sessions, or stores.
Source checkouts expose check/history but fail packaged plan/apply/rollback
closed. See [Safely update and roll back Lemon](updates.md) for the complete
safety contract and current publisher-signing/network-cap residuals.

## External secret sources

External source diagnostics are available through the same packaged and source
command boundary:

```bash
lemon secrets sources status
lemon secrets sources status --json
lemon secrets sources test
lemon secrets sources test vault --json

# Source checkout
./bin/lemon secrets sources test --source-id vault
```

`status` validates configuration plus executable/bootstrap readiness without
executing the source. `test` runs all enabled sources, or one named source,
under the configured timeout and output bound. Human and JSON responses expose
only source id/type, readiness, provenance, counts, byte counts, duration, and
stable error kinds; they never include secret values. Operational test failure
exits `1`, invalid options exit `2`, and an empty/not-configured selection is an
operational failure.

`lemon secrets check` likewise reports only `present` for resolved entries; it
does not print prefixes or suffixes. External sources remain read-only
fallbacks behind the encrypted Lemon store. See
[External secret sources](../config.md#external-secret-sources) for the exact
configuration and fail-closed resolution contract.

## Portable blueprints

`lemon blueprints` talks only to the authenticated local control plane. It
never accepts a filesystem root or path and never starts a scheduler in the
one-shot CLI VM. Both source and packaged launchers start the local runtime
when it is not already healthy.

```bash
lemon blueprints
lemon blueprints inspect daily-note
lemon blueprints validate daily-note --json
lemon blueprints daily-note --profile operator
lemon blueprints preview daily-note --profile operator --json
```

The bundle-ID shorthand is preview, not activation. These reads return only
the control plane's sanitized projections: IDs/names, content hashes and byte
counts, profile/session target, cron schedule/state, provenance, collision
actions, and cleanup flags. They omit absolute paths, skill bodies, prompt or
command text, and secret values.

Activation requires the exact 64-character `confirmationDigest` from a fresh
preview:

```bash
lemon blueprints activate daily-note --profile operator \
  --confirm <exact-confirmation-digest>
```

The long-running runtime re-plans under the existing blueprint lock before any
write. Content, profile destination, enabled-skill state, or cron collision
changes invalidate the digest. Successful replay reports `unchanged` and keeps
one stable cron job. JSON success is one sanitized document on stdout;
operational failures are one redacted error document on stderr with exit `1`;
invalid CLI arguments use exit `2`. See the
[bundle manifest and safety guide](skills.md#portable-skill-and-automation-bundles).

## Durable sessions

`lemon sessions` is the operator boundary over Lemon's canonical run history,
chat state, policy, and session metadata stores. It does not create another
conversation database. All list and history reads are bounded; history and
exports are always redacted.
Session commands connect to the authenticated running daemon, starting it through
the normal launcher when absent. They read and mutate that daemon's canonical
state, not a separate store in the short-lived CLI process. This also applies
when the runtime uses an isolated home or agent directory. Export destination
files are still written locally by the client.

### List, search, show, and history

```bash
lemon sessions list --limit 20
lemon sessions list --archived --pinned --agent-id research --json
lemon sessions search "deployment follow-up" --limit 10
lemon sessions stats --active --group-limit 10
lemon sessions stats "deployment follow-up" --agent-id research --json
lemon sessions show agent:research:main
lemon sessions history agent:research:main --limit 25 --json
```

List and search accept `--limit` from 1 to 500 and `--offset` from 0 to
1,000,000. History accepts `--limit` from 1 to 200. Lifecycle filters are
explicit pairs: `--pinned` or `--unpinned`, and `--archived` or `--active`.
Contradictory filters are usage errors rather than silently selecting one.

Search checks session identifiers, agent identifiers, titles, and a bounded
redacted history selection. Human output avoids store paths and secret values;
JSON output contains normalized session and run fields only.

`sessions stats` applies the same agent, pin, archive, and bounded redacted
history-search filters. It reports exact valid-store and matched session counts,
active/archived/pinned/titled counts, the canonical run-count sum, and oldest
and newest update timestamps. Agent and origin dimensions are deterministically
ordered and capped from 1 to 50 entries (`--group-limit`, default 10); omitted
cardinality is reported. The report never contains session keys, titles,
messages, prompts, answers, paths, URLs, or credentials. Message/turn counts are
not inferred because no single canonical store exposes them reliably.

### Context-window usage

```bash
lemon sessions context agent:default:tui:local:dm:<uuid>
lemon sessions context agent:research:main --cwd ~/src/project --json
```

`sessions context` prints how a native session's next request spends the
model's context window: system prompt, tool definitions, skills, context files,
memory, user and assistant messages, tool results, summaries and free space,
with the auto-compaction threshold and the largest contributors. `--cwd`
(default: the current directory) locates a stopped session's native history.
The total is the latest provider-reported request size plus estimates for newer
messages; category splits are ~4 characters/token estimates scaled to that total.
A stopped session reuses the system-prompt/tool profile recorded when its last
turn ended. Output contains counts and bounded labels only—no prompt text, tool
arguments or absolute paths. The TUI `/context` and ACP `/context` commands use
the same `sessions.context` control-plane method.

The reply also carries a numeric `usage` block: cumulative `tokens` and
catalog-estimated `costUsd` from the session's spend ledger (every branch), and
`input`/`output`/`cacheRead`/`cacheWrite` token sums plus `assistantMessages`
for the active branch. The TUI prints it as a `tokens … in / … out / … cache ·
cost $… (estimate)` line under `/context` and `/session info`.

### Title, pin, and archive state

```bash
lemon sessions title agent:research:main "Literature review"
lemon sessions title agent:research:main --clear
lemon sessions pin agent:research:main
lemon sessions unpin agent:research:main
lemon sessions archive agent:research:main
lemon sessions restore agent:research:main
```

Titles are trimmed and limited to 160 characters. These commands update the
shared lifecycle metadata and verify the session still exists before reporting
success.

### Redacted export

Print an always-redacted export as JSON, JSON Lines, Markdown or a self-contained HTML page:

```bash
lemon sessions export agent:research:main --format json
lemon sessions export agent:research:main --format jsonl
lemon sessions export agent:research:main --format markdown
lemon sessions export agent:research:main --format html --output research-session.html
```

Write the selected export to an owner-only file:

```bash
lemon sessions export agent:research:main \
  --format json \
  --output research-session.json \
  --json
```

Existing files are refused unless `--force` is explicit. Symlinks and special
files are always refused. With `--output --json`, stdout contains safe export
metadata and only the output basename; the exported content stays in the file.
Without `--output`, `--json` returns the redacted content in its JSON envelope.
Exports contain selected session/run/tool fields, SHA-256 integrity metadata,
and omission counts. They never contain raw run records or raw event payloads.
`jsonl` emits one compact JSON object per line: a `{"type":"session",...}`
record followed by one `{"type":"run",...}` record per run. `html` is a single
file with inline CSS only (no scripts or external resources) and every value
escaped. The TUI `/session export [key] [json|jsonl|markdown|html]` uses the same
method.

### Preview-confirm prune

Prune is dry-run by default. It selects only archived sessions older than the
cutoff and excludes pinned sessions:

```bash
lemon sessions prune --older-than 30d
```

`--older-than` accepts a positive age with `s`, `m`, `h`, `d`, or `w`, an
ISO-8601 date/time, or epoch milliseconds. The preview prints the exact
`older_than_ms`, candidate keys, and confirmation token. Review the candidates,
then execute with the exact millisecond cutoff and token printed by the
preview:

```bash
lemon sessions prune \
  --older-than 1788062400000 \
  --confirm <preview-token>
```

Do not repeat a relative value such as `30d` for execution: time has advanced,
so the derived cutoff and token will differ. If any candidate or lifecycle
metadata changes after preview, execution fails and requires a new preview.

`--all` also considers non-archived sessions. `--include-pinned` also considers
pinned sessions. Both widen deletion scope and are included in the token, so
they must be identical at preview and execution. Deletion removes core-owned
chat, policy, metadata, index, and history state and verifies each session is
gone before reporting success.

### Verified single-session delete

Single-session deletion requires the exact session key twice:

```bash
lemon sessions delete agent:research:main \
  --confirm agent:research:main
```

A mismatch is a usage error and does not mutate state. The lifecycle service
deletes canonical run history last, verifies all core-owned state is gone, and
restores recoverable ancillary metadata if final deletion or verification
fails.

## omp delegate sessions

`lemon omp` drives omp (oh-my-pi) coding-agent processes that the runtime owns,
through the authenticated control plane (`omp.*` methods; see the
[omp guide](omp.md)). Every subcommand accepts `--json`; text that came from omp
is printed with terminal control characters removed.

```bash
lemon omp status                         # installed?, version, live/max sessions
lemon omp list [--all] [--limit N]       # live sessions; --all adds ended ones
lemon omp show omp_3f9a1c2b7d4e          # bounded plain-text summary
lemon omp start [--cwd PATH] [--model M] [--thinking LEVEL] [--approval-mode write] [--isolate] fix the flaky test
lemon omp start-many --task "Fix parser" --task "Document API" --cwd PATH --isolate
lemon omp models [query] [--free] [--provider P] [--limit N]
lemon omp configure omp_3f9a1c2b7d4e [--model provider/id] [--thinking low]
lemon omp subagent omp_3f9a1c2b7d4e CHILD-ID [--limit N]
lemon omp watch omp_3f9a1c2b7d4e         # follow until the turn settles
lemon omp send omp_3f9a1c2b7d4e [--follow-up|--redirect] also update the docs
lemon omp cancel omp_3f9a1c2b7d4e        # abort the turn; the process stays open
lemon omp close omp_3f9a1c2b7d4e         # end the process; it stays resumable
lemon omp discover [--cwd PATH] [--limit N]
lemon omp resume 01a137e9 [--cwd PATH] [prompt...]
lemon omp resume 01a137e9 --continue [--approval-mode write]
```

`start` and `resume` accept `--approval-mode always-ask|write|yolo`; omitting it
preserves omp's configured mode. `--continue` explicitly continues interrupted
history and cannot accompany a prompt. `start --isolate` creates a managed Git
worktree; `start-many` takes 1–8 repeated `--task` prompts and shares `--cwd`,
`--model`, `--thinking`, `--approval-mode` and `--isolate` across tasks. Its
output has one indexed success (id/status) or error (code/message) per task.
Successful workers remain running if another task fails.

`models` prints selector, name, context window and input/output prices per
million tokens (or FREE), with a limit up to 200. `subagent` prints a bounded
transcript tail (limit up to 50). `configure` requires at least one setting and
prints the effective model/thinking. If configuration is partially applied, the
error identifies acknowledged settings and the failed step: earlier changes
are **not rolled back**, and the request must not be blindly retried.

`discover` includes the history source (`lemon` or `omp`) and marks interrupted
turns. This hint can also describe a live turn; check its live id before resuming.
`show` includes approval mode, pending approval ids, managed worktree path/branch
and kept/dirty/commit state, and child activity. Resolve approvals in the TUI
or through control-plane `exec.approval.resolve` (there is no CLI approval resolver).

`--cwd` defaults to the current directory. `send` steers the running turn
(`--follow-up` queues the message after it; `--redirect` stops it and starts
over with the new message). These flags are mutually exclusive. An idle
session starts a new turn in any mode; messages are limited to 16 KiB.
`watch` follows `omp.session` events,
re-reading the session every two seconds when none arrive; leaving it, including
with Ctrl-C, never cancels the turn. A send, cancel, or start reported as not
retry-safe may already have taken effect: check `lemon omp show ID` before
retrying. When omp is not installed, `status` says so and `start` fails with
`UNAVAILABLE`; set `LEMON_OMP_BIN` for a non-`PATH` install.

## Command and option reference

Every command, subcommand and option below is read from the shared
`LemonCli.CommandRegistry`, which also drives `lemon --help`,
`lemon help <command>` and shell completion. Narrative sections above and in the
linked guides explain behavior; this section is the exhaustive syntax list.
Run `lemon help <command>` for the same data on your installed version.
Launcher lifecycle commands (`tui`, `web`, `start`, `daemon`, `stop`, `restart`,
`status`) are described under [Launcher lifecycle commands](#launcher-lifecycle-commands).

#### `lemon acp`

Serve ACP over stdio using the local runtime.

```text
lemon acp
```

#### `lemon tern`

Install Lemon's Tern palette plugin and ACP agent.

```text
lemon tern install [--config-dir PATH]
```

| Subcommand | Purpose |
| --- | --- |
| `install` | Install the palette plugin and register `tern acp lemon` |

| Option | Purpose |
| --- | --- |
| `--config-dir PATH` | Tern configuration directory (not a config file) |

#### `lemon run`

Run a prompt non-interactively (-p, --print).

```text
lemon run [PROMPT] [--output text|json|stream-json] [options]
```

| Option | Purpose |
| --- | --- |
| `--output FORMAT` | text, json, or stream-json |
| `--model MODEL` | Provider:model override |
| `--cwd PATH` | Working directory |
| `--session KEY` | Resume a session |
| `--continue` | Continue the latest CLI session |
| `--approval-policy deny\|allow` | Deny or allow approval requests |
| `--allowed-tools LIST` | Comma-separated tool allowlist |
| `--denied-tools LIST` | Comma-separated tool denylist |

#### `lemon setup`

Run first-time setup and configuration.

```text
lemon setup [provider|runtime|gateway|doctor] [options]
```

| Subcommand | Purpose |
| --- | --- |
| `provider` | Configure an AI provider |
| `runtime` | Configure runtime profile and port bindings |
| `gateway` | Configure gateway adapters |
| `doctor` | Run diagnostics or write a support bundle (alias for doctor) |

| Option | Purpose |
| --- | --- |
| `--non-interactive, -n` | Skip prompts |
| `--config-path PATH` | Config file to read or write |
| `--skip-verify` | Defer live provider verification |
| `--daily-brief HH:MM` | Daily brief time (non-interactive) |
| `--set-default` | Set the provider and model as defaults |
| `--provider NAME` | Provider to sign in to (openai-codex for ChatGPT) |
| `--token TOKEN` | Credential for non-interactive provider setup |
| `--auth oauth\|device\|api_key\|codex-cli` | Authentication mode (import is opt-in) |
| `--codex-auth-path PATH` | Auth file for --auth codex-cli only |
| `--model MODEL` | Model to make the default after onboarding |
| `--if-required` | Exit immediately unless setup is still required |

#### `lemon model`

Configure an AI provider.

```text
lemon model [provider] [options]
```

| Option | Purpose |
| --- | --- |
| `--provider NAME` | Provider id |
| `--token TOKEN` | Provider credential |
| `--auth oauth\|device\|api_key\|codex-cli` | Authentication mode (import is opt-in) |
| `--codex-auth-path PATH` | Auth file for --auth codex-cli only |
| `--non-interactive` | Require --token, --auth device or --auth codex-cli |
| `--secret-name NAME` | Secret to store, inspect, or log out |
| `--model MODEL` | Default model with --set-default |
| `--set-default` | Set the provider and model as defaults |
| `--config-path PATH` | Config file to update |
| `--status` | Show the provider's sign-in and credential status |
| `--logout` | Delete the stored OAuth login and its config |

Without a provider, Lemon displays an interactive picker. Credentials are stored in the encrypted secrets store and referenced from config.toml.

`lemon model anthropic` signs in with a Claude Pro/Max subscription in the browser; `--status` and `--logout` need a provider.

`lemon model openai-codex --auth device` signs in to ChatGPT with a device code (no local callback); `openrouter`, `xai`, `kimi_coding` and `zai` also offer subscription sign-in.

#### `lemon gateway`

Configure a gateway adapter.

```text
lemon gateway setup [--transport NAME] [options]
```

| Subcommand | Purpose |
| --- | --- |
| `setup` | Configure Telegram or Discord |

| Option | Purpose |
| --- | --- |
| `--transport NAME, -t NAME` | Gateway adapter |
| `--non-interactive, -n` | Skip prompts |
| `--token TOKEN` | Bot token to store in encrypted secrets |
| `--chat-id ID` | Telegram chat to allow (repeatable) |
| `--pair-timeout SECONDS` | Telegram /start pairing wait |

Telegram setup pairs the bot with your chat: send /start to the bot when prompted, or pass --chat-id. An unpaired bot ignores every chat.

#### `lemon pairing`

Review and approve channel pairing requests.

```text
lemon pairing list | approve <telegram|discord> <CODE> | deny <telegram|discord> <CODE>
lemon pairing revoke <telegram|discord> <CHAT_ID>
```

| Subcommand | Purpose |
| --- | --- |
| `list` | List pending requests without codes |
| `approve` | Consume a code and allow its chat |
| `deny` | Consume a code without allowing its chat |
| `revoke` | Remove a paired chat from the allowlist (accepted by the command, not yet listed in registry help) |

Local operator only. Approval updates the user gateway config; restart the runtime to apply the allowlist.

#### `lemon doctor`

Run diagnostics or write a support bundle.

```text
lemon doctor [options]
```

| Option | Purpose |
| --- | --- |
| `--verbose, -v` | Show passing and skipped checks |
| `--json` | Output one JSON document |
| `--live` | Opt in to bounded, non-generating connectivity checks |
| `--project-dir PATH` | Use a specific project directory |
| `--bundle [PATH]` | Write a redacted support bundle |
| `--bundle-path PATH` | Set the support bundle path |

#### `lemon config`

Validate, show or migrate configuration.

```text
lemon config [validate|show|migrate] [options]
```

| Subcommand | Purpose |
| --- | --- |
| `validate` | Validate the resolved configuration |
| `show` | Show the resolved configuration summary |
| `migrate` | Rewrite deprecated sections in global and project config (keeps a backup) |

| Option | Purpose |
| --- | --- |
| `--verbose, -v` | Verbose output |
| `--project-dir, -p PATH` | Project directory for project config |

#### `lemon mcp`

Manage and test named MCP servers.

```text
lemon mcp add NAME (--stdio COMMAND [-- ARG...] | --http URL) [options]
lemon mcp list [--all]|remove NAME|test NAME|enable NAME|disable NAME [options]
```

| Subcommand | Purpose |
| --- | --- |
| `add` | Add |
| `list` | List |
| `remove` | Remove |
| `test` | Test |
| `enable` | Enable |
| `disable` | Disable |

| Option | Purpose |
| --- | --- |
| `--global` | Use the global agent MCP file instead of project config |
| `--cwd PATH` | Project root (default: current directory) |
| `--all` | list: effective servers incl. other tools' configs, with source and state |
| `--stdio COMMAND` | Executable; pass its arguments after -- |
| `--http URL` | Streamable HTTP MCP endpoint |
| `--env KEY=VALUE` | Stdio environment entry (repeatable) |
| `--header KEY=VALUE` | HTTP header (repeatable) |
| `--approval always\|never` | Server approval default (add: always) |
| `--tool-approval TOOL=always\|never` | Exact remote tool override (repeatable) |
| `--replace` | Replace a unique existing name, preserving extensions |
| `--json` | Emit redacted JSON |

#### `lemon secrets`

Manage encrypted secrets.

```text
lemon secrets <command> [args]
```

| Subcommand | Purpose |
| --- | --- |
| `status` | Show safe secrets-store status |
| `init` | Initialize the master key |
| `set` | Store one secret |
| `list` | List metadata without values |
| `delete` | Delete one secret |
| `check` | Check configured credential sources |
| `import-env` | Import selected environment credentials |
| `rotate-key` | Preview or apply a master-key rotation |
| `sources` | Inspect or test external secret sources |

| Option | Purpose |
| --- | --- |
| `--target file\|keychain` | Master-key target for init |
| `--provider NAME` | Metadata provider for set |
| `--expires-at N` | Expiry timestamp for set |
| `--dry-run` | Preview environment imports |
| `--force` | Confirm the selected replacement operation |
| `--confirm TOKEN` | Exact rotate-key preview token |
| `--project-dir PATH` | Project directory for source config |
| `--source-id ID` | Test one external source |
| `--json` | Emit redacted source readiness JSON |

rotate-key previews by default and changes nothing. Applying requires the exact preview token, refuses while a Lemon runtime is running, and re-encrypts every stored secret under a new master key written to the Keychain entry or key file that supplied the current one.

#### `lemon channels`

Inspect channel configuration.

```text
lemon channels [options]
```

| Option | Purpose |
| --- | --- |
| `--project-dir PATH` | Project root to read config from |
| `--json` | Emit redacted channel diagnostics JSON |

#### `lemon providers`

Inspect provider readiness and manage routing.

```text
lemon providers [status|fallback|pool] [options]
```

| Subcommand | Purpose |
| --- | --- |
| `status` | Status |
| `fallback` | Fallback |
| `pool` | Pool |

| Option | Purpose |
| --- | --- |
| `--provider NAME, -p NAME` | Filter or add a provider |
| `--include-catalog` | Include every known provider |
| `--project-dir PATH` | Resolve project configuration |
| `--scope global\|project` | Configuration target |
| `--config-path PATH` | Explicit configuration path |
| `--dry-run` | Preview without writing |
| `--confirm VALUE` | Exact destructive-change confirmation |
| `--strategy priority\|round_robin` | Credential-pool strategy |
| `--activate` | Make the selected pool the default |
| `--json` | Emit one redacted JSON document |

Fallback commands: list, add PROVIDER, remove PROVIDER, clear.

Pool commands: list, set POOL, delete POOL, and credential add/remove/clear. Credential references remain in the existing encrypted store or environment; values are never copied into TOML or status output.

Mutations preserve comments, preview safely, and require the exact confirmation value when removing configured routing state.

#### `lemon blueprints`

Review and activate cataloged skill automation blueprints.

```text
lemon blueprints [list|inspect|validate|preview|activate] [options]
```

| Subcommand | Purpose |
| --- | --- |
| `list` | List |
| `inspect` | Inspect |
| `validate` | Validate |
| `preview` | Preview |
| `activate` | Activate |

| Option | Purpose |
| --- | --- |
| `--profile ID` | Target profile for preview or activation |
| `--confirm DIGEST` | Exact digest from a fresh preview |
| `--json` | Emit one sanitized JSON document |

With no arguments, the command lists the local catalog. A bundle ID plus --profile is shorthand for preview and never mutates state.

Activation accepts catalog IDs only and requires the exact confirmation digest from a fresh plan. Bundle paths, archives, commands, environment overrides, and secret values are not CLI inputs.

#### `lemon profile`

Manage isolated agent profiles.

```text
lemon profile <command> [options]
```

| Subcommand | Purpose |
| --- | --- |
| `list` | List |
| `show` | Show |
| `create` | Create |
| `clone` | Clone |
| `rename` | Rename |
| `export` | Export |
| `delete` | Delete |
| `roster` | Roster |
| `chat` | Chat |

| Option | Purpose |
| --- | --- |
| `--json` | Emit JSON |
| `--name NAME` | Profile display name |
| `--model MODEL` | Profile or chat model |
| `--node NODE` | Named execution node |
| `--queue-mode MODE` | Chat queue mode |
| `--confirm ID` | Exact profile deletion confirmation |
| `--force` | Replace an existing export file |

Lifecycle commands keep profiles under the canonical Lemon home. Exports are selected-file snapshots that never include sessions, memory, or artifacts. Selected files (profile `config.toml`, designated workspace Markdown, allowlisted skill text) and the profile name, description, and system prompt go through credential redaction before export, so inline credential values are not preserved. Redaction is not exhaustive; review an export before sharing it.

#### `lemon backup`

Back up or restore durable user state.

```text
lemon backup <contract|create|list|verify|restore> [options]
```

| Subcommand | Purpose |
| --- | --- |
| `contract` | Contract |
| `create` | Create |
| `list` | List |
| `verify` | Verify |
| `restore` | Restore |

| Option | Purpose |
| --- | --- |
| `--output PATH` | Output bundle path |
| `--root PATH` | Backup root to list |
| `--target PATH` | Restore target |
| `--include-credentials` | Include local credentials |
| `--overwrite` | Allow verified differing files |
| `--confirm TOKEN` | Exact verify token |
| `--json` | Emit one JSON document |

Restore verifies before mutation. The only credential-specific exclusions are the `cookie`, `env`, and `secrets_master_key` files and the `nodes/execution/` directory; `--include-credentials` adds them. Backups also skip generated/runtime roots, support bundles, pid/socket files, the backup lock, symlinks, and special files. SQLite databases are snapshotted transactionally; `config.toml` and other non-SQLite included files are copied byte-for-byte and are not scrubbed, so inline API keys or tokens in them are preserved. Treat every backup as sensitive. Secret values and backed-up file contents are never printed. See [Back up and restore](backups.md) for the full contract.

Exit codes: 0 success; 1 verification or operational failure; 2 invalid command or options.

#### `lemon context`

Preview or resolve bounded context references.

```text
lemon context <preview|resolve> <reference>... [options]
```

| Subcommand | Purpose |
| --- | --- |
| `preview` | Preview |
| `resolve` | Resolve |

| Option | Purpose |
| --- | --- |
| `--root PATH` | Root for confined file references |
| `--json` | Emit JSON |
| `--max-bytes N` | Bound selected bytes |
| `--max-items N` | Bound selected items |
| `--max-depth N` | Bound folder traversal depth |
| `--max-pages N` | Bound document pages |
| `--timeout-ms N` | Bound external resolution time |

#### `lemon sessions`

Inspect and manage durable sessions.

```text
lemon sessions <command> [options]
```

| Subcommand | Purpose |
| --- | --- |
| `list` | List |
| `search` | Search |
| `stats` | Stats |
| `show` | Show |
| `history` | History |
| `context` | Context |
| `title` | Title |
| `pin` | Pin |
| `unpin` | Unpin |
| `archive` | Archive |
| `restore` | Restore |
| `export` | Export |
| `prune` | Prune |
| `delete` | Delete |

| Option | Purpose |
| --- | --- |
| `--json` | Emit one redacted JSON document |
| `--limit N` | Bound rows or history entries |
| `--offset N` | Skip list/search rows |
| `--group-limit N` | Bound stats dimension entries |
| `--agent-id ID` | Filter by agent id |
| `--pinned \| --unpinned` | Filter pin state |
| `--archived \| --active` | Filter archive state |
| `--format json\|jsonl\|markdown\|html` | Redacted export format |
| `--cwd PATH` | Project directory for context (default: current) |
| `--clear` | Clear a session title |
| `--output PATH` | Write export content to a private file |
| `--force` | Replace an existing regular export file |
| `--older-than AGE\|DATE` | Prune cutoff, for example 30d |
| `--all` | Allow non-archived prune candidates |
| `--include-pinned` | Allow pinned prune candidates |
| `--confirm TOKEN` | Exact preview or delete confirmation |

Stats returns exact aggregate counts with bounded, redacted agent and origin dimensions. History and exports are always redacted. Prune previews by default and executes only with the exact token from an unchanged candidate set. Delete requires the exact session key.

Context shows a native session's context-window usage by category (system prompt, tools, skills, context files, memory, messages, free space); splits are estimates scaled to the provider-reported total.

#### `lemon runs`

Inspect runtime runs and per-run timelines.

```text
lemon runs [list|active] [options] | lemon runs show <runId> [--json]
```

| Subcommand | Purpose |
| --- | --- |
| `list` | List |
| `active` | Active |
| `show` | Show |

| Option | Purpose |
| --- | --- |
| `--status S` | completed, aborted, crashed, or error (recent only) |
| `--session KEY` | Filter session key |
| `--agent ID` | Filter agent |
| `--since AGE` | Recent cutoff: 30m, 1h, or 2d |
| `--limit N` | Return 1..200 rows (default 50) |
| `--json` | Emit JSON |

Requires a running runtime; never starts one. Recent filters inspect at most 200 returned history rows. Active lists in-flight sessions. Show renders a redacted per-run timeline with relative times, tool outcomes, subagents and usage (latest 500 entries).

#### `lemon cron`

Manage cron jobs and inspect run history.

```text
lemon cron list [--failing] [--json] | pause|resume|run <id|name> | remove <id|name> [--yes] | status [--json] | runs [options]
```

| Subcommand | Purpose |
| --- | --- |
| `list` | List |
| `pause` | Pause |
| `resume` | Resume |
| `run` | Run |
| `remove` | Remove |
| `status` | Status |
| `runs` | Runs |

| Option | Purpose |
| --- | --- |
| `--failing` | List only jobs with a nonzero failure streak |
| `--yes` | Confirm removal without an interactive prompt |
| `--job ID` | Select one job; default all current jobs |
| `--status S` | pending, running, completed, failed, timeout, or aborted |
| `--since AGE` | Cutoff: 30m, 1h, or 2d |
| `--limit N` | Return 1..200 rows (default 50) |
| `--json` | Emit JSON without job prompts or run output |

#### `lemon logs`

Tail redacted runtime or offline launcher logs.

```text
lemon logs [-n 50] [--level info|warning|error] [--follow] [--json]
```

| Option | Purpose |
| --- | --- |
| `-n N` (alias `--lines N`) | Return 1..1000 lines (default 50) |
| `--level LEVEL` | Minimum severity: info, warning, or error |
| `--follow` | Poll every two seconds; Ctrl-C exits |
| `--json` | Emit JSON; follow emits one document per poll |

Reads logs.tail while online, otherwise the launcher log. File reads are bounded to the last 1 MiB; unknown-level file lines are excluded with --level.

#### `lemon omp`

Start, watch, and steer omp coding-agent sessions.

```text
lemon omp <command> [args] [options]
```

| Subcommand | Purpose |
| --- | --- |
| `status` | Show whether omp is installed and live-session counts |
| `list` | List live omp sessions (--all includes ended ones) |
| `show` | Summarize one session: show ID |
| `discover` | List omp's stored sessions for a workspace |
| `start` | Start omp on a prompt: start [options] PROMPT... |
| `start-many` | Start parallel workers with repeated --task PROMPT |
| `models` | List omp models: models [QUERY] [--free] [--provider P] |
| `subagent` | Read a transcript tail: subagent ID SUBAGENT-ID |
| `configure` | Change a worker: configure ID [--model M] [--thinking L] |
| `send` | Steer, follow up or redirect: send ID [--follow-up\|--redirect] MESSAGE... |
| `cancel` | Abort the running turn; the session stays open |
| `close` | End the omp process; it stays resumable |
| `resume` | Reopen a stored session: resume OMP-ID [PROMPT...] |
| `watch` | Follow a session until its turn settles |

| Option | Purpose |
| --- | --- |
| `--cwd PATH` | Workspace for start, resume, discover (default: .) |
| `--model MODEL` | omp model for start, start-many, resume or configure |
| `--thinking LEVEL` | Thinking level for start, start-many, resume or configure |
| `--approval-mode MODE` | always-ask, write or yolo (start/start-many/resume) |
| `--isolate` | Create managed Git worktrees (start/start-many) |
| `--continue` | Continue interrupted history on resume; no prompt |
| `--task PROMPT` | Repeat 1–8 times for start-many |
| `--free` | Only free omp models |
| `--provider PROVIDER` | Filter omp model provider |
| `--redirect` | Stop the current turn and replace its prompt |
| `--follow-up` | Queue a send after the running turn |
| `--all` | Include ended sessions in list |
| `--limit N` | Bound rows: list/discover max 100, models 200, subagent 50 |
| `--json` | Emit JSON |

omp runs inside the Lemon runtime, which starts first when needed. Without a subcommand, lemon omp lists live sessions. Text from omp is untrusted and printed with control characters removed.

Leaving watch (including Ctrl-C) never cancels the omp turn. A send or cancel reported as not retry-safe may already have taken effect; check `lemon omp show ID` before retrying.

#### `lemon learning`

Browse the current profile's learning timeline.

```text
lemon learning [--profile ID] [--kind memory|user|project|skill] [--limit N] [--json]
```

| Option | Purpose |
| --- | --- |
| `--profile ID` | Local profile (default: default assistant) |
| `--kind KIND` | Filter memory, user, project, or skill events |
| `--limit N` | Maximum events, 1–100 (default 50) |
| `--json` | Emit one redacted JSON document |

Newest first. Existing creation/latest-update timestamps only, not a complete historical log. Previews show current redacted content.

Use the existing memory management and skill commands to edit/delete; this command never mutates state.

#### `lemon learn`

Review and confirm bounded learning from sources.

```text
lemon learn [review|confirm] <reference>... [options]
```

| Subcommand | Purpose |
| --- | --- |
| `review` | Review |
| `confirm` | Confirm |

| Option | Purpose |
| --- | --- |
| `--root PATH` | Root for confined local sources |
| `--agent-id ID` | Durable memory owner |
| `--session-key KEY` | Explicit learning session |
| `--project` | Use the project draft scope |
| `--confirm DIGEST` | Exact digest from a fresh review |
| `--json` | Emit one sanitized JSON document |

Review is the default and never writes state. Confirm re-resolves every source and fails closed when source content, audit state, or destination conflicts changed.

Output contains hashes, counts, audit codes, and conflict state only; source text, prompts, paths, URLs, secret names, and secret values are omitted.

#### `lemon update`

Safely plan, apply, inspect, or roll back Lemon releases.

```text
lemon update <check|plan|apply|history|rollback> [options]
```

| Subcommand | Purpose |
| --- | --- |
| `check` | Check |
| `plan` | Plan |
| `apply` | Apply |
| `history` | History |
| `rollback` | Rollback |

| Option | Purpose |
| --- | --- |
| `--channel CHANNEL` | Override the release channel |
| `--version VERSION` | Use an exact published version |
| `--confirm DIGEST` | Exact fresh plan or rollback digest |
| `--receipt ID` | Exact update receipt for rollback |
| `--limit N` | Bound history receipts |
| `--json` | Emit one redacted JSON document |

Planning is non-mutating. Managed-release apply requires the exact digest from a fresh plan; rollback requires both the exact apply receipt and its rollback digest.

Source checkouts support read-only check/history. Plan, apply, and rollback fail closed because source updates belong to the operator's reviewed git workflow.

#### `lemon completion`

Generate shell completion scripts.

```text
lemon completion <bash|zsh|fish>
```

| Subcommand | Purpose |
| --- | --- |
| `bash` | Bash |
| `zsh` | Zsh |
| `fish` | Fish |

The generated script matches the invoking launcher. Release VM tools (remote, eval, rpc) are only advertised by packaged installs.

#### `lemon migrate`

Import user data from a Hermes home.

```text
lemon migrate hermes [audit] [options]
```

| Subcommand | Purpose |
| --- | --- |
| `hermes` | Preview, then import a Hermes home into Lemon |
| `audit` | Read-only compatibility audit (`migrate hermes audit`) |

| Option | Purpose |
| --- | --- |
| `--source PATH` | Hermes home (default: ~/.hermes) |
| `--target PATH` | Lemon home (default: ~/.lemon) |
| `--workspace-dir PATH` | Assistant workspace override |
| `--preset user-data\|full` | Import scope (default: user-data) |
| `--migrate-secrets` | Import allowlisted secrets |
| `--skill-conflict skip\|rename` | Existing skill policy |
| `--dry-run` | Preview without writing |
| `--yes` | Apply without prompting |
| `--overwrite` | Replace conflicting target files |
| `--no-backup` | Skip the pre-migration zip backup |
| `--json` | Emit the audit as JSON |

Migration always previews first and refuses conflicts unless --overwrite is set. Without --yes it asks before writing. Secret values are never printed or written to reports.

#### `lemon node`

Inspect worker compatibility or join a named execution node.

```text
lemon node join --name NAME --controller wss://HOST/ws [options]
lemon node capabilities [--json] [--require-bot] [--expected-version VERSION]
```

| Subcommand | Purpose |
| --- | --- |
| `join` | Pair with or reconnect to a controller |
| `capabilities` | Inspect installed worker API compatibility without starting a runtime |

| Option | Purpose |
| --- | --- |
| `--json` | Print worker compatibility JSON (capabilities) |
| `--require-bot` | Fail if required bot worker APIs are absent (capabilities) |
| `--expected-version VERSION` | Require the exact installed worker CalVer (capabilities) |
| `--name NAME` | Unique execution node name |
| `--controller URL` | Controller control-plane WebSocket |
| `--pair` | Pair and store a controller-issued node token |
| `--invite-code-stdin` | Read one bounded enrollment or repair code from stdin (implies --pair) |
| `--node-id ID` | Durable controller node ID |
| `--repair` | Operator-authorized legacy credential repair |
| `--allow-insecure-controller` | Allow non-loopback ws:// |
| `--cwd PATH` | Default local working directory |
| `--allowed-root PATH` | Allowed host file/shell root (repeatable) |

#### `lemon version`

Print the Lemon version (--version includes build identity).

```text
lemon version [--verbose]
```

| Option | Purpose |
| --- | --- |
| `--verbose` | Show source/release, commit, and channel |

#### `lemon send`

Send a Telegram or Discord notification.

```text
lemon send --to TARGET [options] [message]
```

| Option | Purpose |
| --- | --- |
| `--to TARGET` | Telegram or Discord target |
| `--account NAME` | Channel account |
| `--subject TEXT` | Message subject |
| `--file PATH` | Read body from a file, or - for stdin |
| `--attach PATH` | Attach a local file (repeatable) |
| `--thread ID, --topic ID` | Thread or topic |
| `--reply-to ID` | Reply to a platform message |
| `--list [PLATFORM]` | List known targets |
| `--dry-run` | Validate without sending |
| `--quiet` | Suppress normal output |
| `--json` | Emit JSON |

#### `lemon media`

Inspect media generation diagnostics.

```text
lemon media [options]
```

| Option | Purpose |
| --- | --- |
| `--project-dir PATH` | Project root |
| `--limit N` | Recent jobs to show |
| `--json` | Emit redacted JSON |

#### `lemon models`

List the model catalog.

```text
lemon models [options]
```

| Option | Purpose |
| --- | --- |
| `--provider NAME` | Filter by provider |
| `--vision` | Only image-capable models |
| `--thinking` | Only reasoning-capable models |
| `--limit N` | Maximum rows |
| `--json` | Emit catalog and summary JSON |
| `--discover` | Query a preset provider endpoint for its models |
| `--base-url URL` | Endpoint for --discover |

#### `lemon policy`

Manage model policies.

```text
lemon policy <list|set|get|clear> [channel] [options]
```

| Subcommand | Purpose |
| --- | --- |
| `list` | List |
| `set` | Set |
| `get` | Get |
| `clear` | Clear |

| Option | Purpose |
| --- | --- |
| `--account ID` | Channel account |
| `--peer ID` | Peer or chat |
| `--thread ID` | Thread or topic |
| `--model MODEL` | Model override |
| `--thinking LEVEL` | Thinking override |
| `--reason TEXT` | Policy metadata reason |
| `--all` | Clear all policies for the channel |

#### `lemon skill`

Manage installed skills.

```text
lemon skill <command> [args]
```

| Subcommand | Purpose |
| --- | --- |
| `list` | List |
| `browse` | Browse |
| `search` | Search |
| `discover` | Discover |
| `hermes` | Hermes |
| `install` | Install |
| `update` | Update |
| `remove` | Remove |
| `inspect` | Inspect |
| `check` | Check |
| `info` | Info |
| `draft` | Draft |
| `curator` | Curator |

| Option | Purpose |
| --- | --- |
| `--cwd PATH` | Project workspace |
| `--local` | Install only in the project |
| `--global` | Use global skills |
| `--force` | Confirm overwrite or removal |
| `--no-online` | Search only installed skills |
| `--active` | Browse only active skills |
| `--not-ready` | Browse skills missing dependencies |
| `--all` | Include hidden skills when browsing |

#### `lemon usage`

Inspect usage diagnostics.

```text
lemon usage [--days N | --since YYYY-MM-DD --until YYYY-MM-DD] [--by day|provider|model|session] [--json]
```

| Option | Purpose |
| --- | --- |
| `--days N` | Last N UTC dates including today (1–366) |
| `--since YYYY-MM-DD` | Inclusive first UTC date |
| `--until YYYY-MM-DD` | Inclusive last UTC date |
| `--by GROUP` | day, provider (default), model, or session |
| `--json` | Emit redacted usage JSON |

## Shell completion

Completion scripts are generated from the same registry used by CLI dispatch
and help, so new runtime families cannot be added to one surface while being
omitted from the others.

### Bash

```bash
mkdir -p "$HOME/.local/share/bash-completion/completions"
lemon completion bash > "$HOME/.local/share/bash-completion/completions/lemon"
```

### Zsh

```zsh
mkdir -p "$HOME/.zfunc"
lemon completion zsh > "$HOME/.zfunc/_lemon"
fpath=("$HOME/.zfunc" $fpath)
autoload -Uz compinit && compinit
```

Persist the `fpath` line in `.zshrc` if `$HOME/.zfunc` is not already in the
completion path.

### Fish

```fish
mkdir -p "$HOME/.config/fish/completions"
lemon completion fish > "$HOME/.config/fish/completions/lemon.fish"
```

Regenerate the script after upgrading Lemon so it reflects the installed
command registry.
