# Lemon CLI

`lemon_cli` is the user-facing command boundary for source and packaged Lemon.
`LemonCli.CLI.main/1` receives the forwarded argument vector from either
launcher and turns dispatch results into exit codes. Its non-halting `run/1`
and Mix-free runtime command handlers are shared by both installation paths.

The runtime CLI is included in `lemon_runtime_min` and `lemon_runtime_full`
artifacts. The source-built `sim_broadcast_platform` release intentionally does
not bundle `lemon_cli`; it supports only its release-specific `doctor --bundle`
path.

At application startup, `lemon_cli` registers its destination-local provider
management service with `LemonCore.ProviderManagement`. Both controller and named
worker runtimes use this registration; core-only runtimes without CLI setup
support return `unavailable` without attempting credential writes.

Codex device login is supervised on that destination. Authorized transports call
`device_start/2`, `device_poll/2`, and `device_cancel/2` with the exact
`targetId`, `providerId` (`openai_codex`), fixed `loginId`, and opaque
`ownerId`/`sessionId` binding. Every operation compares the binding. Only
`loginId`, `targetId`, `providerId`, `status`, `verificationUrl`, `userCode`,
`expiresAtMs`, and `pollIntervalMs` are returned. Pending logins show only
`https://auth.openai.com/codex/device` and the issued public code; other states
clear the browser/code/timing fields. The provider grant, verifier, token
exchange and refreshable credentials remain on the execution machine.

The device API uses the canonical provider ID from provider listing,
`openai_codex`; the existing TOML table remains `[providers.openai-codex]`.

Polling reads current status; a bounded worker polls the provider at its interval.
The login is at most 15 minutes, with at most 16 active and 128 retained records.
A new login cancels the same owner's previous target/provider login, even across
product sessions. Cancellation, completion, replacement and disconnect serialize;
only a current, unexpired completion uses the existing encrypted-secret/config
transaction, and it does not change defaults. Device-code sign-in may need to be
enabled for the ChatGPT account or organization.
A cancel received before its matching start consumes the fixed login ID without
contacting OpenAI; a delayed start cannot reconnect that cancelled intent.

Successful OAuth alone never writes credentials. The product requests an internal
`device_challenge/2` with the same five-field binding, then reauthorizes the
initiating owner/session/device, generation and exact execution target under its
existing authorization lock before issuing `device_complete/2` for that exact
nonce and a durably single-use completion ID. Only a ready target issues the
32-byte random URL-safe nonce, bound to the start authority; its own monotonic
five-second deadline starts at issuance. Repeated requests preserve an unexpired
challenge without extending it. The internal response adds `challengeNonce`
(null unless ready); it never reaches public clients or durable storage.
Tokens wait only in the sensitive target worker. Completion admits only a
matching, unused, unexpired nonce and rechecks the same monotonic deadline inside
the serialized credential transaction. Wall-clock skew or rollback cannot extend
admission, and target restart invalidates all challenges. Revocation prevents new
authorizations without waiting for a login or acknowledgement; an already-issued
authorization has only the remainder of that target-local five-second,
single-write admission window. An admitted write may finish later.
The controller connection or worker session generation must match the start when
authorizing a write. Non-writing `commit:false` settlement instead accepts the
exact original login binding after reconnect/re-pairing, consumes the completion
ID durably and cannot authorize a delayed write. Uncertain outcomes retain that
same ID for reconciliation, never automatic retry or a revocation lock. The
public eight-field status is unchanged; waiting for authorization is `pending`.


After lifecycle restart or record expiry, an old login returns `lost`, not success
or a restarted exchange. A nonsecret, one-MiB spent-ID filter in the target Store
prevents fixed-ID replay even after volatile records are pruned. Its bytes are
persisted as canonical Base64 so the JSONL backend can durably retain every hash
position. Invalid, malformed or legacy raw-byte filter records fail closed;
they are never treated as an empty filter. It can conservatively report `lost`
on a hash collision and refuses new starts at its 100,000-ID lifetime ceiling,
including cancelled-before-start IDs and namespaced completion attempts (whether
they write credentials or settle without writing). The filter is never
automatically cleared; credentials and pending grants are not stored in it.
No localhost callback, client-ID change, hosted relay or phone-side token storage
is involved.

