# Lemon Missions

## Problem

Lemon needs a durable "large, multi-feature work" mode equivalent to Factory Droid's Missions feature, but implemented on Lemon's existing runtime instead of depending on a separate daemon such as `factoryd`.

The target is behavioral parity at the user level:

- enter a mission from an interactive agent session
- collaborate on a concrete plan before execution
- decompose work into features and milestones
- define or reuse worker skills
- hand execution to a Mission Control orchestrator
- validate at milestone boundaries, not after every small step
- pause, resume, inspect, and recover from failures without losing the plan

## Reverse-Engineered Factory Behavior

Sources:

- official docs: `https://docs.factory.ai/cli/features/missions`
- official guide: `https://docs.factory.ai/cli/user-guides/implementing-large-features`
- local Droid CLI install and local `~/.factory` mission/session artifacts

Observed/confirmed behavior:

- Missions are entered from the interactive session via `/missions`, `/mission`, or `/enter-mission`, not as a top-level CLI subcommand.
- Planning is collaborative and blocking. Droid pushes back on under-specified plans before it will start execution.
- Existing runtime context carries into a mission. Factory explicitly says MCP integrations, skills, hooks, and custom droids still apply.
- Mission execution is controlled by an orchestrator mode ("Mission Control") and uses separate worker sessions for feature execution.
- Validation frequency is milestone-based.
- Factory auto-injects two validator features at milestone completion:
  - `scrutiny-validator`
  - `user-testing-validator`
- Validation failures can lead to new "fix" features, so the real feature count can grow during execution.
- Cost guidance in the official docs is roughly:
  - `total runs ~= #features + 2 * #milestones`
- Mission artifacts are durable on disk. A local mission directory contains at least:
  - `mission.md`
  - `features.json`
  - `validation-contract.md`
  - `validation-state.json`
  - `state.json`
  - `progress_log.jsonl`
  - `working_directory.txt`
  - `AGENTS.md`
- Factory records mission lifecycle events in `progress_log.jsonl`, including acceptance, run start, worker failure, and pause events.
- Worker spawn failures caused by `factoryd` being unreachable are retried once automatically, then the mission pauses with explicit recovery guidance.

Captured live tool sequencing for a small greenfield mission was:

1. `Skill("mission-planning")`
2. `Skill("define-mission-skills")`
3. repo/context reads and environment probes
4. `AskUser` with a structured questionnaire
5. `TodoWrite`
6. validation-readiness dry run via `Execute`
7. `ProposeMission`
8. `Task` review pass over the validation contract
9. creation of mission artifacts and repo-local worker infrastructure
10. coverage check via `Task`
11. repo-local `.factory/` commit
12. `StartMissionRun`

That sequence matters. Droid does not jump directly from proposal acceptance to worker execution.

Local session logs also showed two built-in planning skills at mission entry:

- `mission-planning`
- `define-mission-skills`

The planning skill behavior, inferred from captured prompt bodies, requires:

- feature and milestone definition
- explicit user confirmation on milestones
- infrastructure/services/ports/off-limits capture
- credentials and account setup requirements
- testing strategy and user-testing strategy
- a validation-readiness dry run before proposing the mission

The captured `AskUser` step also showed that Droid prefers a structured questionnaire rather than freeform clarification when it can collapse decisions into a few concrete axes.

### Additional Binary Findings

Inspection of the installed `droid` binary added a few useful constraints:

- The mission feature is explicitly framed in-product as a research preview for "Autonomous Multi-Agent Execution".
- The onboarding copy emphasizes four open research questions:
  - the ideal UI for managing multiple running agents
  - whether swarms and parallelization are needed
  - the largest task scope that can complete autonomously
  - how to validate quality
- Mission Control has dedicated UI surfaces for:
  - Features
  - Workers
  - per-feature detail
  - worker transcript viewing
  - worker handoff viewing
  - mission model settings
- Feature detail UI explicitly exposes:
  - Preconditions
  - Expected Behavior
  - Verification Steps
  - Worker Sessions
- Mission model settings expose separate worker and validator model choices.
- Mission model settings also expose toggles to skip:
  - scrutiny validation
  - user testing validation
