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

## Commands and availability

### Launcher lifecycle commands

The registry defines their help and completion; the launcher executes them:

| Command | Source checkout | Packaged release | Purpose |
| --- | --- | --- | --- |
| `tui [args]` | Yes | Yes | Reuse a healthy runtime; otherwise run `setup --if-required` in an interactive terminal, start the daemon, and open the TUI. |
| `web [--no-open]` | Yes | Full profile only | Start the daemon if needed, wait for Web UI health, and print its URL; open a browser unless `--no-open` is set. |
| `start` | Yes | Yes | Run the runtime in the foreground. |
| `daemon` | Yes | Yes | Start the runtime in the background and wait for health. |
| `stop`, `restart`, `status` | Yes | Yes | Manage or inspect the daemon using its pidfile. |
| `remote`, `eval EXPR`, `rpc EXPR` | No | Yes | Use release VM remote/eval/RPC tools. |

Source runtime options go after `start`, `daemon`, or `restart`:
`--debug`, `--port N`, `--web-port N`, `--sim-port N`, `--name name@host`,
`--sname name`, `--cookie C`, and `--no-distribution`. For example,
`./bin/lemon start --no-distribution`. Runtime options are accepted after the
relevant lifecycle command, not as bare launcher flags.

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
Commands that document `--json` emit JSON on success. Redacted operational
error JSON is supported by the profile, session, blueprint, provider, learning,
and secret-source command families; other commands report errors as text on
stderr. Invalid arguments remain human-readable usage errors.

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
