# Agent Safety Contract

Lemon agent safety is layered. No single check is the boundary; tool exposure,
approvals, memory screening, skill audits, and telemetry each cover a different
failure mode.

## Tool Exposure

`CodingAgent.ToolPolicy` is the first boundary. Tool-policy profiles decide which
tools are available, which are blocked, and which require approval.

- `:full_access` is for trusted local coding work.
- `:orchestrator` keeps delegation tools for parent sessions.
- `:leaf_worker` keeps normal work tools but removes recursive delegation.
- `:read_only` allows the read-tool list; `:safe_mode` denies the dangerous-tool list.
- `:subagent_restricted` denies dangerous tools and requires approval for
  `write` and `edit`; `:no_external` denies the external-tool list.
- `:minimal_core` is a curated tool allowlist, not a read-only or side-effect-free
  profile. It includes file writes, shell execution, and browser tools.

New built-in tools must be classified in the relevant policy profiles before
they are exposed through `CodingAgent.ToolRegistry`. Restricted tool lists and
approval checks do not isolate arbitrary host code or automatically classify
third-party extensions. Invalid custom-policy handling and unknown-profile
fallbacks require their own validation; an approval gate is not a replacement
for those checks.

## Approvals

`LemonCore.ExecApprovals` is the human/admin gate for sensitive actions.
Approvals may be one-shot, session-scoped, agent-scoped, or global; existing
node-scoped policy can also satisfy a request. Denials are explicit and must
be respected by callers.

`CodingAgent.ToolExecutor` executes a gated tool only after an explicit approved
response with a supported scope. Approval request exceptions, exits, throws,
malformed replies, and unsupported scopes fail closed. An unavailable approval
service never produces automatic authorization. Raw service error terms are
excluded from tool results and logs; callers receive bounded error categories.
The failure boundary covers the approval request only, so exceptions raised by
an approved tool are not reclassified as authorization failures.

Use approval gates when a tool can mutate files, execute commands, install
code, call external systems with side effects, or change local trust state. Do
not use approval prompts as a substitute for removing a tool from a restricted
profile. A supported approval authorizes that invocation; it is not an
exactly-once guarantee for external effects or a process-crash recovery policy.

## Durable Memory

The run-history search index stores summaries rather than complete transcripts.
`LemonMemory.Ingest` builds `LemonMemory.Document` records after run finalization.
When the feature flag enables session search, the default `LemonMemory.Store`
setting routes ingest writes through `LemonMemory.Providers` to the configured
provider chain.
Session transcript persistence is a separate surface.

Before a document is stored or mined for skill synthesis,
`LemonMemory.Safety` screens `prompt_summary` and `answer_summary` for
secret-looking content such as password assignments, API keys, private-key
headers, and JWT-like tokens. Matching run-derived documents are skipped rather than
redacted in place.

Reviewed source learning follows a separate explicit-confirmation path through
`LemonSkills.Learn`. It binds confirmation to the exact source and destination
state, redacts confirmed content again at the durable boundary, and writes a
memory document plus an audited skill draft. This path does not rely on the
run-ingest feature flag.

`search_memory` is read-only recall. `memory_topic` creates explicit topic files
under `memory/topics/` for durable project context. Procedural workflows belong
in audited skills, not memory topics.

## Skills

Skill reads and writes have different trust boundaries:

- `read_skill` is read-only and emits redacted load telemetry.
- `skill_manage` writes project or global skills and runs audit checks.
- Installer flows use `LemonCore.ExecApprovals` for install/update/uninstall
  unless ordinary approval is pre-authorized or configured off.
- `LemonSkills.Audit.Engine` scans auditable bundle files.
- `LemonSkills.Audit.BundleAudit` caches results by bundle hash and audit
  fingerprint.
- `:warn` verdicts require approval unless explicitly pre-authorized through
  the installer's `:approve` option.
- `:block` verdicts require a separate exact-bundle security-override approval;
  the ordinary `:approve` option cannot bypass a block. Denial, timeout, or an
  unavailable approval service refuses the operation.

Auditable bundles include `SKILL.md` plus supported files under `references/`,
`templates/`, `scripts/`, and `assets/`. Symlinked bundle entries are rejected
so audits cannot escape the skill root.

## Observability

Safety-relevant operations must emit enough metadata to audit behavior without
recording sensitive payloads:

- tool/session provenance for tool calls and tool results
- redacted skill load/write telemetry
- missed-skill and missed-learning observations
- approval request and resolution events
- memory search and durable topic creation traces

Telemetry should identify the operation, actor, run/session, and outcome. It
must not include skill bodies, patch payloads, command secrets, or memory
contents that were rejected by safety screening.

## Change Checklist

When adding or changing an agent capability:

1. Classify the tool in `CodingAgent.ToolPolicy`.
2. Add approval gates for side effects that remain available to trusted profiles.
3. Validate user or model-provided structured arguments before side effects.
4. Keep durable memory writes behind `LemonMemory.Safety`.
5. Route reusable procedural knowledge through audited skills.
6. Emit redacted telemetry with run/session provenance.
7. Add focused deterministic tests and, when model behavior matters, an opt-in
   live-model eval. Approval tests must cover exceptions, exits, throws, invalid
   responses, denied decisions, timeouts, and valid approvals.

The September review covers dispatch and approval failure semantics; it is not
an exhaustive security audit of every tool, skill source, or storage backend.

*Last reviewed: 2026-09-07*