- The binary contains mission-specific confirmation UI for:
  - reviewing a mission proposal
  - warning when other missions are already running
  - mission proposal comments before acceptance
- Mission Control UI state labels include:
  - `running`
  - `paused`
  - `completed`
  - `planning`
  - `initializing`
  - `awaiting_input`
- Mission-related command/state strings confirm:
  - `/enter-mission` upgrades the session into mission mode
  - Mission Control is only available in orchestrator sessions
  - once a mission is proposed, exiting mission mode is blocked for the duration of that mission
- I did not find evidence in the binary that Missions requires git worktrees or per-worker git worktree management.

I did not recover the full mission-planning system prompt from the binary itself. The better source for that prompt remains the local session history, which already exposed the planning skill behavior and validation-readiness requirements.

### Additional Live Runtime Findings

The binary was not enough to explain execution. Running a real mission exposed several important implementation details:

- `ProposeMission` acceptance initially creates only a sparse global mission directory:
  - `mission.md`
  - `progress_log.jsonl`
  - `working_directory.txt`
- Droid then materializes the rest of the mission state in a second phase:
  - `validation-contract.md`
  - `validation-state.json`
  - `features.json`
  - mission `AGENTS.md`
- Droid also writes repo-local worker infrastructure under the project root before any feature runs:
  - `.factory/services.yaml`
  - `.factory/init.sh`
  - `.factory/library/architecture.md`
  - `.factory/library/environment.md`
  - `.factory/library/user-testing.md`
  - `.factory/skills/<worker>/SKILL.md`
- The orchestrator runs an explicit coverage check subagent to prove every assertion is claimed by exactly one feature before execution begins.
- In a git repo, Droid stages and commits the repo-local `.factory/` infrastructure before calling `StartMissionRun`.
- The observed commit message for this setup step was:
  - `Add mission infrastructure: skills, services, library, init script`
- The first `StartMissionRun` call is a lightweight control action, not a worker itself. In the probe it carried:
  - `Starting md-summary CLI mission. Two implementation features (parser + CLI entrypoint) followed by automatic validation.`
- After `StartMissionRun`, `progress_log.jsonl` recorded:
  - `mission_run_started`
  - `worker_failed` with a `spawnId` and daemon error
  - a second `mission_run_started` on the automatic retry
  - a second `worker_failed` after the retry

The post-start daemon failure contract is now clear:

1. first worker-spawn failure due to daemon reachability is surfaced as a worker failure
2. the runner returns control with a system instruction to retry exactly once
3. the orchestrator performs one retry by calling `StartMissionRun` again
4. if the same daemon failure happens again, Droid stops retrying and tells the user:
   - run `/quit`
   - restart Droid
   - re-enter mission mode
   - resume the mission

That retry-once rule was observed both in the local probe and in an independent mission transcript.

### Observed Artifact Shapes

The live Droid probe also exposed the exact field naming style it uses in mission artifacts.

Observed `features.json` fields:

- `id`
- `description`
- `skillName`
- `milestone`
- `preconditions`
- `expectedBehavior`
- `verificationSteps`
- `fulfills`
- `status`

Observed `validation-state.json` shape:

```json
{
  "assertions": {
    "VAL-PARSE-001": { "status": "pending" }
  }
}
```

Observed mission `AGENTS.md` role:

- mission-specific boundaries
- coding conventions
- test command and test file expectations
- manual user-testing guidance

Observed worker skill structure:

- YAML frontmatter
- `When to Use This Skill`
- `Work Procedure`
- `Example Handoff`
- `When to Return to Orchestrator`

Observed worker subagent prompt envelope:

- subagent identity is generic `# Worker Droid`
- the parent passes a tightly scoped task prompt
- the worker session is linked back to the orchestrator via `callingSessionId` and `callingToolUseId`

## Final Design

### Product Surface

Lemon should keep the same mental model and command vocabulary:

- `/missions`
- `/mission`
- `/enter-mission`

Mission Control should also expose explicit status commands/actions:

- `/mission-status`
- `/pause-mission`
- `/resume-mission`
- `/mission-control`

The human-facing flow is:

