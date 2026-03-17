# Skill Synthesis Planning

Status: current-state review for planning the next iteration of adaptive skill authoring.

Last reviewed: 2026-03-17

## Goal

Make Lemon better at learning reusable workflows from successful runs, with the long-term goal that bots can author skills for themselves safely and improve future performance.

This document captures:

- what exists today
- what is working well
- what is missing for a real closed learning loop
- the highest-value improvements to plan next

## Current Setup

### Implemented pieces

The current skill synthesis system is real, but it is draft-oriented and mostly manual.

1. Memory documents are written after runs finalize.
2. Candidate selection filters memory documents down to actionable, non-secret, non-trivial runs.
3. Draft generation converts a candidate into a `SKILL.md` draft.
4. Audit runs against draft content before the draft is stored.
5. Drafts are written to `skill_drafts/`.
6. A human can review, edit, publish, or delete the draft.
7. Once published as an installed skill, normal skill retrieval can surface it in future prompts.

Key modules:

- `apps/lemon_core/lib/lemon_core/memory_ingest.ex`
- `apps/lemon_skills/lib/lemon_skills/synthesis/candidate_selector.ex`
- `apps/lemon_skills/lib/lemon_skills/synthesis/draft_generator.ex`
- `apps/lemon_skills/lib/lemon_skills/synthesis/pipeline.ex`
- `apps/lemon_skills/lib/lemon_skills/synthesis/draft_store.ex`
- `apps/lemon_skills/lib/mix/tasks/lemon.skill.ex`
- `apps/coding_agent/lib/coding_agent/prompt_builder.ex`

### What is not implemented

The system does not currently learn "as it goes" in the runtime.

- `MemoryIngest` stores memory and routing feedback, but it does not trigger synthesis.
- `Pipeline.run/3` exists, but it is only called from the `mix lemon.skill draft generate` CLI flow.
- Drafts are not active skills.
- Drafts do not affect future prompts until a human publishes them.
- There is no feedback loop measuring whether a synthesized skill improved later runs.

In practice, this means Lemon can synthesize draft notes from past runs, but it does not yet autonomously get smarter from them.

## What Is Good

### The pipeline is decomposed cleanly

The implementation is broken into reasonable units:

- candidate selection
- draft generation
- audit
- draft storage
- manual publish flow

This is a good foundation because each piece can be improved independently without rewriting the whole system.

### Safety posture is conservative

The current system already avoids the worst failure mode: auto-installing unsafe garbage.

- Candidate selection rejects secret-looking content.
- Audit blocks dangerous patterns before draft storage or install.
- Promotion to an installed skill is a separate step.
- Installed skills still flow through the normal installer and audit path.

For self-authored skills, this caution is correct.

### It reuses the existing skill system

Synthesized drafts are not a separate format. They become ordinary skills after promotion.

That is good because it avoids building a second retrieval, storage, and rendering stack. Once a skill is published, the existing registry and prompt builder can use it.

### Retrieval integration already exists for installed skills

The coding agent already uses `LemonSkills.find_relevant/2` during prompt construction. If a synthesized draft becomes a real installed skill, it can influence future runs immediately without additional integration work.

### Test coverage exists for the core pieces

Targeted tests currently exist for:

- candidate selection
- draft generation
- draft storage
- rollout gate evaluation

That gives a decent base for iterating safely.

## What Could Be Improved

### 1. No runtime trigger

This is the biggest gap.

Today, synthesis is a manual maintenance command. For self-improving bots, synthesis needs to happen automatically after eligible successful runs, or on a background cadence, without requiring a human to invoke a Mix task.

Current reality:

- memory ingest is automatic
- routing feedback is automatic
- skill synthesis is manual

That breaks the learning loop.

### 2. No notion of confidence or promotion readiness

A single successful run can produce a draft. That is useful for brainstorming, but weak for autonomous learning.

The current system does not ask:

- has this pattern repeated multiple times?
- did it succeed across different sessions?
- is the tool sequence stable?
- does a similar installed skill already exist?
- is the generated draft likely to retrieve well?

