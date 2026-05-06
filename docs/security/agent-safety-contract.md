# Agent Safety Contract

Lemon agent safety is layered. No single check is the boundary; tool exposure,
approvals, memory screening, skill audits, and telemetry each cover a different
failure mode.

## Tool Exposure

`CodingAgent.ToolPolicy` is the first boundary. Runtime profiles decide which
tools are available, which are blocked, and which require approval.

- `:full_access` is for trusted local coding work.
- `:orchestrator` keeps delegation tools for parent sessions.
- `:leaf_worker` keeps normal work tools but removes recursive delegation.
- `:read_only`, `:safe_mode`, `:subagent_restricted`, `:no_external`, and
  `:minimal_core` remove or gate write-capable and external tools.

New built-in tools must be classified in the relevant policy profiles before
they are exposed through `CodingAgent.ToolRegistry`.

## Approvals

`LemonCore.ExecApprovals` is the human/admin gate for sensitive actions.
Approvals may be one-shot, session-scoped, agent-scoped, or global. Denials are
explicit and must be respected by callers.

Use approval gates when a tool can mutate files, execute commands, install
code, call external systems with side effects, or change local trust state. Do
not use approval prompts as a substitute for removing a tool from a restricted
profile.

## Durable Memory

Durable memory stores summaries, not raw transcripts. `LemonCore.MemoryIngest`
builds `MemoryDocument` records after run finalization and writes them to
`LemonCore.MemoryStore` only when the feature flag enables session search.

Before a document is stored or mined for skill synthesis,
`LemonCore.MemorySafety` screens `prompt_summary` and `answer_summary` for
secret-looking content such as password assignments, API keys, private-key
headers, and JWT-like tokens. Matching documents are skipped rather than
redacted in place.

`search_memory` is read-only recall. `memory_topic` creates explicit topic files
under `memory/topics/` for durable project context. Procedural workflows belong
in audited skills, not memory topics.

## Skills

Skill reads and writes have different trust boundaries:

- `read_skill` is read-only and emits redacted load telemetry.
- `skill_manage` writes project or global skills and runs audit checks.
- Installer flows use `LemonCore.ExecApprovals` before install/update/uninstall.
- `LemonSkills.Audit.Engine` scans auditable bundle files.
- `LemonSkills.Audit.BundleAudit` caches results by bundle hash and audit
  fingerprint.
- `:block` verdicts are refused; `:warn` verdicts require explicit approval.

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
4. Keep durable memory writes behind `LemonCore.MemorySafety`.
5. Route reusable procedural knowledge through audited skills.
6. Emit redacted telemetry with run/session provenance.
7. Add focused deterministic tests and, when model behavior matters, an opt-in
   live-model eval.

*Last reviewed: 2026-05-06*
