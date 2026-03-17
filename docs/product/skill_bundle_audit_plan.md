# Skill Bundle Audit Plan

Status: proposal

Last reviewed: 2026-03-17

## Goal

Add a stronger audit layer for Lemon skills that:

- audits whole skill bundles, not just `SKILL.md`
- reuses the current deterministic audit checks
- optionally adds an LLM-based malicious-content review
- caches audit results by bundle hash
- rescans automatically when a skill has never been scanned or its bundle changes
- blocks unsafe skills and requires approval for warned skills

This is an incremental safety/control improvement that can support future autonomous skill creation and maintenance.

## Why This Is Needed

Today Lemon already has:

- a deterministic content audit in `LemonSkills.Audit.Engine`
- structural linting in `LemonSkills.Audit.SkillLint`
- install/update blocking for `:block` verdicts
- synthesis draft blocking for `:block` verdicts

What it does not have yet:

- bundle-aware hashing across multi-file skills
- persistent audit state tied to skill version changes
- semantic review of malicious intent that regex rules may miss
- automatic rescanning when supporting files change

This matters because skills are not always single-file. A skill can eventually include:

- `SKILL.md`
- `references/`
- `templates/`
- `scripts/`
- `assets/`

If only `SKILL.md` is hashed or audited, the safety model is incomplete.

## Current State

### Existing deterministic audit

Current audit engine:

- scans `SKILL.md` content
- returns `:pass`, `:warn`, or `:block`
- checks for patterns like destructive commands, remote execution, exfiltration, path traversal, and symlink escape

Current structural lint:

- validates `SKILL.md` exists
- validates frontmatter parses
- requires `name`
- requires `description`
- validates references remain inside the skill directory
- requires a non-empty body
- treats audit `:block` as invalid

### Current hashing

Lemon already stores:

- `content_hash`
- `upstream_hash`

But the current `content_hash` is only the SHA-256 of `SKILL.md`, not the whole bundle.

That is not enough for multi-file audit invalidation.

## Proposed Design

Introduce a new audit model centered on the **skill bundle**.

### Core concepts

#### 1. Bundle hash

Add a deterministic `bundle_hash` for the installed skill directory.

It should cover:

- `SKILL.md`
- allowed supporting files under `references/`, `templates/`, `scripts/`, and `assets/`
- file paths as well as file contents

It should not include:

- lockfiles outside the skill directory
- hidden temp files
- transient editor files
- audit metadata files

#### 2. Audit fingerprint

Do not cache only on `bundle_hash`.

Cache on an `audit_fingerprint` that also includes the versions of the auditing logic.

Recommended inputs:

- `bundle_hash`
- static audit engine version
- structural lint version
- LLM audit policy version
- LLM model identifier

This ensures a skill can be rescanned when audit policy changes even if the skill content does not.

#### 3. Two-stage audit

Stage A: deterministic/static audit

- current `Audit.Engine`
- current `SkillLint`
- always runs

Stage B: optional LLM audit

- configurable
- reviews the whole bundle semantically
- identifies suspicious or malicious intent missed by static rules

Final verdict combines both stages.

## Bundle Hash Design

### Requirements

The hash must be:

- deterministic
- path-sensitive
- content-sensitive
- stable across runs
- easy to recompute

### Proposed algorithm

1. Walk the skill directory recursively.
2. Keep only allowed files:
   - `SKILL.md`
   - files inside `references/`
   - files inside `templates/`
   - files inside `scripts/`
   - files inside `assets/`
3. Normalize every file to a relative path from the skill root.
4. Sort by relative path.
5. For each file, compute:
   - relative path
   - SHA-256 of file bytes
6. Build a canonical manifest string from those pairs.
7. SHA-256 the manifest string to produce `bundle_hash`.

### Why include paths

Including only file contents is not enough. Two bundles with identical bytes but different paths may behave differently.

Examples:

- `scripts/deploy.sh` vs `references/deploy.sh`
- `templates/config.yaml` vs `assets/config.yaml`

Path must be part of the identity.