Without those checks, the system can produce drafts that are too specific, redundant, or low-value.

### 3. Generated skills are structurally weak for retrieval

The generator currently produces:

- `name`
- `description`
- optional `requires_tools`
- `metadata.lemon.category`
- `synthesized: true`
- a body built mostly from `prompt_summary` and `answer_summary`

It does not generate stronger retrieval aids such as:

- `keywords`
- usage triggers
- normalized problem statements
- examples
- bundled scripts
- references
- aliases or alternate phrasings

Because relevance scoring strongly benefits name and keyword matches, synthesized skills will usually retrieve worse than curated skills.

### 4. The current task taxonomy is too coarse

`TaskFingerprint` currently reduces work to families like:

- `:code`
- `:query`
- `:file_ops`
- `:chat`
- `:unknown`

This is enough for rough routing and filtering, but not enough for high-quality skill synthesis. A generated skill from a `:code` task may still be far too broad or mix unrelated patterns.

For planning, this means synthesis likely needs richer clustering than the current task-family heuristic alone.

### 5. There is no de-duplication against the installed skill corpus

Candidate de-duplication only collapses identical normalized prompt summaries.

It does not check:

- whether a near-equivalent installed skill already exists
- whether a draft overlaps with another draft semantically
- whether the generated key is colliding with a more useful skill

This will matter quickly if synthesis becomes automatic.

### 6. No observed-outcome loop after publication

There is currently no mechanism to answer:

"Did this synthesized skill actually help future runs?"

That is the core metric for self-improvement. Without it, the system can accumulate more skills without becoming more effective.

Future planning should include:

- attribution of skill usage to later runs
- outcome tracking when synthesized skills are loaded
- disable/rollback for harmful or noisy synthesized skills

### 7. Docs and implementation are out of sync

The docs currently describe a broader feature set than the code implements.

Examples:

- docs mention `--session` and `--workspace` generation flows
- docs imply richer draft status reporting
- docs use `.../skills/` paths while the implementation uses `.../skill/`

This is mostly a documentation problem, but it will create planning confusion if left unresolved.

### 8. No end-to-end pipeline test

The pieces are tested individually, but there does not appear to be an end-to-end synthesis pipeline test that verifies:

- documents fetched from memory
- candidate filtering
- audit handling
- draft storage behavior
- skip reasons
- feature-flag behavior

That test should exist before enabling more automation.

## Quality of the Current Design

Overall assessment:

- Foundation: good
- Safety: good
- Manual usability: decent
- Retrieval quality of synthesized output: weak
- Runtime autonomy: missing
- Closed-loop learning: missing

The current system is a draft synthesis pipeline, not yet a self-improving skill system.

## Planning Priorities

### Priority 1: automate draft creation, not auto-promotion

The next step should be safe automation:

- trigger synthesis automatically after eligible successful runs or on a background job
- keep output in `skill_drafts/`
- do not auto-install by default

This creates real learning throughput without introducing unsafe automatic behavior.

### Priority 2: add draft scoring and clustering

Before autonomous promotion, add ranking signals such as:

- repeated success count
- cross-session recurrence
- stable toolset
- low similarity to existing installed skills
- retrieval confidence

This should decide which drafts are worth review or promotion.

### Priority 3: improve generated skill shape

The generator should produce more retrieval-friendly and reusable skills:

- keywords
- normalized trigger phrases
- concise "when to use" sections
- distilled steps instead of raw summaries
- optional examples
- optional extracted scripts for deterministic workflows

The generated output should look more like a curated skill and less like a copied run summary.

### Priority 4: measure downstream impact

Add instrumentation for:

- which skills were loaded for a run
- whether a loaded synthesized skill correlated with success or failure
- whether a newly promoted skill improved relevant future runs

Without this, synthesis cannot graduate from content generation into actual learning.

### Priority 5: add rollback and aging

Self-authored skills should not be permanent by default.