## Release CLI contract

The packaged launcher sends runtime CLI arguments through `LemonCli.CLI` as
data, not dynamically constructed Elixir source. The boundary has these
user-visible rules:

- success exits `0`;
- a command failure exits `1`;
- an unknown command, unknown setup/gateway subcommand, or invalid command
  arguments exits `2`;
- `--help`, `-h`, or `help` prints the relevant command usage and exits `0`
  without starting a wizard, provider flow, or gateway adapter.

## Packaged and source commands

Use the same command nouns in an installed release and a source checkout.
Installed releases use `lemon`; a checkout uses the matching `./bin/lemon`
wrapper. The command table shows launcher commands separately from commands
dispatched by `LemonCli.CLI`.

Packaged and source `secrets check` / `secrets import-env` commands read the
same ordered environment-secret names from `LemonCore.Secrets.EnvCatalog`.

External 1Password, Bitwarden Secrets Manager, and command sources remain
read-only fallbacks behind the encrypted Lemon store. Their source and packaged
diagnostics share `lemon secrets sources status|test`; both surfaces report
only readiness, stable provenance, counts, byte counts, and error kinds.

| Purpose | Installed release | Source checkout |
| --- | --- | --- |
| Start TUI (interactive no-argument launch) | `lemon` | `./bin/lemon` |
| Foreground runtime | `lemon start` | `./bin/lemon start` |
| Non-interactive coding | `lemon -p "prompt"` or `lemon run` | `./bin/lemon -p "prompt"` or `./bin/lemon run` |
| ACP over stdio | `lemon acp` | `./bin/lemon acp` |
| Register native Tern integration | `lemon tern install` | `./bin/lemon tern install` |
| Background runtime | `lemon daemon` | `./bin/lemon daemon` |
| First-time setup | `lemon setup` | `./bin/lemon setup` |
| Configure a model provider | `lemon model --provider anthropic` | `./bin/lemon model --provider anthropic` |
| Configure Telegram or Discord | `lemon gateway setup` | `./bin/lemon gateway setup` |
| Diagnostics | `lemon doctor` | `./bin/lemon doctor` |
| Open the local Web UI | `lemon web` | `./bin/lemon web` |
| Validate/show config | `lemon config validate` | `./bin/lemon config validate` |
| Manage encrypted secrets | `lemon secrets status` | `./bin/lemon secrets status` |
| Inspect/test external secret sources | `lemon secrets sources status` | `./bin/lemon secrets sources test` |
| Rotate the secrets master key | `lemon secrets rotate-key` | `./bin/lemon secrets rotate-key` |
| Inspect channel configuration | `lemon channels` | `./bin/lemon channels` |
| Inspect/edit provider routing | `lemon providers status|fallback|pool` | `./bin/lemon providers status|fallback|pool` |
| Review/activate cataloged blueprints | `lemon blueprints daily-note --profile operator` | `./bin/lemon blueprints daily-note --profile operator` |
| Back up or restore durable user state | `lemon backup create` | `./bin/lemon backup create` |
| Manage specialist profiles | `lemon profile list` | `./bin/lemon profile list` |
| Preview/resolve bounded context | `lemon context preview|resolve ...` | `./bin/lemon context preview|resolve ...` |
| Manage durable sessions | `lemon sessions list` | `./bin/lemon sessions list` |
| Review/confirm learning from bounded sources | `lemon learn '@file:guide.md'` | `./bin/lemon learn '@file:guide.md'` |
| Browse a profile's learning timeline | `lemon learning --profile research` | `./bin/lemon learning --profile research` |
| Migrate Hermes data | `lemon migrate hermes audit` | `./bin/lemon migrate hermes audit` |
| Join a named execution node | `lemon node join ...` | `./bin/lemon node join ...` |
| Print version | `lemon version` | `./bin/lemon version` |
| Safely update a managed release | `lemon update plan|apply|history|rollback` | `./bin/lemon update check|history` (binary mutation fails closed) |
| Generate shell completion | `lemon completion zsh` | `./bin/lemon completion zsh` |
| Send channel notifications | `lemon send --to telegram:123 "hello"` | `./bin/lemon send --to telegram:123 "hello"` |
| Inspect media, models, policies, skills, and usage | `lemon media`, `models`, `policy`, `skill`, `usage` | `./bin/lemon media`, `models`, `policy`, `skill`, `usage` |