## LLM Audit Design

### Purpose

The LLM audit should not replace deterministic scanning. It should catch higher-level malicious intent, including cases spread across multiple files.

Examples of what it may catch better than regexes:

- deceptive instructions that encourage hiding actions from the user
- social-engineering phrasing
- stealthy secret collection guidance
- instructions that combine harmless-looking steps into a malicious workflow
- prompt-injection-like behavior framed as "workflow guidance"

### Inputs

The LLM audit should receive:

- skill metadata
- normalized file list
- `SKILL.md`
- selected supporting file contents
- summary of deterministic findings

For very large bundles, supporting files may need truncation or summarization before review.

### Output

The LLM audit should return structured JSON with:

- `verdict`: `pass | warn | block`
- `summary`
- `findings`: list of finding objects
- `confidence`

Each finding should ideally include:

- severity
- file path
- rationale
- quoted or summarized suspicious content

### Configuration

The LLM audit should be optional and configurable:

- enabled/disabled
- model
- timeout
- max bundle bytes or token budget
- policy prompt version

If disabled, Lemon should still run the deterministic audit.

If the LLM is unavailable, Lemon should fall back to deterministic audit rather than failing all installs.

## Verdict Model

Keep the same top-level verdict model:

- `pass`
- `warn`
- `block`

### Decision rules

Recommended final verdict logic:

- if deterministic audit returns `block`, final verdict is `block`
- else if LLM audit returns `block`, final verdict is `block`
- else if deterministic audit returns `warn`, final verdict is at least `warn`
- else if LLM audit returns `warn`, final verdict is `warn`
- else `pass`

### User-facing behavior

For install/update/publish:

- `pass`: proceed
- `warn`: show findings and require approval
- `block`: reject

For synthesized drafts:

- `pass`: allow draft storage
- `warn`: allow draft storage but mark approval required before promotion
- `block`: do not allow draft promotion or discard entirely, depending on pipeline stage

## Rescan Rules

A skill should be audited when:

1. it has never been audited
2. its `bundle_hash` changed
3. static audit version changed
4. lint version changed
5. LLM audit version changed
6. configured LLM model changed

This should apply to:

- install
- update
- publish
- explicit audit/check commands

## Audit State Storage

Audit results need persistent storage.

### Option A: extend `skills.lock.json`

Pros:

- reuse existing provenance storage
- one file to inspect

Cons:

- mixes install provenance with mutable audit results
- may become noisy if audit metadata grows

### Option B: separate audit state file

Example:

- `~/.lemon/agent/skills.audit.json`
- `<cwd>/.lemon/skills.audit.json`

Pros:

- cleaner separation of concerns
- easier to evolve independently

Cons:

- one more file to manage

### Recommended stored fields

Per skill key, store:

- `key`
- `bundle_hash`
- `audit_fingerprint`
- `scanned_at`
- `static_verdict`
- `static_findings`
- `lint_valid`
- `lint_issues`
- `llm_verdict`
- `llm_findings`
- `llm_model`
- `llm_policy_version`
- `final_verdict`
- `approval_required`

## Integration Points

### Installer

During install/update:

1. compute `bundle_hash`
2. check cached audit state
3. if missing or stale, run audit
4. persist audit result
5. block on final `block`
6. require approval on final `warn`

### Synthesis pipeline

For generated drafts:

1. compute `bundle_hash` once the draft exists as a directory
2. run deterministic audit
3. optionally run LLM audit
4. persist audit result alongside draft metadata
5. prevent promotion if blocked

### Explicit audit tooling

Eventually Lemon should have an explicit command to:

- rescan one skill
- rescan all changed skills
- show audit findings
- show which skills are stale relative to current policy version

## Suggested Implementation Phases

### Phase 1: bundle hashing

- add bundle file enumeration
- add deterministic `bundle_hash`
- store it in audit state
- rescan whenever bundle hash changes

No LLM required yet.

### Phase 2: cached deterministic audit state

- persist audit results by `bundle_hash`
- reuse cached results when unchanged
- wire into install/update/publish