Plan for:

- draft expiration
- inactive-skill pruning
- auto-demotion of poor-performing synthesized skills
- explicit provenance on every generated skill

## Suggested Roadmap

### Phase 1: make the current draft system operational

- Add automatic synthesis trigger.
- Add pipeline telemetry and metrics.
- Add end-to-end pipeline tests.
- Fix docs to match the actual CLI and paths.

### Phase 2: improve draft quality

- Add similarity checking against existing skills and drafts.
- Add recurrence-based candidate ranking.
- Generate better metadata and retrieval fields.
- Add a review queue sorted by likely value.

### Phase 3: controlled autonomy

- Allow optional auto-promotion for narrow, low-risk cases.
- Prefer project-local promotion first.
- Track downstream run outcomes for synthesized skills.
- Add rollback when a promoted skill degrades outcomes.

## Recommended Product Framing

For planning and naming, it is better to think about this as:

- draft synthesis
- skill curation
- adaptive retrieval
- promotion based on observed impact

not simply:

- "bots write skills for themselves"

The latter is the end state. The current system is much closer to adaptive draft generation with manual promotion.

## Open Questions

- Should synthesis trigger per successful run, per session, or on a background schedule?
- Should generated skills be global by default or project-local by default?
- What evidence threshold is required before a draft is considered reusable?
- How should Lemon detect overlap with existing curated skills?
- Should autonomous promotion ever be allowed for global skills?
- What telemetry proves a synthesized skill improved future runs?

## Relevant Files

- `apps/lemon_core/lib/lemon_core/memory_ingest.ex`
- `apps/lemon_core/lib/lemon_core/task_fingerprint.ex`
- `apps/lemon_skills/lib/lemon_skills/synthesis/candidate_selector.ex`
- `apps/lemon_skills/lib/lemon_skills/synthesis/draft_generator.ex`
- `apps/lemon_skills/lib/lemon_skills/synthesis/draft_store.ex`
- `apps/lemon_skills/lib/lemon_skills/synthesis/pipeline.ex`
- `apps/lemon_skills/lib/mix/tasks/lemon.skill.ex`
- `apps/lemon_skills/lib/lemon_skills/registry.ex`
- `apps/coding_agent/lib/coding_agent/prompt_builder.ex`
- `docs/user-guide/adaptive.md`
- `docs/user-guide/skills.md`

## Hermes Comparison

Hermes takes a notably different approach from Lemon.

Lemon today has:

- an offline-style draft pipeline
- feature-flagged generation
- manual review and publish
- no runtime-triggered synthesis

Hermes has:

- an in-band `skill_manage` tool that the agent can call during normal work
- direct create/edit/patch/delete/write-file operations on skills
- prompt-level policy telling the agent to save reusable workflows and patch stale skills immediately
- a runtime nudge that reminds the agent to persist a reusable approach after long tool loops
- a single live skill directory, not a separate draft store

### What Hermes is doing well

#### 1. It treats skills as active procedural memory

Hermes makes skills part of the normal working loop, not a side pipeline.

The documentation and tool schema both frame skills as the agent's procedural memory, and the tool is available in the core runtime rather than only through a maintenance command.

This is important because it changes agent behavior. The model is explicitly told:

- save a reusable workflow after difficult tasks
- patch skills when they are outdated or incomplete
- maintain skills as part of doing the work

That is much closer to a closed loop than Lemon's current "generate drafts later" model.

#### 2. Hermes supports self-improvement of existing skills, not just synthesis of new ones

Lemon currently focuses on:

- select candidate
- generate draft
- review
- publish

Hermes also supports:

- `patch` for targeted fixes
- `edit` for full rewrites
- `write_file` for adding references/templates/scripts/assets
- `remove_file` and `delete`

That means the agent can refine a skill incrementally during use, instead of waiting for an entirely new synthesized artifact.

This is one of the strongest ideas we should learn from.

#### 3. Hermes uses policy and nudges, not only heuristics