1. User enters mission mode from a normal coding session.
2. Lemon runs an interactive planning interview.
3. Lemon proposes a durable mission plan and mission-specific instructions.
4. User accepts or revises the plan.
5. Mission Control begins executing features.
6. Milestone validators run automatically.
7. Mission pauses only for meaningful blockers, validation failures that require a decision, or explicit user control.

### Key Compatibility Decisions

Lemon should match Factory's behavior where it matters, but not copy its internal architecture blindly.

Keep:

- the mission/planning/control mental model
- slash-command entry points
- feature + milestone decomposition
- mission-specific worker skills
- milestone validators
- durable on-disk artifacts
- pause/resume semantics

Change:

- no separate external daemon requirement; Mission Control should be a supervised Lemon process
- artifacts should live under the project's `.lemon/` directory first, not only in a global home directory
- Phase 1 should stay serial; any later parallelism is an implementation detail, not a parity requirement

Additional Lemon parity decisions:

- preserve Droid-style mission artifact field names where practical, especially inside `features.json` and `validation-state.json`
- keep the two-phase flow:
  - mission proposal acceptance creates mission identity and top-level record
  - artifact completion and execution start happen afterward
- keep the explicit pre-run coverage check and mission-run start event
- replace the external-daemon retry behavior with the equivalent Lemon-supervisor retry behavior, but preserve the same user-facing "retry once, then pause with recovery instructions" contract

## Mission Planning Contract

Mission planning is the most important part of the feature. Lemon should implement it as a first-class system skill pair:

- `mission-planning`
- `define-mission-skills`

`mission-planning` must not allow execution until it has captured:

- project goal and non-goals
- concrete features
- milestone grouping
- dependencies and preconditions
- expected behavior per feature
- verification steps per feature
- infrastructure/services/ports/off-limits
- credentials or account setup requirements
- automated test strategy
- human user-testing strategy
- a validation dry run proving the contract is checkable

The planner must require explicit user confirmation for:

- milestone boundaries
- external dependencies and off-limits areas
- validation expectations

`define-mission-skills` must:

- identify the worker types needed by boundary or domain
- prefer existing Lemon subagent roles where possible
- generate mission-local instructions when existing roles are too generic
- reserve two implicit validator roles per milestone:
  - `scrutiny-validator`
  - `user-testing-validator`

## Artifact Model

Mission artifacts should be durable, human-readable, and resumable without the original session context.

Primary location:

```text
.lemon/missions/<mission_id>/
```

Directory layout:

```text
.lemon/missions/<mission_id>/
  mission.md
  features.json
  milestones.json
  validation-contract.md
  validation-state.json
  state.json
  progress_log.jsonl
  working_directory.txt
  AGENTS.md
  skills/
```

Notes:

- `mission.md` is the narrative plan shown to humans.
- `features.json` is the executable feature graph.
- `milestones.json` keeps milestone state separate from feature state.
- `validation-contract.md` is the human-readable acceptance contract.
- `validation-state.json` stores machine-usable assertion statuses and evidence.
- `AGENTS.md` contains mission-specific constraints for all workers.
- `skills/` contains generated worker instructions when needed.
- Droid splits artifacts between a global mission directory and repo-local `.factory/` worker infrastructure. Lemon can place the durable mission state under `.lemon/missions/<id>`, but it should still support repo-local worker infrastructure if that produces better execution isolation and resumability.

Observed Droid-style `features.json` example:

```json
[
  {
    "id": "project-scaffold-and-parser",
    "description": "Set up the project and implement the core parser module with TDD.",
    "skillName": "cli-worker",
    "milestone": "core",
    "preconditions": [],
    "expectedBehavior": [
      "package.json exists with type:module, bin entry, zero runtime dependencies"
    ],
    "verificationSteps": [
      "node --test (all parser tests pass)"
    ],
    "fulfills": ["VAL-PARSE-001"],
    "status": "pending"
  }
]
```

Recommended top-level `state.json` fields:

```json
{
  "schema_version": 1,
  "mission_id": "msn_123",
  "base_session_id": "sess_123",
  "base_run_id": "run_123",
  "state": "paused",
  "working_directory": "/abs/path",
  "current_feature_id": "feat_003",
  "current_worker_task_id": "task_123",
  "current_worker_run_id": "run_456",
  "worker_task_ids": ["task_123"],
  "completed_features": 2,
  "total_features": 7,
  "max_parallelism": 1,
  "created_at": "2026-03-12T00:00:00Z",
  "updated_at": "2026-03-12T00:00:00Z"
}
```