### Phase 3: configurable LLM audit

- add optional model-based scan
- define strict JSON schema for findings
- fold into final verdict
- expose config flags

### Phase 4: synthesis integration

- apply bundle-aware audit to generated skills and multi-file drafts
- block or mark drafts based on final verdict

## Resolved Decisions

### Include `assets/` in the bundle hash

Decision: yes.

Reasoning:

- the hash is an identity mechanism, not just an execution-risk mechanism
- assets can still affect behavior indirectly
- path and content changes anywhere in the bundle should invalidate cached audit state

Implementation note:

- include all regular files under `assets/` in `bundle_hash`
- do not assume assets are safe just because they are not executable
- hidden temp files and editor artifacts should still be excluded

### LLM audit input strategy for supporting files

Decision: use a budgeted hybrid approach.

The LLM audit should read:

- raw `SKILL.md`
- raw text content for small and medium supporting text files
- summaries or excerpts for very large text files
- metadata only for binary files unless they are explicitly suspicious

Priority order for raw inclusion:

1. `SKILL.md`
2. `scripts/`
3. `references/`
4. `templates/`
5. `assets/`

Rules:

- text-like files below a configured byte/token threshold are included raw
- large text files are chunked and summarized before final audit
- binary assets contribute to `bundle_hash` but usually do not get passed to the LLM verbatim

This keeps semantic review useful without making audit cost explode on large bundles.

### `warn` drafts should be stored automatically

Decision: yes, but marked as approval-required.

Reasoning:

- drafts are already an intermediate artifact
- warnings are useful for review and refinement
- withholding warned drafts entirely would hide potentially valuable output

Rules:

- `pass`: store draft normally
- `warn`: store draft, persist audit findings, require approval before promotion/install
- `block`: do not allow promotion and preferably skip storage if the content is clearly unsafe

### Audit state should live outside lockfiles

Decision: use separate audit state files.

Recommended files:

- global: `~/.lemon/agent/skills.audit.json`
- project: `<cwd>/.lemon/skills.audit.json`

Reasoning:

- lockfiles should remain provenance/install state
- audit data will evolve faster and may contain richer findings
- keeping audit state separate avoids bloating or overloading the meaning of `skills.lock.json`

The lockfile can still store the latest high-level audit status if convenient, but the detailed cached audit record should live separately.

### Global and project-local audit state should be separate

Decision: yes.

Reasoning:

- the same skill key may exist in both scopes with different contents
- project-local skills override global ones
- audit results must follow the actual bundle being loaded, not just the key

The natural key should be:

- scope
- skill key
- bundle hash

This avoids collisions and makes project-local overrides safe.

### Audit versioning should be explicit and code-owned

Decision: represent audit versions as explicit version constants in code, with LLM policy version configurable only where necessary.

Recommended structure:

- static audit engine version constant
- structural lint version constant
- LLM audit prompt/policy version constant
- configured LLM model name from runtime config

The `audit_fingerprint` should be derived from:

- `bundle_hash`
- static audit version
- lint version
- LLM policy version
- LLM model name

This means:

- policy changes force rescans
- model changes force rescans
- engine rule changes force rescans

It should not rely on ad hoc manual cache busting.

## Recommended Defaults

These should be the initial implementation defaults:

- `assets/` included in `bundle_hash`: yes
- LLM audit enabled by default: no
- LLM audit fallback when unavailable: static audit only
- warned drafts stored: yes
- warned drafts promotable without approval: no
- audit state storage: separate `skills.audit.json`
- audit scope separation: yes
- rescan trigger on audit-policy/model/version change: yes

## Recommendation

This is a strong next step for Lemon.

It improves:

- safety
- trust
- observability
- multi-file correctness

And it prepares Lemon for more autonomous skill creation later without committing to global auto-promotion too early.

The recommended starting point is:

1. add `bundle_hash`
2. cache deterministic audit by hash
3. add optional LLM scan as a second stage

That gives immediate value even before the broader skill-synthesis redesign is complete.