Hermes does not rely only on background logic. It also nudges the model directly:

- after enough tool-calling iterations
- when a complex task just happened
- when a loaded skill turned out to be stale

This is simple but effective. It shifts some synthesis behavior into the model policy layer instead of trying to infer everything from a post-hoc pipeline.

#### 4. Hermes has a unified skill store

All skills live under `~/.hermes/skills/`, including bundled skills, installed skills, and agent-created skills.

That gives Hermes:

- one retrieval path
- one command surface
- one mutation path
- immediate discoverability for newly created skills

Lemon currently splits drafts from installed skills. That is safer, but it also slows down the learning loop.

#### 5. Hermes optimizes for incremental edits

The `patch` action is clearly preferred over full rewrites.

That matters because it:

- reduces token cost
- reduces damage risk
- makes self-maintenance practical
- lets the agent repair an existing skill quickly when it discovers a missing step

This is a better update primitive than forcing most changes through full regenerated documents.

### What Lemon should learn from Hermes

#### 1. Add runtime skill maintenance, not just draft generation

Lemon should probably keep the draft pipeline, but add an in-band maintenance path.

That could mean introducing a guarded tool for:

- patching an existing skill
- creating a project-local draft skill directly from the current task
- adding reference files or templates to an existing skill

The key idea is that learning should be possible while the agent is working, not only after the fact.

#### 2. Separate "create new" from "patch existing"

Hermes is right that these are different operations.

For Lemon, the likely design improvement is:

- draft synthesis for new skills
- direct patch flow for already-installed skills

That would let Lemon improve curated or promoted skills immediately when they fail in practice, without regenerating a full replacement.

#### 3. Use prompt policy to encourage persistence

Lemon currently has pipeline mechanics but very little runtime instruction telling the agent when to capture or repair procedural knowledge.

A useful improvement would be adding policy text in the coding-agent prompt along the lines of:

- after a difficult or iterative task, consider saving a reusable workflow
- if a loaded skill was wrong or incomplete, patch it before finishing
- do not save one-off work; save repeatable procedures

That should materially improve skill capture frequency even before deeper automation exists.

#### 4. Prefer project-local first for self-authored skills

Hermes writes directly into the main skill store. That is fast, but it increases risk.

For Lemon, the safer adaptation is:

- keep global skill promotion conservative
- allow faster project-local creation/patching
- make project-local self-authored skills the first autonomous lane

That keeps the best part of Hermes' immediacy without overexposing every future session to low-quality synthesized content.

#### 5. Support richer mutation than SKILL.md replacement

Hermes can add supporting files to a skill. Lemon should eventually support that too.

A good skill is often not just instructions. It may need:

- references
- templates
- scripts
- assets

If Lemon only synthesizes a `SKILL.md`, it will plateau at "documentation memory" rather than "operational procedural memory."

#### 6. Make retrieval and repair part of the same loop

Hermes explicitly couples:

- loading a skill
- noticing it is stale
- patching it immediately

Lemon should copy that loop.

The strongest product improvement here is not more generation. It is making skill use generate repair signals automatically.

### What Lemon should not copy directly

Hermes is more aggressive about direct skill mutation. We should not blindly copy that at global scope.

Hermes-style direct writes are powerful, but Lemon should preserve stricter controls around:

- safety review
- promotion
- rollback
- provenance
- measurement of downstream impact

The right adaptation is likely:

- Hermes-style in-band patching for local/project scope
- Lemon-style staged promotion for global scope

### Recommended Hybrid Direction

The best next design for Lemon is probably a hybrid of both systems:

1. Keep Lemon's candidate selection, audit, draft store, and promotion model.
2. Add a runtime skill-maintenance tool for patching and enriching existing skills.
3. Add model nudges after long/difficult tool loops.
4. Make project-local skills the default autonomous lane.
5. Track whether loaded or patched synthesized skills improve future outcomes.

That would preserve Lemon's stronger safety posture while adopting Hermes' much better learning ergonomics.
