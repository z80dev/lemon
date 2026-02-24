---
id: PLN-20260224-long-running-agent-harnesses
title: Long-Running Agent Harnesses and Task Management
owner: janitor
reviewer: codex
status: ready_to_land
workspace: feature/pln-20260224-long-running-harnesses
change_id: pending
created: 2026-02-24
updated: 2026-02-25
---

## Goal

Implement long-running agent harnesses to prevent agents from "one-shotting" tasks and prematurely considering projects complete. This feature adds structured task management, progress tracking, and checkpoint/resume capabilities.

## Background

Anthropic and others have identified that agents need sophisticated harnesses for long-running tasks:
- Feature requirements files with comprehensive checklists
- Progress tracking beyond simple todos
- Checkpoint/resume for extended operations
- Task dependency management

## Current State

Lemon has basic todo management:
- `CodingAgent.Tools.TodoStore` - ETS-based storage
- `CodingAgent.Tools.TodoRead/TodoWrite` - Todo tools
- Session persistence

Missing:
- Feature requirements generation
- Structured progress tracking
- Checkpoint/resume mechanism
- Task dependencies

## Milestones

- [x] M1 — Add feature requirements generation tool
- [x] M2 — Enhance todo system with dependencies and progress
- [x] M3 — Implement checkpoint/resume mechanism
- [x] M4 — Add progress reporting and visualization
- [x] M5 — Integrate with introspection system
- [x] M6 — Tests and documentation

## M1: Feature Requirements Generation Tool

### New Module: `CodingAgent.Tools.FeatureRequirements`

