# Lemon Missions Phase 1 Plan

## Goal

Build a first usable Lemon Missions MVP with:

- chat entry via mission slash commands
- collaborative planning and mission proposal
- durable mission artifacts under `.lemon/missions/<id>`
- Mission Control serial feature execution
- milestone validation
- pause, resume, and status APIs

Phase 1 is intentionally single-worker and execution-focused. It should prove the end-to-end loop before adding richer UI or parallelism.

## Scope

In scope:

- mission creation from an interactive coding session
- planning workflow and explicit user acceptance
- mission artifact creation and updates
- Mission Control run loop
- feature worker spawning via existing Task infrastructure
- milestone auto-validation
- mission pause/resume/status/event inspection

Out of scope:

- parallel feature execution
- automatic merge handling
- scheduled continuation
- mission templates
- full TUI Mission Control UI

## Primary Product Flow

1. User enters `/missions` from an active coding session.
2. Lemon switches the session into mission-planning mode.
3. Planner gathers features, milestones, constraints, and validation contract.
4. Lemon writes mission artifacts and presents a proposal.
5. User accepts.
6. Mission Control starts and selects the first ready feature.
7. Mission Control spawns a feature worker using `CodingAgent.Tools.Task`.
8. Worker completes or fails.
9. Mission Control updates artifacts and introspection.
10. At milestone boundary, Mission Control runs:
    - `scrutiny-validator`
    - `user-testing-validator`
11. Mission advances, pauses, or completes.

## Module Plan

### `apps/coding_agent`

Add these modules:

- `CodingAgent.Missions`
  - public facade for mission creation, loading, resume, and status shaping
- `CodingAgent.Missions.Artifacts`
  - filesystem read/write helpers for `.lemon/missions/<id>`
- `CodingAgent.Missions.Planner`
  - planning interview and proposal assembly
- `CodingAgent.Missions.SkillBuilder`
  - mission-local worker/validator instruction generation
- `CodingAgent.Missions.Control`
  - Mission Control state machine and execution loop
- `CodingAgent.Missions.Validator`
  - validator prompt building and validation result shaping
- `CodingAgent.Missions.Progress`
  - mission progress snapshot derived from mission artifacts

Likely support modules:

- `CodingAgent.Missions.Types`
- `CodingAgent.Missions.Event`
- `CodingAgent.Missions.Prompt`

### `apps/lemon_core`

Add:

- `LemonCore.Missions.Store`
  - index mission metadata for lookup outside the filesystem tree
- `LemonCore.Missions.Record`
  - canonical mission record struct/map normalization

This store should keep a compact index only:

- `mission_id`
- `base_session_id`
- `state`
- `cwd`
- `created_at`
- `updated_at`
- `title`

The full source of truth remains the mission artifact directory.

### `apps/lemon_control_plane`

Add methods:

- `mission_list`
- `mission_get`
- `mission_events`
- `mission_pause`
- `mission_resume`

Phase 1 can defer `mission_abort` if pause is enough operationally, but the wire contract should leave room for it.

## Artifact Plan

Phase 1 artifact set:

- `mission.md`
- `features.json`
- `milestones.json`
- `validation-contract.md`
- `validation-state.json`
- `state.json`
- `progress_log.jsonl`
- `working_directory.txt`
- `AGENTS.md`

Additional Phase 1 conventions:

- all files are updated transactionally enough that resume can tolerate mid-write crashes
- `progress_log.jsonl` is append-only
- `state.json` is the authoritative live pointer for the currently running feature and task
- preserve Droid-style field names inside mission artifacts where feasible:
  - `skillName`
  - `milestone`
  - `expectedBehavior`
  - `verificationSteps`
  - `dependsOn`
- proposal acceptance and artifact completion should be separate phases. The observed Droid flow creates a sparse mission dir first, then fills in the rest before execution starts.
- if Lemon chooses repo-local worker infrastructure, it should be written before the first worker run and treated as part of mission initialization

## Data Contracts

### `state.json`

Required fields:

- `schema_version`
- `mission_id`
- `title`
- `base_session_id`
- `base_run_id`
- `state`
- `working_directory`
- `current_milestone_id`
- `current_feature_id`
- `current_worker_task_id`
- `current_worker_run_id`
- `worker_task_ids`
- `completed_features`
- `total_features`
- `completed_milestones`
- `total_milestones`
- `pending_user_action`
- `created_at`
- `updated_at`

### `features.json`

Required fields per feature:

- `id`
- `description`
- `type`
- `skillName`
- `workerRole`
- `milestone`
- `dependsOn`
- `preconditions`
- `expectedBehavior`
- `verificationSteps`
- `fulfills`
- `status`
- `attempts`
- `lastError`

Feature `type` values for Phase 1:

- `implementation`
- `scrutiny_validation`
- `user_testing_validation`
- `fix`

### `milestones.json`

Required fields per milestone:

- `id`
- `title`
- `description`
- `feature_ids`
- `status`
- `validation_status`

### `validation-state.json`

Recommended top-level shape:

```json
{
  "assertions": {
    "VAL-ARTIFACTS-001": {
      "status": "pending",
      "description": "Mission files are created under .lemon/missions/<id>",
      "evidence": [],
      "updatedAt": "2026-03-12T00:00:00Z"
    }
  }
}
```

