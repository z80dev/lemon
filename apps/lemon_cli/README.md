# Lemon CLI

`lemon_cli` is the user-facing command boundary for packaged Lemon releases.
`LemonCli.CLI.main/1` is the one process-halting boundary: it receives the
forwarded argument vector from the release launcher and turns dispatch results
into exit codes. Its non-halting `run/1` and command handlers are shared by
tests and source-checkout Mix adapters, so release commands do not depend on
Mix at runtime.

The runtime CLI is included in `lemon_runtime_min` and `lemon_runtime_full`
artifacts. The `sim_broadcast_platform` artifact intentionally does not bundle
`lemon_cli`; it supports only its release-specific `doctor --bundle` path.

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
wrapper. Direct Mix tasks remain contributor-level alternatives, not the
recommended commands for users of a packaged release.

Packaged and Mix `secrets check` / `secrets import-env` commands read the same
ordered environment-secret names from `LemonCore.Secrets.EnvCatalog`, keeping
release and source-checkout behavior aligned.

External 1Password, Bitwarden Secrets Manager, and command sources remain
read-only fallbacks behind the encrypted Lemon store. Their source and packaged
diagnostics share `lemon secrets sources status|test`; both surfaces report
only readiness, stable provenance, counts, byte counts, and error kinds.

| Purpose | Installed release | Source checkout | Contributor Mix adapter |
| --- | --- | --- | --- |
| First-time setup | `lemon setup` | `./bin/lemon setup` | `mix lemon.setup` |
| Configure a model provider | `lemon model --provider anthropic` | `./bin/lemon model --provider anthropic` | `mix lemon.onboard anthropic` |
| Configure Telegram or Discord | `lemon gateway setup` | `./bin/lemon gateway setup` | `mix lemon.setup gateway` |
| Diagnostics | `lemon doctor` | `./bin/lemon doctor` | `mix lemon.doctor` |
| Open the local Web UI | `lemon web` | `./bin/lemon web` | Start the full runtime directly |
| Validate/show config | `lemon config validate` | `./bin/lemon config validate` | `mix lemon.config validate` |
| Manage encrypted secrets | `lemon secrets status` | `./bin/lemon secrets status` | `mix lemon.secrets.status` |
| Inspect/test external secret sources | `lemon secrets sources status` | `./bin/lemon secrets sources test` | Use the same Mix-free command boundary |
| Inspect channel readiness | `lemon channels` | `./bin/lemon channels` | `mix lemon.channels` |
| Inspect/edit provider routing | `lemon providers status|fallback|pool` | `./bin/lemon providers status|fallback|pool` | `mix lemon.providers` (read-only) |
| Review/activate cataloged blueprints | `lemon blueprints daily-note --profile operator` | `./bin/lemon blueprints daily-note --profile operator` | Use the same control-plane command boundary |
| Back up or restore durable user state | `lemon backup create` | `./bin/lemon backup create` | Call `LemonCli.CLI.run/1` from contributor tooling |
| Manage specialist profiles | `lemon profile list` | `./bin/lemon profile list` | Use the same packaged command boundary |
| Preview/resolve bounded context | `lemon context preview|resolve ...` | `./bin/lemon context preview|resolve ...` | Call `LemonCore.Context` from IEx/tests |
| Manage durable sessions | `lemon sessions list` | `./bin/lemon sessions list` | Call `LemonCore.SessionLifecycle` from IEx/tests |
| Review/confirm learning from bounded sources | `lemon learn '@file:guide.md'` | `./bin/lemon learn '@file:guide.md'` | Call `LemonSkills.Learn.review/2` from IEx/tests |
| Safely update a managed release | `lemon update plan|apply|history|rollback` | `./bin/lemon update check|history` (binary mutation fails closed) | `mix lemon.update` remains source maintenance |
| Generate shell completion | `lemon completion zsh` | `./bin/lemon completion zsh` | Call `LemonCli.CompletionCommand.render/2` from IEx/tests |

## Command registry and completion

`LemonCli.CommandRegistry` is the single source for Mix-free runtime-family
dispatch, top-level help, command help, and shell completion metadata. It
contains setup, model, gateway, doctor, config, secrets (including external
source diagnostics), channels, providers, blueprints, profile, backup, context,
sessions, update, and completion. Launcher-only
metadata is separated into source and release sets so generated scripts never
advertise commands the current launcher cannot run.

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
overrides, and secret values are not CLI inputs. A source checkout needs its
unified runtime running first (`./bin/lemon --daemon`); the packaged launcher
starts its daemon when necessary.

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
to the authenticated loopback control plane and calls `profile.chat`. The
packaged launcher starts the daemon when needed; source users start
`./bin/lemon --daemon` before `./bin/lemon profile chat`. The request sends only
the profile ID, prompt, queue mode, and optional model override—working
directory and execution node are resolved again from the profile by the
long-running runtime.

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

When setup onboards a provider, it always performs offline configuration checks
and performs the provider's live credential check by default. Use
`lemon setup --skip-verify` or `lemon setup provider --skip-verify` only to
defer that live check when offline; a failed verification is not reported as a
completed setup.

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

## Gateway setup

`lemon gateway setup` provides interactive and non-interactive adapters for
both supported messaging gateways:

- `telegram` stores a Telegram bot token in encrypted secrets and verifies it
  with the Telegram Bot API.
- `discord` stores a Discord bot token in encrypted secrets, enables Discord,
  writes its secret reference and a default/allowed channel scope to
  `[gateway.discord]`, and verifies the token with Discord's bot identity API.

```bash
# Installed release: choose Telegram or Discord interactively.
lemon gateway setup

# Configure a specific adapter.
lemon gateway setup telegram
lemon gateway setup discord

# Source checkout: use the matching wrapper.
./bin/lemon gateway setup discord --non-interactive \
  --token "$DISCORD_BOT_TOKEN" \
  --default-channel-id 123456789012345678 \
  --allowed-channel-id 234567890123456789
```

The Discord token is persisted as `discord_bot_token` by default and only its
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

Anthropic provider auth supports API keys or Claude subscription OAuth. Raw API
keys live in `llm_anthropic_api_key_raw` and should be referenced by
`providers.anthropic.api_key_secret`. OAuth-backed Claude Max usage keeps using
`llm_anthropic_api_key` plus `providers.anthropic.auth_source = "oauth"` /
`providers.anthropic.oauth_secret`, and Lemon prefers refreshable Claude Code
credentials from `~/.claude/.credentials.json` over a stale static
`CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_TOKEN`.

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
lemon model --provider openai-codex --token <token> --set-default --model gpt-5.2
lemon model --provider github-copilot --enterprise-domain company.ghe.com

# Source checkout
./bin/lemon model --provider antigravity --token <token> --set-default --model gemini-3-pro-high
./bin/lemon model --provider gemini --project-id your-gcp-project
./bin/lemon model --provider openai-codex --token <token> --set-default --model gpt-5.2
./bin/lemon model --provider github-copilot --enterprise-domain company.ghe.com

# Contributors can invoke the underlying Mix task directly.
mix lemon.onboard codex --token <token> --set-default --model gpt-5.2
```