```elixir
defmodule CodingAgent.Tools.FeatureRequirements do
  @moduledoc """
  Generates comprehensive feature requirements from user prompts.
  Creates structured checklist for agents to work through.
  """
  
  alias Ai.Models
  
  @type feature :: %{
    id: String.t(),
    description: String.t(),
    status: :pending | :in_progress | :completed | :failed,
    dependencies: [String.t()],
    priority: :high | :medium | :low,
    acceptance_criteria: [String.t()]
  }
  
  @type requirements_file :: %{
    project_name: String.t(),
    original_prompt: String.t(),
    features: [feature()],
    created_at: DateTime.t(),
    version: String.t()
  }
  
  @doc """
  Generate feature requirements from a user prompt using LLM.
  """
  @spec generate_requirements(String.t(), keyword()) :: {:ok, requirements_file()} | {:error, term()}
  def generate_requirements(prompt, opts \\ []) do
    model = Keyword.get(opts, :model, default_model())
    
    system_prompt = """
    You are a requirements analyst. Expand the user's project description into 
    a comprehensive list of features. Each feature should be:
    - Specific and testable
    - Small enough to implement in one session
    - Include acceptance criteria
    - Marked with dependencies on other features
    
    Return as JSON with this structure:
    {
      "project_name": "...",
      "features": [
        {
          "id": "feature-001",
          "description": "...",
          "status": "pending",
          "dependencies": [],
          "priority": "high",
          "acceptance_criteria": ["..."]
        }
      ]
    }
    """
    
    # Call LLM to generate requirements
    case Ai.chat(model, [
      %{role: "system", content: system_prompt},
      %{role: "user", content: prompt}
    ]) do
      {:ok, response} -> parse_requirements_response(response, prompt)
      {:error, reason} -> {:error, reason}
    end
  end
  
  @doc """
  Save requirements to a file in the project directory.
  """
  @spec save_requirements(requirements_file(), String.t()) :: :ok | {:error, term()}
  def save_requirements(requirements, cwd) do
    path = Path.join(cwd, "FEATURE_REQUIREMENTS.json")
    
    content = Jason.encode!(requirements, pretty: true)
    File.write(path, content)
  end
  
  @doc """
  Load requirements from project directory.
  """
  @spec load_requirements(String.t()) :: {:ok, requirements_file()} | {:error, :not_found}
  def load_requirements(cwd) do
    path = Path.join(cwd, "FEATURE_REQUIREMENTS.json")
    
    case File.read(path) do
      {:ok, content} -> Jason.decode(content, keys: :atoms!)
      {:error, _} -> {:error, :not_found}
    end
  end
  
  @doc """
  Update feature status in requirements file.
  """
  @spec update_feature_status(String.t(), String.t(), atom(), String.t()) :: :ok | {:error, term()}
  def update_feature_status(cwd, feature_id, status, notes \\ "") do
    with {:ok, requirements} <- load_requirements(cwd) do
      updated_features = Enum.map(requirements.features, fn feature ->
        if feature.id == feature_id do
          %{feature | status: status, updated_at: DateTime.utc_now(), notes: notes}
        else
          feature
        end
      end)
      
      updated = %{requirements | features: updated_features}
      save_requirements(updated, cwd)
    end
  end
  
  @doc """
  Get progress statistics for requirements.
  """
  @spec get_progress(String.t()) :: {:ok, map()} | {:error, term()}
  def get_progress(cwd) do
    with {:ok, requirements} <- load_requirements(cwd) do
      total = length(requirements.features)
      completed = Enum.count(requirements.features, & &1.status == :completed)
      failed = Enum.count(requirements.features, & &1.status == :failed)
      in_progress = Enum.count(requirements.features, & &1.status == :in_progress)
      pending = Enum.count(requirements.features, & &1.status == :pending)
      
      percentage = if total > 0, do: div(completed * 100, total), else: 0
      
      {:ok, %{
        total: total,
        completed: completed,
        failed: failed,
        in_progress: in_progress,
        pending: pending,
        percentage: percentage,
        project_name: requirements.project_name
      }}
    end
  end
  
  @doc """
  Get next actionable features (dependencies met, not started).
  """
  @spec get_next_features(String.t()) :: {:ok, [feature()]} | {:error, term()}
  def get_next_features(cwd) do
    with {:ok, requirements} <- load_requirements(cwd) do
      completed_ids = requirements.features
      |> Enum.filter(& &1.status == :completed)
      |> Enum.map(& &1.id)
      
      next = requirements.features
      |> Enum.filter(fn feature ->
        feature.status == :pending and
        Enum.all?(feature.dependencies, & &1 in completed_ids)
      end)
      |> Enum.sort_by(& &1.priority, fn a, b -> 
        order = %{high: 0, medium: 1, low: 2}
        order[a] <= order[b]
      end)
      
      {:ok, next}
    end
  end
  
  # Private functions
  
  defp parse_requirements_response(response, original_prompt) do
    case Jason.decode(response, keys: :atoms!) do
      {:ok, data} ->
        requirements = %{
          project_name: data.project_name,
          original_prompt: original_prompt,
          features: data.features,
          created_at: DateTime.utc_now(),
          version: "1.0"
        }
        {:ok, requirements}
        
      {:error, _} ->
        {:error, :invalid_response_format}
    end
  end
  
  defp default_model do
    # Use a capable model for requirements generation
    Models.get_model(:anthropic, "claude-sonnet-4-20250514")
  end
end
```

### New Tool: `feature_requirements`

Add to agent tools:

```elixir
%AgentTool{
  name: "feature_requirements",
  description: "Generate or manage feature requirements for long-running projects",
  parameters: %{
    "type" => "object",
    "properties" => %{
      "action" => %{
        "type" => "string",
        "enum" => ["generate", "load", "update", "progress", "next"],
        "description" => "Action to perform"
      },
      "prompt" => %{
        "type" => "string",
        "description" => "Project description (for generate action)"
      },
      "feature_id" => %{
        "type" => "string",
        "description" => "Feature ID (for update action)"
      },
      "status" => %{
        "type" => "string",
        "enum" => ["pending", "in_progress", "completed", "failed"],
        "description" => "New status (for update action)"
      },
      "notes" => %{
        "type" => "string",
        "description" => "Optional notes (for update action)"
      }
    },
    "required" => ["action"]
  },
  execute: &feature_requirements_execute/4
}
```