Blueprint and profile-chat commands start the local runtime through the
launcher when it is not already healthy, in both source checkouts and packaged
releases.

`mix lemon.update` remains a source-maintenance task for config migration and
bundled-skill sync; it is not reachable as `./bin/lemon update`.
The removed Hermes-specific Mix tasks are deleted; use the unified migration
CLI above.

Hermes migration also previews global/profile-local Honcho settings, including
gateway pinning, runtime-user aliases and peer prefixes. It maps the supported
subset into `[honcho]` and reports unsupported options. API keys are
gated behind `--preset full --migrate-secrets` and go through encrypted Lemon
secrets; neither reports nor config contain their values. Existing Honcho settings
and secrets require `--overwrite` to replace. See the
[migration guide](../../docs/user-guide/migrate-from-hermes.md#honcho-configuration).

## Command registry and completion

`LemonCli.CommandRegistry` is the single registry for CLI dispatch, top-level
and command help, and shell completion metadata. Every CLI family is available
in source and packaged runtimes, including `send`, `media`, `models`, `policy`,
`skill`, and `usage`. These commands use Mix-free modules in their owning apps;
their existing Mix tasks are thin source-development adapters.

Lifecycle commands are registry entries too (for help and completion), but the
launcher shell executes them: `tui`, `web`, `start`, `daemon`, `stop`,
`restart`, and `status` work in both launchers; `remote`, `eval`, and `rpc` are
release-only. Reaching a lifecycle command inside `LemonCli.CLI` is a usage
error. Both launchers export `LEMON_CLI_LAUNCHER` (`source` or `release`) for
availability filtering and `LEMON_LAUNCHER` (their own path) so
`LemonCli.LocalRuntime` can run `$LEMON_LAUNCHER daemon` when a command needs
the runtime.

Source startup probes the local daemon before compiling, never installs or
updates dependencies, and compiles only once on a cold interactive launch.
Install source dependencies explicitly with `mix deps.get` before launching.
An already healthy daemon is reused without a Mix or distributed-node boot.

Source runtime state is private and port-scoped:
`~/.lemon/run/lemon-PORT.pid`, `lemon-PORT.log`, and `lemon-PORT.lock`.
`LEMON_RUNTIME_PID_FILE` and `LEMON_RUNTIME_LOG_FILE` can override the first two.
Concurrent starts serialize on the lock; abandoned locks with a dead recorded
owner are reclaimed. An empty lock is not automatically deleted: inspect it
and remove it only after confirming there is no startup in progress.
An occupied non-Lemon control port fails immediately with a port-selection fix.
An alive but unhealthy managed runtime requires inspection of its log and an
explicit stop, rather than starting another daemon. Stop verifies the process
start identity in the pid record before sending a signal, so stale/reused PIDs
cannot terminate an unrelated process. Select the same
`LEMON_CONTROL_PLANE_PORT` for start, stop, restart, and status.

## Safe managed-release updates

`lemon update` is registry-driven and uses one handler for full/min packaged
releases. `plan` is non-mutating; `apply` requires its exact fresh digest;
`history` reads private content-free receipts; and `rollback` requires the exact
apply receipt plus its receipt-bound rollback digest. JSON results omit managed
filesystem paths and errors expose stable safe kinds/messages rather than raw
runtime terms. The sim profile uses `LemonCore.Update.CLI` because it does not
assemble this app, but preserves the same command and confirmation contract.

Source launchers support check/history and refuse binary plan/apply/rollback.
See [the update guide](../../docs/user-guide/updates.md) for archive confinement,
checksum semantics, restart behavior, and the documented residuals.

`lemon completion bash|zsh|fish` emits only the completion program to stdout.
The source wrapper compiles quietly before generation; packaged runtimes use
the fixed release eval expression and pass the requested shell as argument
data. See the [command-line reference](../../docs/user-guide/cli.md) for
installation examples.

## Portable blueprint management

`lemon blueprints` is a Mix-free client for the authenticated local control
plane. It accepts only catalog IDs below the canonical `~/.lemon/bundles`
boundary; arbitrary roots, paths, archives, scripts, command jobs, environment
overrides, and secret values are not CLI inputs. Both launchers start the local
runtime when it is not already healthy.

```bash
lemon blueprints                         # bounded catalog list
lemon blueprints inspect daily-note      # sanitized manifest projection
lemon blueprints validate daily-note --json
lemon blueprints daily-note --profile operator  # shorthand for preview
lemon blueprints preview daily-note --profile operator --json
lemon blueprints activate daily-note --profile operator \
  --confirm <exact-confirmation-digest>
```

List, inspect, validate, and preview never mutate state. Preview returns the
profile target, skill hashes/actions, cron projection, prompt byte/hash
metadata, provenance, and exact confirmation digest without skill bodies,
prompt text, paths, or secret values. Activation delegates to the existing
control-plane/service path, re-plans under its lock, and succeeds only when the
fresh digest matches. Repeating preview plus activation reports unchanged
skills/job state instead of creating another cron job. JSON success is one
sanitized document on stdout; operational errors are one fixed redacted JSON
document on stderr and use exit `1`; invalid arguments use exit `2`.

## Durable session management

`lemon sessions` adapts `LemonCore.SessionLifecycle` without reimplementing
store queries. List/search/show/history reads are bounded; `sessions stats`
returns exact matched/store/run/status totals with capped, path-safe agent and
origin dimensions; history is always redacted. Title/pin/archive updates
require an existing session, exports are
selected-field and always redacted, and delete reports success only after the
shared service verifies canonical history and ancillary state are gone.

Prune previews archived, unpinned sessions by default. Execution requires the
token from the exact cutoff, flags, candidates, and lifecycle metadata shown by
the preview; a relative age must be replaced with the preview's exact
`older_than_ms` for confirmation. `--all` and `--include-pinned` are explicit
scope wideners. Human and JSON errors contain stable safe messages rather than
store paths, raw runtime terms, credentials, or secret values.

## Provider readiness and routing

`lemon providers` uses one Mix-free handler in source and packaged runtimes.
Status includes credential readiness, the effective fallback route, and
credential-pool counts, but never raw keys, secret names, credential references,
base URLs, or environment-variable names.

Provider rows also include `circuit` (`state`, `failureCount`,
`timeUntilRecoveryMs`). Text output shows, for example,
`circuit open (recovers in 23s, 5 failures)`. These are read-only observations:
status never starts a breaker. An unused provider reports `not_started`; an
unresponsive or exiting breaker reports `unknown`, with null counters.

```bash
lemon providers status --json
lemon providers fallback add zai
lemon providers pool set burst --provider openai --provider zai \
  --strategy round_robin --activate
lemon providers pool credential add burst openai secret:openai_backup
```

Credential pool entries are references only: `secret:NAME` keeps values in the
encrypted Lemon secret store and `env:NAME` resolves from the process
environment. Raw credential values are rejected instead of being copied into
TOML.

Mutations apply immediately unless `--dry-run` is passed. Removing a fallback,
deleting or updating an existing pool, and removing or clearing credentials are
destructive operations. Preview first to obtain the operation-bound confirmation
value, then repeat with `--confirm`:

```bash
lemon providers fallback remove zai --dry-run --json
lemon providers fallback remove zai --confirm zai
```

The command preserves comments and unrelated config, validates the complete
resulting TOML, and atomically replaces only the selected global or project
config. Success exits `0`, operation/config failures exit `1`, and invalid
arguments exit `2`; `--json` emits one redacted document.

## External secret sources

`lemon secrets sources status` validates the configured sources and checks
binary/bootstrap readiness without invoking a provider. `lemon secrets sources
test [source-id]` invokes each selected enabled source under LemonCore's bounded
supervisor. The test result contains the source id/type, readiness, provenance,
secret count, output byte count, duration, or a stable error kind; it never
contains a value.

Sources are explicitly opt-in (`enabled = true`) and execute an argument vector
directly. Shell command strings and interpolation are not accepted. A source
failure stops credential resolution before the ordinary environment fallback;
a successful source that simply lacks the requested name may continue to the
next source and then the environment. See
[`docs/config.md`](../../docs/config.md#external-secret-sources) for the exact
schema, bounds, and bootstrap-secret rules.

## Backup and restore

`lemon backup contract|create|list|verify|restore` is implemented by the same
Mix-free `LemonCli.CLI` handler in source and packaged runtimes. Every
subcommand supports `--json`; success writes one document to stdout and exits
`0`, verification/operational failure writes one redacted document to stderr
and exits `1`, and invalid options exit `2`.

Restore is additive and verified before mutation. Differing destination files
require `--overwrite` plus the token emitted by `backup verify --target PATH`;
that token is bound to the verified manifest digest and expanded target.
Credential-bearing files are excluded unless `backup create
--include-credentials` is explicit. See
[Back up and restore Lemon user state](../../docs/user-guide/backups.md) for the
complete format, exclusion, permissions, rollback, and compatibility contract.

## User-managed profiles

Profiles are durable router agents, not alternate engines. Each validated ID
maps to `[profiles.<id>]`, a stable `agent:<id>:main` chat, and an isolated
`~/.lemon/profiles/<id>/workspace/` used for bootstrap, memory paths, and skills.

```bash
lemon profile create research --name "Research" --model openai:gpt-5
lemon profile clone research research-copy --name "Research Copy"
lemon profile show research --json
lemon profile roster
lemon profile chat research "Review this week's notes"
lemon profile export research ./research-profile.json
lemon profile delete research-copy --confirm research-copy
```

`rename` changes the display name without changing the stable ID or chat.
Deletion requires exact-ID confirmation and moves the managed home into Lemon's
trash before removing config. Export is selected-file and credential-safe by
default: it excludes sessions, memory, artifacts, binaries, and secret-like
paths; redacts sensitive assignments and token patterns; and reports omission
and redaction counts. There is no CLI switch to include secrets.

Lifecycle commands run in the release CLI's fresh, non-booted VM. Canonical
chat is different: it must outlive that one-shot process, so the CLI connects
to the authenticated loopback control plane and calls `profile.chat`. Both
launchers start the daemon when needed. The request sends only the profile ID,
prompt, queue mode, and optional model override—working directory and execution
node are resolved again from the profile by the long-running runtime.

The direct in-VM submission path assigns a run ID before calling the router. If
acceptance cannot be confirmed, `profile chat` prints that safe run reference,
does not fall back to a second submission, and tells the operator to reconcile
before retrying. On the packaged control-plane path, a recognized explicit RPC
rejection is reported as rejected, a connection failure before the RPC is
reported as not submitted, and a timeout, disconnect, malformed acknowledgement,
or server-side unknown outcome remains conservatively unknown. The explicit
server-side unknown-outcome envelope carries its bounded generated run ID for
reconciliation; every other detail field is ignored. Raw router and control-plane
failure terms are never printed.

## Context references

`lemon context preview` and `lemon context resolve` are packaged adapters over
the shared `LemonCore.Context` service. They accept root-confined
`@file:`/`@folder:`, shell-free `@git-diff`, SSRF-guarded `@url:`, and redacted
`@session:` references. PDF, DOCX, XLSX, PPTX, and ipynb content is sniffed
from bytes and selected under explicit byte/page/item/depth/time/archive
limits. Preview performs the exact selection but omits selected text; resolve
returns selected redacted text plus omission metadata. See
[`docs/user-guide/context-references.md`](../../docs/user-guide/context-references.md).

## Learn from sources

`lemon learn` composes the bounded context resolver with canonical durable
memory and synthesized-skill drafts. Review is the default and never mutates:

```bash
lemon learn '@file:docs/runbook.md' '@url:https://example.com/guide' --json
lemon learn confirm '@file:docs/runbook.md' '@url:https://example.com/guide' \
  --confirm <exact-review-digest> --json
```

Confirmation re-resolves every source and destination conflict. It fails closed
when content, audit result, memory state, or draft state changed. Output
contains hashes, counts, audit codes, conflicts, and action state only; source
text, prompts, paths, URLs, secret names, and secret values are never printed.
See [`docs/user-guide/learn-from-sources.md`](../../docs/user-guide/learn-from-sources.md).

## First-run setup and readiness

`lemon setup` is an idempotent state machine over the global config, encrypted
secrets, and default provider. Each run derives which steps are complete,
creates a minimal config only when it is absent, initializes the secrets master
key only when it is absent, skips a provider that is already usable, and
re-derives state before reporting the final result. It never replaces an
existing config or secrets master key.

The full wizard makes the onboarded provider/model the default automatically;
accepting prompts no longer stores a credential while leaving coding unusable.
Choose **OpenAI Codex → Sign in with ChatGPT** for a ChatGPT subscription, or run
`lemon setup --provider chatgpt` directly. OAuth remains interactive. For scripts,
`lemon setup --non-interactive --provider openai --token "$OPENAI_API_KEY" --model gpt-5 --skip-verify`
creates config/secrets, stores the credential, and sets defaults without asking
questions. Omit `--skip-verify` to verify online. Incomplete setup exits nonzero;
rerunning an already configured setup preserves credentials and does not sign
in again.

`lemon doctor` fails when the selected default has a missing/mismatched model or
an unreadable credential, rather than accepting the mere presence of a secret
reference. It reports offline credential usability, not an unperformed API
login check. An occupied control-plane port that does not return Lemon's health
body is a failure with an explicit stop/change-port remedy.

When setup onboards a provider, it always performs offline configuration checks
and performs the provider's live credential check by default. Use
`lemon setup --skip-verify` or `lemon setup provider --skip-verify` only to
defer that live check when offline; a failed verification is not reported as a
completed setup.

The live models check uses the effective provider/model endpoint and headers,
with the same credential-pool/default selection as native requests. Selected
OAuth records resolve to their access token; the stored JSON and refresh token
are never Bearer credentials. If that selected login is unavailable, verification
fails before HTTP rather than reporting a successful skipped check or borrowing
an inline, ambient, or legacy key. Legitimate keyless endpoints are checked
without an Authorization header when no credential resolves. `--skip-verify`
still avoids the live request, and focused `lemon model` onboarding remains
offline by default.

Setup asks only for what first run needs: no runtime profile or Hermes import
questions (`lemon migrate hermes` stays available). The installer chooses the
profile. `LemonCli.Setup.Ports` asks about a port only when another program
holds a default one, and saves the choice to `~/.lemon/ports.env`; both
launchers load that file into unset port variables and export the result.

The derived state lives in `LemonCore.Setup.Readiness`, so the setup wizard,
first-run TUI gate, and Web UI agree on exactly what is missing. The browser is
read-only during setup: it lists pending items and rejects prompts/uploads until
the shared state is ready.

The one-line installer starts `lemon setup` by default when it has a controlling
terminal. `--skip-setup`, an unavailable terminal, and the simulation profile
defer that interaction. The first interactive TUI launch consults the same
readiness predicate and runs setup before starting an unconfigured agent; if
setup remains incomplete, it directs the user to `lemon setup`.

`lemon model` is the focused provider onboarding command. It stores the
credential in encrypted secrets, updates the provider configuration, and can
set the default provider/model. Use the full `lemon setup` journey when config
and secrets may not exist yet or when live provider verification is required.

Onboarding serializes credential/config changes, writes TOML atomically, and
compensates failed writes or runtime reloads. `--config-path` selects the file
to save and verify. Only changes to the runtime's global or current project
configuration trigger its reload; another selected file does not activate or
validate unrelated runtime configuration.

## Gateway setup

`lemon gateway setup` provides interactive and non-interactive adapters for
both supported messaging gateways:

- `telegram` stores a Telegram bot token in encrypted secrets, verifies it with
  `getMe`, pairs the owner's chat (send `/start` to the bot; setup polls
  `getUpdates` for up to `--pair-timeout` seconds, default 120), and writes
  `enable_telegram`, `bot_token_secret`, and `allowed_chat_ids` to
  `[gateway.telegram]`. Non-interactive runs require `--chat-id` (repeatable).
- `discord` stores a Discord bot token in encrypted secrets, enables Discord,
  writes its secret reference and a default/allowed channel scope to
  `[gateway.discord]`, and verifies the token with Discord's bot identity API.

```bash
# Installed release: choose Telegram or Discord interactively.
lemon gateway setup

# Configure a specific adapter.
lemon gateway setup telegram
lemon gateway setup discord

# Scripted Telegram pairing without waiting for /start.
lemon gateway setup telegram --non-interactive \
  --token "$TELEGRAM_BOT_TOKEN" --chat-id 12345678

# Source checkout: use the matching wrapper.
./bin/lemon gateway setup discord --non-interactive \
  --token "$DISCORD_BOT_TOKEN" \
  --default-channel-id 123456789012345678 \
  --allowed-channel-id 234567890123456789
```

The Telegram token is persisted as `telegram_bot_token` by default. The
Discord token is persisted as `discord_bot_token` by default and only its
secret key is written to TOML. Pass `--secret-key <name>` to use another key,
`--allowed-guild-id <id>` to restrict by guild as well, or `--skip-smoke` when
the Discord API identity check cannot be reached.

## Onboarding providers

Guided provider setup uses a plain numbered prompt that works consistently
across packaged releases, source checkouts, SSH sessions, and narrow terminals.
Press Enter to accept the displayed default, enter a number or exact label to
choose another option, or enter `q` to cancel. The same selector is used for
providers, authentication methods, models, and confirmation prompts, so setup
does not switch the terminal between cooked and raw modes.

Anthropic provider auth supports API keys or a Claude Pro/Max subscription
login. Raw API keys live in `llm_anthropic_api_key_raw` and are referenced by
`providers.anthropic.api_key_secret`. Browser sign-in (`lemon model anthropic`)
stores a refreshable login in `llm_anthropic_api_key`, referenced by
`providers.anthropic.auth_source = "oauth"` and `oauth_secret`. It listens on
`http://localhost:53692/callback`; when that port is busy it uses Anthropic's
hosted code page and asks for the pasted `code#state`. `lemon model PROVIDER
--status` and `--logout` (implemented by `LemonCli.Setup.ProviderAuth`) show
and remove OAuth logins. See the [CLI guide](../../docs/user-guide/cli.md).

OpenAI Codex browser sign-in starts a temporary loopback HTTP listener before
opening the authorization URL. The listener binds the redirect URI's port
(`http://localhost:1455/auth/callback` by default), captures the authorization
code, returns a completion page to the browser, and then shuts down. If the
port cannot be bound or no callback arrives within two minutes, onboarding
falls back to accepting the callback URL or authorization code manually.

```bash
# Installed release
lemon model --provider antigravity --token <token> --set-default --model gemini-3-pro-high
lemon model --provider gemini --project-id your-gcp-project
lemon model --provider openai-codex --token <token> --set-default --model gpt-6.1-sol
lemon model --provider github-copilot --enterprise-domain company.ghe.com

# Source checkout
./bin/lemon model --provider antigravity --token <token> --set-default --model gemini-3-pro-high
./bin/lemon model --provider gemini --project-id your-gcp-project
./bin/lemon model --provider openai-codex --token <token> --set-default --model gpt-6.1-sol
./bin/lemon model --provider github-copilot --enterprise-domain company.ghe.com

# Contributors can invoke the underlying Mix task directly.
mix lemon.onboard codex --token <token> --set-default --model gpt-6.1-sol
```
