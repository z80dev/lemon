# Threat Model & Security Posture

_Last reviewed: 2026-08-10_

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
| Package graph | Declared dependencies | Undeclared cross-package reach | Empty grandfather allowlist (`LemonCore.Quality.ArchitectureRulesCheck`) |
| Published tarball | Files you intend to ship | Gitignored local secrets in the tree | `exclude_patterns` in each package's `mix.exs` |

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

- **No key rotation.** Re-encrypting existing secrets under a new master key is
  not implemented. This is a *known, documented gap* (item 1.5 in
  `docs/platform-split.md`, and the `LemonCore.Secrets` moduledoc), not an
  oversight — if the master key is exposed, rotation today means re-entering
  secrets, not an in-place re-wrap.
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
# apps/lemon_channels/mix.exs
files: ~w(lib priv mix.exs README.md CHANGELOG.md LICENSE),
exclude_patterns: [~r/\.env/, ~r/node_modules/],
```

**Reviewer checklist for any new published package:** the `files` list should be
an allowlist (not `.`), and if it includes `priv`, `exclude_patterns` must
exclude `\.env` and any local-only build artifacts. `mix hex.build` and the
tarball-audit lane verify the shipped file set. Never assume `.gitignore`
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

**Bounded body.** `Plug.Parsers` enforces a configurable `max_body_bytes`;
over the limit the caller gets `413` instead of the server buffering unbounded
input. The limit is resolved per request, not frozen into the pipeline.

**Honest delivery status.** If the message cannot reach the router, the webhook
returns `503` (asking a mail provider to redeliver) rather than falsely
acknowledging — losing someone's mail silently is worse than a retry.

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

## 5. Untrusted external content

Content from outside the trust boundary — email bodies, web-search/fetch
results, other agents' output — is wrapped before it reaches a model, by
`LemonAgent.Security.ExternalContent` (with a `CodingAgent.Security.ExternalContent`
counterpart for tool results).

`wrap_external_content/2` fences the content between explicit
`<<<EXTERNAL_UNTRUSTED_CONTENT>>>` markers, prefixed with a security notice
instructing the model to treat everything inside as data, never as instructions
or tool-policy overrides. Crucially, it **sanitizes those markers out of the
content first** (`sanitize_markers/1` rewrites any embedded
`<<<EXTERNAL_UNTRUSTED_CONTENT>>>` / end marker), so a malicious email cannot
inject a fake "end of untrusted content" marker to break out of the fence. The
source is labelled (`Email`, `Webhook`, `Web Search`, …) so the model knows the
provenance.

This is a **defense-in-depth mitigation against prompt injection, not a
guarantee.** A sufficiently capable model can still be influenced by
instructions embedded in untrusted content. The wrapping raises the bar and
makes provenance explicit; it does not make the model immune. Treat any action
an agent takes *because of* external content as untrusted until an approval gate
or a human confirms it.

## 6. The boundary guarantee (blast radius)

Lemon's package graph is enforced, not merely documented. The architecture
lane (`LemonCore.Quality.ArchitectureRulesCheck`) fails the build on any
cross-package reference that violates the dependency direction, and its
grandfather allowlist is **empty**:

```elixir
@grandfathered []
```

An empty allowlist means there are **zero** exempted violations — every
cross-package reference in the tree is a declared dependency. For a security
reviewer, this bounds blast radius and supply-chain reasoning: a published
package reaches only what its `mix.exs` says it reaches, so auditing one
package's dependencies is sufficient to know what it can touch. There is no
hidden runtime reach around the declared graph except the two explicitly
documented behaviour seams (`LemonCore.RouterBridge`,
`LemonCore.EngineRuntime`), which cross the boundary through a behaviour with no
compile-time edge.

## What a reviewer should check

1. **Secrets:** confirm `Crypto` uses AES-256-GCM with per-secret HKDF keys and
   random salt/nonce; confirm the master-key chain fails closed; note that key
   rotation is a known gap.
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

- **Secret key rotation** is not implemented (`docs/platform-split.md` item 1.5).
- **Prompt injection** via untrusted content is mitigated, not solved (§5).
- **Local host compromise** is out of the threat model — anything that can read
  the master key source can decrypt secrets (§1).
