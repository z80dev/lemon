# Threat Model & Security Posture

_Last reviewed: 2026-11-11_

This document is for two readers: an **operator** deciding how to run Lemon
safely, and a **security reviewer** auditing what the platform actually
guarantees. It describes the machinery, names the real modules, and is explicit
about what is *not* protected.

Lemon is local-first: it runs on your machine or your server, under your
credentials, in a working directory you choose. Most of its power — reading
files, running commands, calling providers — is available by design, so the
security story is about the boundaries around that power, not about locking the
agent out of its own job.

For the layered agent-safety story (tool profiles, memory screening, skill
audits), see [`agent-safety-contract.md`](agent-safety-contract.md) and
[`safety.md`](safety.md). For how to report a vulnerability and what is in
scope, see [`SECURITY.md`](https://github.com/z80dev/lemon/blob/main/SECURITY.md). This document focuses on the
cryptographic, network, and boundary machinery those docs assume.

## Trust boundaries at a glance

| Boundary | Trusted side | Untrusted side | Enforced by |
|---|---|---|---|
| Secret storage | Master key holder | Anyone reading the store at rest | AES-256-GCM + per-secret HKDF (`LemonCore.Secrets.Crypto`) |
| Inbound webhooks | Caller with the shared token | The open internet | `authorized?/1` before body parse, timing-safe token compare, body limit (`LemonChannels.InboundHttp`) |
| Tool side effects | Human/admin approver | The model's chosen actions | Approval gates (`LemonCore.ExecApprovals`) + tool policy |
| Model context | System + operator instructions | Email bodies, web content, external agents | Untrusted-content wrapping (`LemonAgent.Security.ExternalContent`) |
| Package graph | Declared dependencies | Undeclared cross-package reach | `deps/0` policy + namespace-reference check (`LemonCore.Quality.ArchitectureCheck`) |
| Published tarball | Files you intend to ship | Gitignored local secrets in the tree | `exclude_patterns` in each package's `mix.exs` |

## Listener exposure

| Listener | Default bind / port | Exposure policy |
| --- | --- | --- |
| Control plane | `127.0.0.1:4040` | Operator/node WebSocket authentication; remote peers get only `GET /ws` and `/healthz` by default |
| Node gateway | `127.0.0.1:4044` | Only node/enrollment `/ws` and `/healthz`; operator and tokenless handshakes refused |
| LemonWeb | `127.0.0.1:4080` | Operator login; non-loopback startup requires an operator token |
| Lemon Bot | `127.0.0.1:4100` | Product sessions; private same-user proof for local owner sign-in |
| A2A (optional) | `127.0.0.1:9901` | Peer tokens; tokenless local fallback requires explicit compatibility opt-in |
| epmd / distribution | Loopback | Launcher defaults; explicit cross-host distribution is an operator choice |

**Breaking change:** LAN clients that relied on wildcard binds must explicitly
opt in and restart. The [configuration reference](../config.md#listener-exposure-breaking-default-change)
owns bind variables; the
[November upgrade notes](../release/upgrade-2026-11.md) cover migration.

Off-loopback control-plane peers get only `GET /ws` and `GET /healthz`; Lemon
serves no OpenAI-compatible or single-shot ACP HTTP API. Main and LemonWeb
non-loopback binds require an operator token and reject tokenless-loopback
compatibility. Put TLS in front of browser login. Lemon Bot's separate backend
requires a configured public origin and HTTPS, or an explicitly trusted
encrypted overlay, for remote use.

The loopback `/acp/ws` transport behind `lemon acp` requires the operator token.
A2A requires peer tokens. The legacy tokenless-local compatibility flag is
default-off, only applies when no token is configured, and must never be enabled
behind a reverse proxy. It is not the passwordless Lemon Bot sign-in mechanism.

### Remote workers: expose the node gateway, not the controller

Forward **4044 only** for node enrollment and execution traffic, using Tailscale
Serve or a TLS reverse proxy, or the managed reverse SSH tunnel. Never forward
**4040** as a node tunnel: that is the operator control plane. The node gateway
accepts node/enrollment credentials on `/ws`, reports health on `/healthz`, and
refuses operator and tokenless handshakes. Off-loopback node connections require
`wss://` unless an authenticated, encrypted overlay is explicitly trusted.
See [Add a Bot machine](../user-guide/attaching-a-bot-machine.md) for the
canonical connection procedure. A remote operator backend is a different role:
give it a separate authenticated TLS route restricted to 4040 `/ws`.

Containers bind explicitly inside their network namespace, require an operator
token, and should publish host ports on loopback. Launcher epmd/distribution
defaults are also loopback; an existing pre-upgrade epmd may retain its old
wildcard listener until stopped. See the configuration reference for remediation.

### Same-user loopback ownership

Loopback means “this host,” not “this user.” Before sending node credentials,
workers check that a literal-loopback listener belongs to their OS user.
The guard also covers tunneled MCP requests; absent, foreign or unverifiable
ownership fails closed. Run the controller and SSH tunnel under the worker's
account. `LEMON_NODE_TRUST_LOOPBACK_LISTENER=1` is an explicit opt-out only for
deployments that deliberately trust another local UID; it does not add TLS or
authenticate a remote server. A reverse proxy's loopback source address is not
user identity.

### Distribution cookie

The source and packaged launchers persist the generated distribution cookie at
`~/.lemon/cookie` with mode `0600`. Treat it as a full remote-code-execution
credential, not as a scoped operator token. Both modes pass the selected secret
through `RELEASE_COOKIE`, never a cookie argument. Source mode also accepts
`LEMON_GATEWAY_NODE_COOKIE` / `LEMON_GATEWAY_COOKIE`. The source `--cookie`
option is removed: its value was visible even in the invoking shell's argv.
Restart preserves the running node's cookie in the child environment.

**Boot ordering matters.** On OTP 29, `ERL_FLAGS` and `vm.args` are expanded
into `beam.smp`'s argv, so moving `-setcookie` there does **not** hide it.
Lemon disables automatic distribution and cookie-file lookup with
`-kernel start_distribution false -nocookie`. `LemonCli.Distribution` reuses
OTP's distribution supervisor specification, replacing only the authentication
child's start function. It sets the cookie after `auth` starts but **before**
the `net_kernel` child starts or opens a listener. It never reads or creates
`~/.erlang.cookie`, changes `HOME`, or exposes a listener with another cookie.

This ordering depends on the **private OTP 29 `:erl_distribution` and `:auth`
APIs**, not a public OTP cookie-before-distribution API. Only OTP 29 is
supported by this bootstrap. A different OTP major, changed supervisor contract,
or missing boot guard fails closed with an OTP-versioned error; there is no
argv-cookie fallback. `scripts/test_lemon_launcher_cookie.sh` pins that
contract, checks real `ps` and native OS argv (`/proc/PID/cmdline` on Linux,
`KERN_PROCARGS2` on macOS), and connects actual source and packaged nodes.

The release assembly step removes the stock Elixir launcher's four `--cookie`
options and inserts the initializer immediately after kernel startup in both
server and clean/client boot scripts. Thus `start`, `rpc`, `remote`, and
lifecycle clients use the same ordering; `eval` stays non-distributed unless
explicitly named. Direct release-profile commands select the same per-user
cookie as `bin/lemon`, rather than a cookie baked into the release archive.
The IEx user driver is deferred too: stock IEx can otherwise start a remote
connection while kernel is still booting, before the cookie initializer runs.


Environment variables are still secrets: do not log command environments or
expose them through diagnostics. This does not protect against root or another
process with permission to inspect the runtime's environment or memory.
Do not supply literal cookies through command-line arguments, `ERL_FLAGS`, or
`vm.args`. Loopback defaults and production rejection of the development
cookie remain unchanged.

Packaged `bin/lemon remote` uses the guarded client boot automatically. For a
source remote shell, compile first, then use the same early initializer (from
the checkout root):

```bash
export RELEASE_COOKIE="$(cat "$HOME/.lemon/cookie")"
elixir --no-halt \
  --erl "-user Elixir.LemonCli.Distribution -kernel start_distribution false -nocookie -pa $PWD/_build/dev/lib/lemon_cli/ebin -s Elixir.LemonCli.Distribution boot" \
  +iex --sname lemon_console --remsh lemon@localhost
```

Use the runtime's actual node name (and `--name` for long names).

### Passwordless local owner

The Mac app and `lemon-bot up` can create the workspace owner without an account
form. Local access proves possession of the backend's private, owner-only
`local-access.key`, not just a loopback connection. `lemon-bot open` exchanges
a short-lived, one-use, origin-bound ticket for a product session; browser
tickets last one minute and headless terminal links five minutes. The browser
redemption rejects proxy headers and mismatched origins. Keep these links private.

Local setup and [headless SSH sign-in](../getting-started/lemon-bot.md#headless-or-ssh-server)
do not need a password. Set one in the account's sign-in settings when you need
ordinary email/password login from another browser or device without local/SSH
proof (or use configured SSO). Adding the first password requires a recent local
confirmation; reopening with `lemon-bot open` supplies it. A remote login uses
the product account, never the runtime operator token.

Anyone who can read the backend's private key and database already controls
that workspace. Do not share an OS account with someone who should not have
that authority. Passwordless local ownership does not bypass Bot access,
execution approvals, or macOS permissions.

## 1. Secrets at rest

Provider keys and other secrets are encrypted, never stored in `config.toml` in
plaintext.

**Cipher.** `LemonCore.Secrets.Crypto` encrypts each value with **AES-256-GCM**
(a 12-byte random nonce, a 16-byte authentication tag). The version string
`lemon-secrets-v1` is bound in as the GCM **additional authenticated data**, so
a payload cannot be silently reinterpreted under a future format.

**Key derivation.** Every secret gets its **own** encryption key, derived from
the master key and a fresh 32-byte random salt via **HKDF-SHA256** (RFC 5869).
Nonce and salt are random per encryption, so encrypting the same value twice
yields different ciphertext, and compromise of one derived key does not
generalize. On decrypt, a bad master key, a truncated payload, or a tampered
tag all fail closed as `:decrypt_failed` — GCM verifies integrity before
returning plaintext.

**Master key provisioning.** The master key is resolved through a configurable
provider chain — `LemonCore.Secrets.KeyProvider`, walked in order by
`LemonCore.Secrets.MasterKey`:

```elixir
config :lemon_core, LemonCore.Secrets,
  key_providers: [:keychain, :env, :file],
  key_file: "~/.lemon/secrets_master_key",
  env_var: "LEMON_SECRETS_MASTER_KEY"
```

- `:keychain` — the macOS Keychain (macOS only; skips itself elsewhere).
- `:env` — `LEMON_SECRETS_MASTER_KEY`.
- `:file` — `~/.lemon/secrets_master_key`, written `0600`.

Any other atom is treated as a module implementing the behaviour, so a host
application can plug in a cloud KMS or HSM. A provider says "nothing here, try
the next" with `{:error, :missing}` and "this backend does not exist on this
host" with `{:error, :unavailable}`; any other error is a hard failure surfaced
once the chain is exhausted. Key material must be base64-encoded 32 bytes; a
raw passphrase-like string is rejected (`:weak_master_key`) because there is no
password stretching. `mix lemon.secrets.init` is the bootstrap path. The full
resolution and error semantics are in
[`secrets-and-keychain.md`](secrets-and-keychain.md).

**What is protected:** secret values at rest, against an attacker who reads the
store but does not hold the master key. **What is not:**

- **Rotation is operator-driven.** `lemon secrets rotate-key` re-encrypts every
  stored secret under a new master key and replaces the key in the Keychain
  entry or key file (see [`secrets-and-keychain.md`](secrets-and-keychain.md)).
  It does not re-encrypt store data inside existing backups, and a key exposed
  before rotation still decrypts those copies.
- **Not protected against a compromised host.** A process that can read the
  master key source (keychain access, the env var, the key file) can decrypt.
  The threat model is "encrypted at rest," not "secure against local root."
- **Memory/skill leakage is a separate control.** Durable memory and synthesized
  skills are screened for secret-looking content by `LemonMemory.Safety` before
  storage; see the agent-safety contract.

## 2. Publishing safely (the `priv/.env` lesson)

Hex builds a package tarball by globbing the **working tree**, not the git
index. A file that is `.gitignore`d but happens to exist locally — a bridge's
`node_modules`, a stray `.env` with real credentials — would be swept into the
tarball and published to a public registry. This nearly happened.

The guard is `exclude_patterns` in each publishable package's `mix.exs`:

```elixir
# apps/lemon_ai/mix.exs
files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE),
exclude_patterns: [~r/\.env/, ~r/node_modules/],
```

**Reviewer checklist for any new published package:** the `files` list should be
an allowlist (not `.`), and if it includes `priv`, `exclude_patterns` must
exclude `\.env` and any local-only build artifacts. `scripts/verify_packages`
(`mix hex.build --unpack`, then a consumer build from the unpacked tree) shows the
shipped file set. Never assume `.gitignore`
protects a published tarball — it does not.

## 3. Inbound webhooks — the internet-facing surface

`LemonChannels.InboundHttp` is the one component that accepts requests from the
open internet (today: the email webhook, `LemonChannels.Adapters.Email.Webhook`).
It is hardened on three axes.

**Auth before parse.** A handler implements
`c:LemonChannels.InboundHttp.Handler.authorized?/1`, and
`LemonChannels.InboundHttp.Router` runs it **before** reading the body. An
unauthenticated caller is rejected with `401` without the server ever decoding
their payload — decoding a megabytes-long body (with email, attachments) only to
then return 401 is free work handed to an attacker. Signature schemes that need
the raw body stay in `handle_inbound/1`; the cheap shared-token check runs first.

**Timing-safe token compare.** The email webhook compares a shared token from
the `x-webhook-token` header in constant time:

```elixir
defp secure_equal?(given, token) when is_binary(given) do
  # Byte-size check first; :crypto.hash_equals/2 requires equal-length inputs.
  byte_size(given) == byte_size(token) and :crypto.hash_equals(given, token)
end
```

The byte-size guard is both a correctness requirement of `:crypto.hash_equals/2`
and deliberately ordered so it cannot itself leak length through an early crash.

**Closed when unconfigured.** With no token configured the endpoint rejects
everything with `401` rather than running open — "an inbound mail endpoint that
accepts unauthenticated POSTs is a spam relay into someone's agent." A malformed
config yields *no* token and therefore a 401: unreadable configuration must not
fail open.

**Sender authorization.** The token authenticates the mail *provider*, not the
sender: anyone can mail the provider address with any `From`. After parsing,
`LemonChannels.Adapters.Email.SenderAuth` admits only `From` mailboxes listed
in `gateway.email.inbound.allowed_senders` (exact, case-insensitive; an empty,
missing or malformed list refuses everyone) **and** only with a provider
attestation: the first RFC 8601 `Authentication-Results` verdict stamped with
the pinned `gateway.email.inbound.authserv_id` must report `dmarc=pass` for the
`From` domain or a `dkim=pass` whose signing domain equals it. SPF alone,
foreign or forged lower verdicts, non-passing and missing verdicts are refused,
and without `authserv_id` every sender is refused. A verdict reporting
`dmarc=fail` for the `From` domain is always refused. A refused sender gets
`403` before thread state, attachment writes, the idempotency reservation or
router submission. The guarantee depends on the provider stamping every
message with its own `Authentication-Results` (and stripping inbound copies
claiming its id). The only way to admit mail without a verdict is the explicit
`sender_auth = "from_only_unsafe"` opt-out, which reduces authorization to a
forgeable `From` and is logged as a warning at startup. Accepted email is still
an unverified, non-owner identity downstream.

**Email thread isolation and reply headers.** Email thread state (message→thread
mappings, subject, reference chain) is keyed by inbox and authorized sender, on
both the inbound and outbound paths, so one sender cannot join, read through the
agent's reply, or overwrite another's thread by naming its Message-IDs; legacy
unscoped rows are never adopted. Outbound composition unfolds folded subjects,
refuses any subject or threading id that still carries a line break or control
character, keeps only single-token `left@right` Message-IDs, and refuses to
render any header value that is not a single line, so text from a sender cannot
inject headers (such as `Reply-To`) into the agent's reply.

**Bounded body.** `Plug.Parsers` enforces a configurable `max_body_bytes`;
over the limit the caller gets `413` instead of the server buffering unbounded
input. The limit is resolved per request, not frozen into the pipeline.

**Honest delivery status.** Email requires a provider Message-ID and a durable
idempotency reservation before router submission. Definite rejection returns
`503` only after a token-fenced reservation transition makes the Message-ID
safely eligible for retry. Accepted and ambiguous responses are reported as
successful only after their durable receipt is stored. Every transition is
compare-and-swap fenced by the current lease-owner token, so an expired handler
cannot overwrite a reclaimed delivery. Missing IDs and unavailable idempotency
storage never proceed untracked; router-level fixed-run-ID admission makes a
post-submit lease recovery safe even across a lost acknowledgement.

## 4. Tool execution approvals

`LemonCore.ExecApprovals` is the human/admin gate for side-effecting tool calls
(`bash`, `write`, `edit`, installs, external calls with side effects). It lives
in `:lemon_core` so every app can request and resolve approvals without a
dependency on the router.

A request blocks until it is granted, denied, or times out, and grants are
scoped:

- `:approve_once` — this request only, not persisted.
- `:approve_session` — persisted per session key.
- `:approve_agent` — persisted per agent id.
- `:approve_global` — persisted for all.

Approvals are keyed by `{tool, action_hash}` (plus agent/session scope), so an
approval for one action does not silently authorize a different one. Denials are
explicit and callers must respect them. Approval requests and resolutions emit
telemetry (`ApprovalRequested`/`ApprovalResolved`) for audit. Which tools are
even *available* is a separate, earlier boundary — `CodingAgent.ToolPolicy`
runtime profiles — and approvals are not a substitute for removing a tool from a
restricted profile.

A resolution commits its completion receipt (exact-record CAS) before writing
any standing grant, so a losing transition, cancellation or crash installs no
grant. A non-durable `LemonCore.Store` mutation whose call times out returns
`{:error, :outcome_unknown}`, never a definite failure; approval resolution
surfaces that as `:outcome_unknown` to the waiter, channels and the TUI.
Every approval mutation (pending creation, claim, completion, cancellation,
waiter timeout) and the remote node relay preserve that unknown outcome; the
gated call does not run and nothing is replayed automatically. After the
completion commits, a run that `LemonCore.Store` already finalized fences the
approval to `:expired` before any grant is written. Remote nodes forward
`onceOnly` (required on the wire), so a once-only request is never answered
from, and never installs, a standing grant on the controller.

Lemon Bot's **remembered approvals** are a separate product-level allowance
over eligible native tool groups, not a global runtime grant and not an
exact-command allowlist. Their scope, exclusions and revocation rules are in
the [agent safety contract](agent-safety-contract.md#lemon-bot-remembered-approvals).

## 5. Untrusted external content

Content from outside the trust boundary — email bodies, web-search/fetch
results, other agents' output, memory files — is wrapped before it reaches a
model by `LemonAgent.Security.ExternalContent`. For email,
`LemonChannels.Adapters.Email` fences the whole prompt it builds (sender,
subject, body and attachment lines) with source `Email` before the message is
submitted to the router.

`wrap_external_content/2` fences the content between
`<<<EXTERNAL_UNTRUSTED_CONTENT id="…">>>` and
`<<<END_EXTERNAL_UNTRUSTED_CONTENT id="…">>>` markers, prefixed with a security
notice instructing the model to treat everything inside as data, never as
instructions or tool-policy overrides. The protection against breaking out is
**sanitisation**: anything shaped like a marker inside the content (any case,
spacing or `id`) is rewritten before wrapping, so the only genuine end marker is
the one appended by the wrapper. The `id` (an HMAC of the content under a
per-node key) is not a secret — the model sees it and can repeat it — and is
not what makes forged markers inert; it lets the notice name the closing marker
and keeps identical content byte-identical for the prompt cache. The source is
labelled (`Email`, `Web Fetch`, `Memory`, `Agent Output`, …).

Tool results fail closed. `AgentToolResult` and `ToolResultMessage` default to
`trust: :untrusted`; only the exact atom `:trusted` on the loop's own canonical
message (an audited, platform-authored result produced in this process) is
exempt. Loop-built results for `{:error, _}` returns, raised exceptions and
unexpected values are untrusted and bounded to 16 KiB. `LemonAgent.Loop`
applies `LemonAgent.Security.UntrustedToolBoundary` as the last step before
every provider request, on the messages `convert_to_llm` produced, so every
loop consumer is fenced; map-shaped and non-canonical tool-result messages are
always wrapped. The bound is 60 000 bytes per text block by default (sessions
pass their guardrail bound). Tools contributed through `LemonAgent.ToolRegistry`
and extension tools are forced to `:untrusted` whatever shape they return.
Tool results restored from a session file or imported as maps are always
untrusted: a file is parsed, not authenticated. Subagent questions
(`ask_parent`), child completions delivered to a parent and branch summaries
reinserted into history are fenced as `Agent Output`; branch summarisation
itself sees the branch inside an escaped untrusted boundary, like compaction.

In the system prompt, `USER.md`/`MEMORY.md` and `LemonAgent.ContextRegistry`
sections are fenced as `Memory`/`Contributed Context` data unless a contributor
explicitly marks a section `trust: :trusted`, and they are placed after
instructions, rules and the environment block so a memory write only changes
the prompt tail.

This is a **defense-in-depth mitigation against prompt injection, not a
guarantee.** A sufficiently capable model can still be influenced by
instructions embedded in untrusted content. The wrapping raises the bar and
makes provenance explicit; it does not make the model immune. Treat any action
an agent takes *because of* external content as untrusted until an approval gate
or a human confirms it.

### Repositories Lemon reads on its own

A repository's configuration and attributes are untrusted content too: a
working directory may be an unpacked archive, a shared checkout or a tree an
agent wrote into, and `core.fsmonitor`, hooks, filter, textconv and external
diff drivers, signature display with a chosen `gpg.program`, or a `.git` file
redirect would otherwise make an ordinary `git status` run their programs, and
a workspace `bin/` on `PATH` would substitute `git` itself. Every Git command
Lemon starts without an explicit request (session-start and per-turn
environment context, ignore filtering for `find`/`grep`, the `issue://` origin
lookup, `@git-diff`, `sessions.changes`, omp session discovery and worktree
cleanup checks, support-bundle build info and the source version) runs through
`LemonCore.SafeGit`:

- `git` is `[runtime] git_path` from the global configuration (a project file
  cannot set it) or the first `git` in `/usr/bin`, `/usr/local/bin`,
  `/opt/homebrew/bin`, `/bin`; the inherited `PATH` is never searched, an
  executable inside the repository is refused, Git older than 2.31 is refused,
  and the child's `PATH` is that fixed list;
- the repository is located with file reads under a deadline; metadata files
  (`.git` files, `commondir`, `HEAD`) must be regular and are read by a killable
  child, so a FIFO or device cannot block discovery. The work tree, `.git`, Git
  directory, common directory and `config` must be owned by the Lemon user;
- Git never reads the live repository configuration: `GIT_DIR` is a private,
  freshly created directory with a Lemon-written `config` (format, a few
  comparison settings, the excludes file and remote/upstream data, read with
  `git config --file … --no-includes`), a copy of `HEAD` and links to the
  validated common directory's stores, with `GIT_INDEX_FILE` and
  `GIT_WORK_TREE` fixed. Attributes (including `info/attributes`, which
  `--attr-source` does not disable) can name drivers, but none is defined, and
  an include or `commondir` replaced after validation is never consulted;
- Git runs without a shell, with no system or global configuration
  (`safe.directory` exceptions are never honoured), no transports and no lazy
  fetches; fsmonitor, hooks, pagers, editors, askpass, SSH/proxy commands,
  external diff, credential helpers, signature display and signing programs,
  maintenance and submodule recursion are disabled on the command line;
- only a fixed set of read-only subcommands runs, each with a deadline and an
  output cap, and the process is killed on either.

The Honcho `per_repo` session name reads the repository root without running
Git. The terminal client's status-line branch read uses the same executable
rule, environment, private Git directory and settings, relying on Git's own
ownership check for discovery plus an ownership check of the result. Git
commands an agent runs through its tools, the writes of explicit worktree
isolation (`task`, `omp`; both use the operator-trusted executable), skill
installation and Kanban's controller repositories
(`LemonAutomation.KanbanGitSandbox`) are not automatic reads and keep their own
policies.

## 6. The boundary guarantee (blast radius)

Lemon's package graph is enforced, not merely documented. The architecture
check (`LemonCore.Quality.ArchitectureCheck`, run by `mix lemon.quality`) fails
the build when an app's `deps/0` leaves the policy in
`LemonCore.Quality.ArchitecturePolicy`, or when code under `apps/*/lib`
references another app's namespace without a declared dependency. The only
exemptions are the reference-only exceptions listed in that policy module
(currently `lemon_gateway` → `lemon_ai`, `lemon_automation`), which can never
authorize a `mix.exs` edge.

Apart from those listed exceptions, every cross-package reference in the tree
is a declared dependency. For a security reviewer, this bounds blast radius and supply-chain reasoning: a published
package reaches only what its `mix.exs` says it reaches, so auditing one
package's dependencies is sufficient to know what it can touch. There is no
hidden runtime reach around the declared graph except the two explicitly
documented behaviour seams (`LemonCore.RouterBridge`,
`LemonCore.EngineRuntime`), which cross the boundary through a behaviour with no
compile-time edge.

## What a reviewer should check

1. **Secrets:** confirm `Crypto` uses AES-256-GCM with per-secret HKDF keys and
   random salt/nonce; confirm the master-key chain fails closed and rotation
   preserves recoverability.
2. **Publishing:** confirm every published `mix.exs` uses an allowlist `files:`
   and excludes `\.env`/`node_modules` if it ships `priv`.
3. **Webhooks:** confirm `authorized?/1` runs before parse, the token compare is
   timing-safe with a length guard, the endpoint is closed when unconfigured,
   and the body is bounded.
4. **Approvals:** confirm side-effecting tools route through `ExecApprovals` and
   that denials are respected; confirm restricted profiles remove tools rather
   than relying on prompts.
5. **Untrusted content:** confirm inbound external content is wrapped and its
   fence markers are sanitized; treat the wrapping as mitigation, not a barrier.
6. **Boundaries:** confirm `@grandfathered` is empty and the architecture lane
   is green.

## Known gaps (tracked)

- **Prompt injection** via untrusted content is mitigated, not solved (§5).
- **Local host compromise** is out of the threat model — anything that can read
  the master key source can decrypt secrets (§1).
