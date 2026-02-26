---
id: IDEA-20260224-community-long-running-agent-harnesses
title: [Community] Long-Running Agent Harnesses and Task Management
source: community
source_url: https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
discovered: 2026-02-24
status: proposed
---

# Description
Long-running agents require sophisticated harnesses to manage state, track progress, and prevent premature completion. Anthropic and others are developing patterns for managing agents that run for extended periods.

## Evidence

### Anthropic's Approach
- **Feature Requirements Files**: "Initializer agent writes comprehensive file of feature requirements expanding on user's initial prompt"
- **Example**: "over 200 features, such as 'a user can open a new chat, type in a query, press enter, and see an AI response'"
- **Status Tracking**: All features initially marked as "failing" so agents have clear outline
- **Progressive Completion**: Agents work through feature checklist

### Key Patterns
1. **Task Decomposition**: Break large tasks into trackable subtasks
2. **Progress Tracking**: Monitor completion of individual components
3. **State Persistence**: Save agent state for resumption
4. **Checkpointing**: Regular checkpoints for long-running tasks
5. **Failure Recovery**: Resume from last checkpoint on failure

### Community Pain Points
- "Agent one-shotting an app or prematurely considering the project complete"
- Need for structured task management
- Long-running session support

# Lemon Status
- Current state: **Partial** - Has todo management but limited harness support
- Gap analysis:
  - Has `CodingAgent.Tools.TodoStore` for task tracking
  - Has `CodingAgent.Tools.TodoRead/TodoWrite`
  - Has session persistence
  - No feature requirements file pattern
  - No structured progress tracking for long tasks
  - No checkpoint/resume mechanism

## Current Implementation
```
apps/coding_agent/lib/coding_agent/tools/:
- todo_store.ex - ETS-based todo storage
- todoread.ex - Read todos
- todowrite.ex - Write todos

apps/coding_agent/lib/coding_agent/session.ex:
- Session persistence
- State management
```

## What's Missing
1. Feature requirements file generation
2. Structured progress tracking beyond todos
3. Checkpoint/resume for long-running tasks
4. Task dependency management
5. Automatic task decomposition
6. Progress reporting/visualization

# Value Assessment
- Community demand: **MEDIUM-HIGH** - Addresses common pain point
- Strategic fit: **HIGH** - Enhances existing todo system
- Implementation complexity: **MEDIUM** - Builds on existing infrastructure

# Recommendation
**Proceed** - Enhance task management for long-running agents:
1. Add feature requirements file generation tool
2. Enhance todo system with dependencies and progress
3. Add checkpoint/resume mechanism
4. Create progress visualization
5. Integrate with introspection system

## Implementation Ideas

### Feature Requirements Tool
```elixir
defmodule CodingAgent.Tools.FeatureRequirements do
  @moduledoc """
  Generates comprehensive feature requirements from user prompts.
  Creates structured checklist for agents to work through.
  """
  
  def generate_requirements(prompt) do
    # Use LLM to expand prompt into detailed feature list
    # Each feature has: id, description, status, dependencies
  end
end
```

### Enhanced Todo System
- Add dependencies between todos
- Track completion percentage
- Support sub-tasks
- Integrate with introspection

# References
- https://www.anthropic.com/engineering/effective-harnesses-for-long-running-agents
- https://developers.openai.com/blog/openai-for-developers-2025/