## M2: Enhanced Todo System

### Add to `CodingAgent.Tools.TodoStore`

```elixir
@type todo_item :: %{
  id: String.t(),
  content: String.t(),
  status: :pending | :in_progress | :completed | :blocked,
  dependencies: [String.t()],
  priority: :high | :medium | :low,
  estimated_effort: String.t(),
  created_at: DateTime.t(),
  updated_at: DateTime.t(),
  completed_at: DateTime.t() | nil,
  metadata: map()
}

@doc """
Get todos with dependency resolution.
Returns only todos whose dependencies are completed.
"""
@spec get_actionable(String.t()) :: [todo_item()]
def get_actionable(session_id) do
  todos = get(session_id)
  completed_ids = todos
  |> Enum.filter(& &1.status == :completed)
  |> Enum.map(& &1.id)
  
  todos
  |> Enum.filter(fn todo ->
    todo.status in [:pending, :in_progress] and
    Enum.all?(todo.dependencies, & &1 in completed_ids)
  end)
end

@doc """
Get progress statistics for todos.
"""
@spec get_progress(String.t()) :: map()
def get_progress(session_id) do
  todos = get(session_id)
  total = length(todos)
  completed = Enum.count(todos, & &1.status == :completed)
  in_progress = Enum.count(todos, & &1.status == :in_progress)
  blocked = Enum.count(todos, & &1.status == :blocked)
  pending = Enum.count(todos, & &1.status == :pending)
  
  percentage = if total > 0, do: div(completed * 100, total), else: 0
  
  %{
    total: total,
    completed: completed,
    in_progress: in_progress,
    blocked: blocked,
    pending: pending,
    percentage: percentage
  }
end
```

## M3: Checkpoint/Resume Mechanism

### New Module: `CodingAgent.Checkpoint`

```elixir
defmodule CodingAgent.Checkpoint do
  @moduledoc """
  Checkpoint and resume mechanism for long-running agents.
  """
  
  alias CodingAgent.Session
  
  @type checkpoint :: %{
    id: String.t(),
    session_id: String.t(),
    timestamp: DateTime.t(),
    state: map(),
    context: map(),
    todos: list(),
    requirements: map() | nil,
    metadata: map()
  }
  
  @doc """
  Create a checkpoint of current session state.
  """
  @spec create(String.t(), map()) :: {:ok, checkpoint()} | {:error, term()}
  def create(session_id, opts \\ %{}) do
    with {:ok, session} <- Session.get(session_id) do
      checkpoint = %{
        id: generate_checkpoint_id(),
        session_id: session_id,
        timestamp: DateTime.utc_now(),
        state: capture_state(session),
        context: opts[:context] || %{},
        todos: CodingAgent.Tools.TodoStore.get(session_id),
        requirements: load_requirements(session.cwd),
        metadata: opts[:metadata] || %{}
      }
      
      save_checkpoint(checkpoint)
      {:ok, checkpoint}
    end
  end
  
  @doc """
  Resume from a checkpoint.
  """
  @spec resume(String.t()) :: {:ok, map()} | {:error, term()}
  def resume(checkpoint_id) do
    with {:ok, checkpoint} <- load_checkpoint(checkpoint_id) do
      # Restore todos
      CodingAgent.Tools.TodoStore.put(
        checkpoint.session_id,
        checkpoint.todos
      )
      
      # Return resume context
      {:ok, %{
        session_id: checkpoint.session_id,
        state: checkpoint.state,
        context: checkpoint.context,
        resumed_from: checkpoint_id,
        timestamp: checkpoint.timestamp
      }}
    end
  end
  
  @doc """
  List checkpoints for a session.
  """
  @spec list(String.t()) :: [checkpoint()]
  def list(session_id) do
    # Implementation to list checkpoints from storage
  end
  
  # Private functions
  
  defp generate_checkpoint_id do
    "chk_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
  
  defp capture_state(session) do
    %{
      message_count: length(session.messages),
      tool_calls: session.tool_calls,
      current_run: session.current_run
    }
  end
  
  defp save_checkpoint(checkpoint) do
    # Persist to disk or database
    path = Path.join([System.tmp_dir!(), "lemon_checkpoints", "#{checkpoint.id}.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(checkpoint))
  end
  
  defp load_checkpoint(checkpoint_id) do
    path = Path.join([System.tmp_dir!(), "lemon_checkpoints", "#{checkpoint_id}.json"])
    
    case File.read(path) do
      {:ok, content} -> Jason.decode(content, keys: :atoms!)
      {:error, _} -> {:error, :not_found}
    end
  end
  
  defp load_requirements(cwd) do
    case CodingAgent.Tools.FeatureRequirements.load_requirements(cwd) do
      {:ok, req} -> req
      {:error, _} -> nil
    end
  end
end
```