Recommended Lemon `features.json` shape for Droid parity:

```json
[
  {
    "id": "feat_001",
    "description": "Implement mission planning artifacts",
    "type": "implementation",
    "skillName": "planner-implementer",
    "workerRole": "implement",
    "milestone": "ms_001",
    "preconditions": [],
    "expectedBehavior": [
      "Mission files are created under .lemon/missions/<id>"
    ],
    "verificationSteps": [
      "Create a mission and confirm files exist"
    ],
    "fulfills": ["VAL-ARTIFACTS-001"],
    "dependsOn": [],
    "status": "pending",
    "attempts": 0
  }
]
```

## Lifecycle

Mission state machine:

- `drafting`
- `proposed`
- `accepted`
- `running`
- `paused`
- `completed`
- `failed`
- `cancelled`

Feature state machine:

- `pending`
- `ready`
- `running`
- `validating`
- `completed`
- `failed`
- `blocked`

Milestone state machine:

- `pending`
- `active`
- `validating`
- `completed`
- `failed`

A mission can resume entirely from artifact state plus Lemon's existing run/task lineage.

## Execution Model

Mission Control should be a supervised service, not an ad hoc prompt convention.

### Core rule

The planning conversation stays human-facing. Actual execution is driven by a durable Mission Control state machine that spawns workers, observes results, updates artifacts, and only routes back to the human session when judgment is needed.

### Worker model

For each runnable feature, Mission Control:

1. chooses the next feature whose dependencies are satisfied
2. materializes a worker prompt from:
   - mission plan
   - mission `AGENTS.md`
   - relevant mission skill
   - feature-specific expectations and verification steps
3. spawns a fresh worker session
4. tracks its run/task lineage
5. records lifecycle events
6. updates feature and mission state on completion
7. when execution has not started yet, performs the pre-run setup stage first:
   - finalize mission artifacts
   - run the assertion-coverage check
   - persist repo-local worker infrastructure if used
   - checkpoint that infrastructure before the first worker starts when running inside a git repo

### Parallelism

Phase 1 should default to serial execution with `max_parallelism = 1`.

If later phases allow parallel feature execution, Lemon should add explicit isolation and merge rules before enabling it. Droid parity does not require worktree-based execution.

## Validation Model

Validation happens at milestone boundaries, not after every feature.

When the last implementation feature in a milestone completes, Mission Control auto-enqueues:

1. `scrutiny-validator`
2. `user-testing-validator`

`scrutiny-validator` should:

- run in a fresh worker context
- review the milestone output against the validation contract
- execute targeted automated checks where possible
- produce explicit pass/fail evidence by validation assertion ID

`user-testing-validator` should:

- generate a concise human test plan
- pause for human confirmation when direct user interaction is required
- record user-reported pass/fail evidence into `validation-state.json`

If validation fails, Mission Control may create synthetic `fix` features and append them to the current milestone before it can advance.

## Lemon Architecture Mapping

This design should reuse existing modules instead of inventing a parallel runtime:

- `CodingAgent.Tools.Task`
  - worker spawn, async polling, join semantics, followup routing
- `CodingAgent.Coordinator`
  - bounded subagent orchestration
- `CodingAgent.LaneQueue`
  - concurrency caps for mission worker lanes
- `CodingAgent.RunGraph`
  - parent/child lineage for mission, feature, and validator runs
- `CodingAgent.TaskStore`
  - durable task-tool records for active worker runs
- `CodingAgent.SessionManager`
  - durable planning/orchestrator transcript when mission mode is entered from a chat session
- `LemonRouter.RunOrchestrator`
  - routed execution and normalized run submission
- `LemonRouter.SessionTransitions`
  - queue semantics for followups, pauses, and interruption
- `LemonCore.Introspection`
  - Mission Control event stream and operator visibility
- `CodingAgent.Tools.FeatureRequirements`
  - optional import/export bridge for simple requirement graphs, not the primary mission store
