# Context Management Implementation Worklog

## Team Structure

| Role | Agent | Assignment |
|------|-------|------------|
| Manager | Opus (lead) | Coordination, architecture, new module creation, worklog |
| Engineer 1 | Sonnet | Fix 1: Skill registry ordering |
| Engineer 2 | Sonnet | Fix 2: Extension/WASM tool ordering |
| Engineer 3 | Sonnet | Hook 1: Streaming diagnostics wiring |
| Engineer 4 | Sonnet | Hook 2: Ai.complete diagnostics wiring |
| Engineer 5 | Sonnet | Fix 5: Session guardrails wiring |
| Verification | Codex | Compile + test verification |

## Work Log

### Phase 0: Planning & Exploration (Manager)
- [x] Read CONTEXT_MANAGEMENT.md and understood all 7 fixes
- [x] Explored all 6 target files to understand current state
- [x] Verified AgentCore.Context.check_size/3 signature (takes messages, system_prompt, opts)
- [x] Verified LemonCore.Introspection.record/3 signature (takes event_type, payload, opts)
- [x] Verified wasm_identity/1 helper exists at tool_registry.ex:470-475
- [x] Created task tracking (8 tasks, task 8 blocked by all others)
- [x] Created this worklog

### Phase 1: Architecture (Manager - Opus)
- [x] Created Ai.PromptDiagnostics module (apps/ai/lib/ai/prompt_diagnostics.ex)
- [x] Created CodingAgent.ContextGuardrails module (apps/coding_agent/lib/coding_agent/context_guardrails.ex)

### Phase 2: Parallel Edits (Sonnet Engineers 1-5)
- [x] Engineer 1: Fixed skill registry ordering (registry.ex)
- [x] Engineer 2: Fixed extension + WASM tool ordering (tool_registry.ex)
- [x] Engineer 3: Wired diagnostics into streaming.ex
- [x] Engineer 4: Wired diagnostics into ai.ex complete/3
- [x] Engineer 5: Wired guardrails into session.ex transform pipeline

### Phase 3: Verification
- [x] `mix compile` - all 6 affected apps recompiled successfully (ai, agent_core, lemon_skills, coding_agent, lemon_gateway, lemon_router)
- [x] `mix compile --warnings-as-errors` - clean build, zero warnings
- [x] Fixed one warning: underscored variable `_msg` used after being set in context_guardrails.ex:72
- [x] Manager verified all 7 edits by reading the changed lines
- [x] Run tests across all 4 affected apps in parallel
  - ai: 1,958 tests, 0 failures - PASS
  - lemon_skills: 107 tests, 0 failures - PASS
  - agent_core: 1,607 tests, 27 failures - all pre-existing (MockCodexRunner module issues)
  - coding_agent: 3,574 tests, 45 failures - all pre-existing (StubRunOrchestrator module issues)
- [x] Confirmed: zero new failures introduced by our changes

## Decisions & Notes

### Adaptation: check_size call
The CONTEXT_MANAGEMENT.md suggests `AgentCore.Context.check_size(context)` but the actual
function signature is `check_size(messages, system_prompt \\ nil, opts \\ [])`. We adapt the
call to `AgentCore.Context.check_size(context.messages, context.system_prompt)`.

### Adaptation: StreamOptions struct
The `Ai.PromptDiagnostics.record_llm_call/4` receives a `StreamOptions` struct. The actual
`stream_options` field is on `AgentLoopConfig`, accessed as `config.stream_options`.

### Ordering: Guardrails before UntrustedToolBoundary
Per the doc recommendation, `ContextGuardrails.transform` runs BEFORE `UntrustedToolBoundary.transform`
to avoid truncating in a way that could chop off external-content wrappers.