## M4: Progress Reporting

### Integration with Introspection

Add progress reporting to the control plane introspection system:

```elixir
# In control plane methods
def handle("agent.progress", params) do
  session_id = params["session_id"]
  
  # Get todo progress
  todo_progress = CodingAgent.Tools.TodoStore.get_progress(session_id)
  
  # Get feature requirements progress
  {:ok, req_progress} = CodingAgent.Tools.FeatureRequirements.get_progress(session.cwd)
  
  {:ok, %{
    todos: todo_progress,
    features: req_progress,
    overall_percentage: calculate_overall(todo_progress, req_progress),
    next_actions: get_next_actions(session)
  }}
end
```

## Exit Criteria

- [x] Feature requirements generation works with LLM
- [x] Requirements files save/load correctly
- [x] Todo dependencies are respected
- [x] Checkpoints can be created and resumed
- [x] Progress is visible in introspection
- [x] Tests cover all major functionality
- [x] Documentation updated

## Progress Log

| Timestamp | Milestone | Notes |
|-----------|-----------|-------|
| 2026-02-24 | Planning | Created PLN for long-running agent harnesses |
| 2026-02-24 | M1 | Implemented FeatureRequirements module with full functionality |
| 2026-02-24 | M1 | Added 10 comprehensive tests, all passing |
| 2026-02-24 | M1 | Support for generate, save, load, update, progress tracking |
| 2026-02-24 | M2 | Enhanced TodoStore with dependencies and progress tracking |
| 2026-02-24 | M2 | Added 6 new functions: get_actionable, get_progress, update_status, complete, all_completed?, get_blocking |
| 2026-02-24 | M2 | Added 16 new tests, all 75 tests passing |
| 2026-02-24 | M3 | Implemented Checkpoint module for save/resume |
| 2026-02-24 | M3 | Added 17 tests for checkpoint functionality |
| 2026-02-24 | M4 | Added `CodingAgent.Progress.snapshot/2` aggregation (todos + requirements + checkpoint stats + next actions) with dedicated tests |
| 2026-02-24 | M5 | Added `agent.progress` control-plane method + schema/registry integration; emits `:agent_progress_snapshot` introspection events with run/session metadata |
| 2026-02-25 | M6 | Added long-running harness operator docs + AGENTS references; produced review/merge artifacts and moved plan to `ready_to_land` |

## Implementation Summary

### M1: Feature Requirements Tool ✅

Created `CodingAgent.Tools.FeatureRequirements` module:

**Core Functions:**
- `generate_requirements/2` - Uses LLM to expand prompts into detailed feature lists
- `save_requirements/2` - Persists to `FEATURE_REQUIREMENTS.json`
- `load_requirements/1` - Loads from project directory
- `update_feature_status/4` - Updates feature status with notes
- `get_progress/1` - Calculates completion statistics
- `get_next_features/1` - Returns actionable features (dependencies met)
- `complete_feature/3` - Convenience for marking complete