Required fields per assertion record:

- `status`
- `description`
- `evidence`
- `updatedAt`

## Execution Loop

`CodingAgent.Missions.Control` should follow this loop:

1. Load mission state.
2. If mission is paused, failed, completed, or cancelled, stop.
3. Compute next ready feature.
4. If no ready feature exists:
   - if current milestone needs validation, enqueue validators
   - else if all milestones are complete, complete the mission
   - else pause with explicit reason
5. If execution has not started yet:
   - finalize mission artifacts
   - run assertion coverage validation
   - write any repo-local worker infrastructure
   - checkpoint initialization state
6. Emit `mission_run_started`.
7. Spawn worker via `CodingAgent.Tools.Task` with `async: true`.
8. Persist worker lineage into `state.json` and `progress_log.jsonl`.
9. Poll/join until terminal result.
10. Update feature state.
11. Emit introspection event.
12. Repeat.

Phase 1 should keep Control simple:

- one active worker at a time
- one retry for spawn failures
- no speculative prefetching
- no parallel validator runs
- retry-once policy should mirror observed Droid behavior:
  - first start/run spawn failure logs a worker failure and returns control
  - Mission Control retries start once
  - second consecutive failure pauses the mission with concrete recovery instructions:
    - restart Lemon mission control
    - re-enter mission mode
    - resume from the first pending feature

## Planner Behavior

The planner should be implemented as a guided prompt contract, not hidden heuristics.

The planning result must produce:

- a mission title
- milestone list
- feature list
- mission-local `AGENTS.md`
- validation contract
- worker skill definitions when needed

The planner must block proposal until:

- every feature belongs to a milestone
- every milestone has at least one validation assertion
- every feature has verification steps
- off-limits areas are explicitly recorded
- the user has accepted the plan

## Worker Prompt Construction

Each worker prompt should include:

- mission title and goal
- current feature description
- mission-specific constraints from mission `AGENTS.md`
- expected behavior
- verification steps
- dependencies already completed
- instruction to update only what is needed for the feature

Each validator prompt should include:

- milestone summary
- completed feature outputs
- validation contract assertions for that milestone
- expected evidence format

## Reuse Plan

Phase 1 should reuse existing Lemon infrastructure aggressively.

- Use `CodingAgent.Tools.Task` for worker execution.
- Use `CodingAgent.TaskStore` for async task tracking.
- Use `CodingAgent.RunGraph` to attach feature workers under the mission run.
- Use `LemonCore.Introspection` for mission events.
- Use `CodingAgent.SessionManager` to persist the planning/orchestrator session.
- Use `LemonRouter.SessionTransitions` semantics only when routing mission followups back into the base session.

Avoid in Phase 1:

- inventing a second general-purpose scheduler
- storing the full mission only in `LemonCore.Store`
- embedding mission state only in session transcript messages

## Event Plan

Phase 1 introspection events:

- `mission_created`
- `mission_proposed`
- `mission_accepted`
- `mission_run_started`
- `mission_paused`
- `mission_resumed`
- `mission_feature_started`
- `mission_feature_completed`
- `mission_feature_failed`
- `mission_validation_started`
- `mission_validation_passed`
- `mission_validation_failed`
- `mission_completed`
- `mission_failed`

`progress_log.jsonl` should mirror the same logical lifecycle in a mission-local append-only stream.

## API Plan

### `mission.list`

Returns compact mission records for the current project or globally.

### `mission.get`

Returns:

- current mission state
- feature list summary
- milestone summary
- current worker lineage
- pending user action

### `mission.events`

Returns recent mission-local events from `progress_log.jsonl` with optional introspection correlation data.

### `mission.pause`

Sets mission state to `paused`, prevents new workers from spawning, and records a reason.

### `mission.resume`

Reloads artifacts, reconstructs active state, and restarts the Mission Control loop.

## Delivery Order

Recommended build order:

1. `CodingAgent.Missions.Artifacts`
2. `LemonCore.Missions.Store`
3. `CodingAgent.Missions.Planner`
4. `CodingAgent.Missions.SkillBuilder`
5. `CodingAgent.Missions.Control`
6. `CodingAgent.Missions.Validator`
7. control-plane mission methods
8. slash-command integration in the coding session

This order gets the artifact contract stable first, which reduces churn in the planner and Mission Control loop.

## Milestones

### Milestone 1: Artifact and store foundation

- mission directory creation
- mission record index
- load/save/update helpers
- progress log append helpers

### Milestone 2: Planning and acceptance

- planner prompt contract
- mission proposal output
- acceptance path
- mission-local `AGENTS.md`

### Milestone 3: Mission Control execution

- next-ready feature selection
- worker spawn and result handling
- feature state transitions
- pause/resume behavior

### Milestone 4: Validation and APIs

- milestone validator injection
- validation-state updates
- control-plane status and events

## Acceptance Criteria

Phase 1 is done when:

- a user can create and accept a mission from chat
- the mission is durably written under `.lemon/missions/<id>`
- Mission Control can execute a serial feature plan using Task workers
- milestone validators are injected automatically
- pause/resume works across process restarts
- operators can inspect missions via control-plane methods