- `CodingAgent.Progress`
  - base for mission progress snapshots

## New Components

To make missions first-class, Lemon should add:

- `LemonCore.Missions.Store`
  - typed durable record wrapper for mission metadata and indexing
- `CodingAgent.Missions.Artifacts`
  - read/write helpers for `.lemon/missions/<id>/...`
- `CodingAgent.Missions.Planner`
  - planning interview, proposal generation, and revision loop
- `CodingAgent.Missions.SkillBuilder`
  - mission-local worker skill generation
- `CodingAgent.Missions.Control`
  - Mission Control state machine and execution loop
- `CodingAgent.Missions.Validator`
  - scrutiny and user-testing validator orchestration
- `LemonControlPlane` mission methods
  - listing, status, events, pause, resume, inspect

Ownership by app should respect existing architecture boundaries:

- `lemon_core` for durable mission records and event contracts
- `coding_agent` for mission planning, execution, and artifact handling
- `lemon_router` for queue and submission semantics
- `lemon_control_plane` for API exposure

## Control Plane And UI

Lemon should expose mission state through both chat commands and structured APIs.

Minimum control-plane methods:

- `mission.list`
- `mission.get`
- `mission.events`
- `mission.pause`
- `mission.resume`
- `mission.abort`

Minimum mission status payload:

```json
{
  "mission_id": "msn_123",
  "state": "running",
  "current_feature_id": "feat_003",
  "current_milestone_id": "ms_001",
  "progress": {
    "completed_features": 2,
    "total_features": 7,
    "completed_milestones": 0,
    "total_milestones": 3
  },
  "pending_user_action": null
}
```

## Telemetry And Introspection

Mission Control should extend the existing introspection taxonomy instead of inventing a separate event system.

Recommended events:

- `mission_created`
- `mission_proposed`
- `mission_accepted`
- `mission_run_started`
- `mission_paused`
- `mission_resumed`
- `mission_completed`
- `mission_failed`
- `mission_feature_started`
- `mission_feature_completed`
- `mission_feature_failed`
- `mission_validation_started`
- `mission_validation_passed`
- `mission_validation_failed`

Each event should include, when available:

- `mission_id`
- `milestone_id`
- `feature_id`
- `task_id`
- `run_id`
- `parent_run_id`
- `session_key`
- `working_directory`

## Failure And Recovery Policy

Mission Control should be conservative and resumable.

- transient worker-spawn failures should retry once automatically
- a second consecutive spawn failure should pause the mission and log explicit recovery steps
- worker implementation failures should not destroy the mission record
- validation failures should create explicit follow-up work instead of silently looping
- mission resumption must reconstruct state from artifacts plus `TaskStore` and `RunGraph`
- the retry policy should be attached to mission-run start, not to every arbitrary worker action; this matches the observed Droid behavior where the orchestrator calls `StartMissionRun` once more, then stops

This deliberately preserves the user-facing recovery behavior observed in Factory while avoiding dependence on an external daemon.

## Phased Implementation Plan

### Phase 1: Single-worker mission MVP

- slash-command entry to mission mode
- planning interview and mission proposal
- durable mission artifacts under `.lemon/missions`
- Mission Control with serial feature execution
- milestone validators
- pause/resume/status/events APIs

### Phase 2: Better operator visibility

- richer control-plane mission inspection
- TUI Mission Control view
- explicit validation evidence rendering
- run graph projection for mission trees

### Phase 3: Parallel feature execution

- dependency-aware parallel scheduling
- explicit isolation strategy for parallel worker edits
- merge/review flow for parallel worker outputs

### Phase 4: Deeper automation

- automatic fix-feature synthesis on validator failure
- mission templates
- scheduled mission continuation via `lemon_automation`

## Acceptance Criteria

Lemon Missions is "feature complete" for parity when all of the following are true:

- a user can enter mission mode from chat without leaving the session
- Lemon refuses to execute until a concrete, confirmed mission plan exists
- execution creates durable mission artifacts on disk
- Mission Control can run, pause, resume, and survive client restarts
- each feature runs in its own worker session
- milestone validators are auto-injected and recorded durably
- failures produce visible state and recovery instructions
- mission state is visible via control-plane APIs and introspection