**Feature Structure:**
```elixir
%{
  id: "feature-001",
  description: "Clear description",
  status: :pending | :in_progress | :completed | :failed,
  dependencies: ["feature-000"],
  priority: :high | :medium | :low,
  acceptance_criteria: ["testable criteria"],
  notes: "",
  created_at: "2026-02-24T...",
  updated_at: nil
}
```

**Tests:** 10 tests covering all functionality

### M2: Enhanced TodoStore ✅

Enhanced `CodingAgent.Tools.TodoStore` with dependency tracking:

**New Functions:**
- `get_actionable/1` - Returns todos whose dependencies are all completed
- `get_progress/1` - Calculates progress statistics (total, completed, in_progress, blocked, pending, percentage)
- `update_status/3` - Updates todo status with automatic timestamp management
- `complete/2` - Convenience function to mark todo as completed
- `all_completed?/1` - Checks if all todos are completed
- `get_blocking/1` - Returns todos that are blocking other todos

**Todo Structure:**
```elixir
%{
  id: "todo-001",
  content: "Description",
  status: :pending | :in_progress | :completed | :blocked,
  dependencies: ["todo-000"],
  priority: :high | :medium | :low,
  estimated_effort: "2 hours",
  created_at: "2026-02-24T...",
  updated_at: nil,
  completed_at: nil,
  metadata: %{}
}
```

**Tests:** 75 total tests (59 existing + 16 new) all passing

### M3: Checkpoint Module ✅

Created `CodingAgent.Checkpoint` module for save/resume functionality:

**Core Functions:**
- `create/2` - Creates checkpoint with session state, todos, requirements
- `resume/1` - Restores from checkpoint and returns resume state
- `list/1` - Lists all checkpoints for a session (newest first)
- `get_latest/1` - Gets most recent checkpoint
- `delete/1` - Deletes a specific checkpoint
- `delete_all/1` - Deletes all checkpoints for a session
- `stats/1` - Returns checkpoint statistics
- `exists?/1` - Checks if checkpoint exists
- `prune/2` - Keeps only N most recent checkpoints

**Checkpoint Structure:**
```elixir
%{
  id: "chk_a1b2c3d4",
  session_id: "session-123",
  timestamp: "2026-02-24T...",
  state: %{...},              # Session state
  context: %{step: 5},        # User context
  todos: [...],               # Todo list snapshot
  requirements: %{...},       # Feature requirements
  metadata: %{version: "1.0", tag: "before_api"}
}
```

**Storage:** JSON files in system temp directory (`lemon_checkpoints/`)

**Tests:** 17 tests covering all functionality

### M4: Progress Snapshot ✅

Added `CodingAgent.Progress.snapshot/2` to provide a unified view of long-running harness state:

- Aggregates todo progress (`TodoStore.get_progress/1`)
- Aggregates feature requirements progress when `FEATURE_REQUIREMENTS.json` exists
- Aggregates checkpoint stats (`Checkpoint.stats/1`)
- Returns prioritized next actions for both todos and feature requirements
- Computes an overall completion percentage across todo + feature dimensions

**Tests:** `apps/coding_agent/test/coding_agent/progress_test.exs` (2 tests)

### M5: Introspection Integration ✅

Added control-plane surface area for progress visibility:

- New JSON-RPC method: `agent.progress`
- Added method registration and schema validation
- Records `:agent_progress_snapshot` introspection events with optional run/session/agent metadata

**Tests:** Extended `apps/lemon_control_plane/test/lemon_control_plane/methods/introspection_methods_test.exs`

### M6: Tests + Documentation + Artifacts ✅

Completed close-out deliverables for long-running harnesses:

- Added operator doc: `docs/long-running-agent-harnesses.md`
- Updated `apps/coding_agent/AGENTS.md` and `apps/lemon_control_plane/AGENTS.md` with progress APIs and `agent.progress`
- Added review artifact: `planning/reviews/RVW-PLN-20260224-long-running-agent-harnesses.md`
- Added merge artifact: `planning/merges/MRG-PLN-20260224-long-running-agent-harnesses.md`
- Moved plan status to `ready_to_land`
