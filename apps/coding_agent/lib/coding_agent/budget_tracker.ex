defmodule CodingAgent.BudgetTracker do
  @moduledoc """
  Token and cost budget tracking for runs.

  Tracks resource usage per run and enforces budget limits.
  Integrates with RunGraph to track parent/child budget inheritance.

  ## Features

  - Token usage tracking (input, output, cache)
  - Cost tracking (estimated and actual)
  - Per-parent concurrency limits
  - Atomic child reservations and idempotent completion aggregation
  - Budget exceeded handling
  - Durable tracking via RunGraph

  ## Usage

      # Create a budget for a new run
      budget = BudgetTracker.create_budget(max_tokens: 100000, max_cost: 10.0)

      # Record usage
      BudgetTracker.record_usage(run_id, tokens: 500, cost: 0.01)

      # Check limits
      BudgetTracker.check_budget(run_id)
  """

  alias CodingAgent.{RunGraph, RunGraphServer}

  @type budget :: %{
          max_tokens: non_neg_integer() | nil,
          max_cost: float() | nil,
          max_children: non_neg_integer() | nil,
          used_tokens: non_neg_integer(),
          used_cost: float(),
          active_children: non_neg_integer(),
          active_child_ids: [String.t()],
          completed_child_ids: [String.t()],
          created_at: integer()
        }

  @type usage :: %{
          tokens: non_neg_integer(),
          cost: float()
        }

  # ============================================================================
  # Budget Creation
  # ============================================================================

  @doc """
  Create a new budget for a run.

  ## Options

  - `:max_tokens` - Maximum token budget (nil = unlimited)
  - `:max_cost` - Maximum cost budget in USD (nil = unlimited)
  - `:max_children` - Maximum concurrent child runs (nil = unlimited)
  - `:parent_id` - Parent run ID to inherit budget from

  ## Examples

      BudgetTracker.create_budget(max_tokens: 100000, max_cost: 5.0)
      # => %{max_tokens: 100000, max_cost: 5.0, ...}
  """
  @spec create_budget(keyword()) :: budget()
  def create_budget(opts \\ []) do
    parent_id = Keyword.get(opts, :parent_id)

    # Inherit limits from parent if specified
    parent_budget = parent_id && get_budget(parent_id)

    %{
      max_tokens: Keyword.get(opts, :max_tokens, parent_budget && parent_budget.max_tokens),
      max_cost: Keyword.get(opts, :max_cost, parent_budget && parent_budget.max_cost),
      max_children: Keyword.get(opts, :max_children, parent_budget && parent_budget.max_children),
      used_tokens: 0,
      used_cost: 0.0,
      active_children: 0,
      active_child_ids: [],
      completed_child_ids: [],
      created_at: System.system_time(:second)
    }
  end

  @doc """
  Create a budget for a subagent run with inherited limits.

  Subagents inherit the parent's budget but can have stricter limits.
  """
  @spec create_subagent_budget(String.t(), keyword()) :: budget()
  def create_subagent_budget(parent_id, opts \\ []) do
    parent_budget = get_budget(parent_id)

    if parent_budget do
      # Inherit from parent, but apply any stricter limits from opts
      %{
        max_tokens: min_opt(parent_budget.max_tokens, Keyword.get(opts, :max_tokens)),
        max_cost: min_opt(parent_budget.max_cost, Keyword.get(opts, :max_cost)),
        max_children: min_opt(parent_budget.max_children, Keyword.get(opts, :max_children)),
        used_tokens: 0,
        used_cost: 0.0,
        active_children: 0,
        active_child_ids: [],
        completed_child_ids: [],
        created_at: System.system_time(:second)
      }
    else
      create_budget(opts)
    end
  end

  # ============================================================================
  # Usage Tracking
  # ============================================================================

  @doc """
  Record token and cost usage for a run.

  ## Examples

      BudgetTracker.record_usage(run_id, tokens: 1000, cost: 0.02)
  """
  @spec record_usage(String.t(), keyword()) :: :ok | {:error, term()}
  def record_usage(run_id, opts \\ []) do
    tokens = Keyword.get(opts, :tokens, 0)
    cost = Keyword.get(opts, :cost, 0.0)

    update_budget(run_id, fn budget ->
      %{
        budget
        | used_tokens: budget.used_tokens + tokens,
          used_cost: budget.used_cost + cost
      }
    end)
  end

  @doc """
  Record usage from an AI response.

  Extracts token usage from the response and records it.
  """
  @spec record_response_usage(String.t(), map()) :: :ok | {:error, term()}
  def record_response_usage(run_id, response) do
    usage = extract_usage(response)
    record_usage(run_id, tokens: usage.tokens, cost: usage.cost)
  end

  @doc """
  Get current usage for a run.
  """
  @spec get_usage(String.t()) :: usage() | nil
  def get_usage(run_id) do
    case get_budget(run_id) do
      nil -> nil
      budget -> %{tokens: budget.used_tokens, cost: budget.used_cost}
    end
  end

  # ============================================================================
  # Budget Checking
  # ============================================================================

  @doc """
  Check if a run is within budget.

  Returns `{:ok, remaining}` if within budget, `{:error, reason}` if exceeded.

  ## Examples

      BudgetTracker.check_budget(run_id)
      # => {:ok, %{tokens_remaining: 50000, cost_remaining: 4.5}}
      # => {:error, :budget_exceeded, %{limit: 100000, used: 100050}}
  """
  @spec check_budget(String.t()) ::
          {:ok, map()}
          | {:error, :budget_exceeded | :token_limit_exceeded | :cost_limit_exceeded, map()}
  def check_budget(run_id) do
    case get_budget(run_id) do
      nil ->
        {:ok, %{tokens_remaining: nil, cost_remaining: nil}}

      budget ->
        check_limits(budget)
    end
  end

  @doc """
  Check if a run can spawn a child.

  Enforces per-parent concurrency limits.
  """
  @spec can_spawn_child?(String.t()) :: boolean()
  def can_spawn_child?(parent_id) do
    case get_budget(parent_id) do
      nil -> true
      %{max_children: nil} -> true
      %{max_children: max, active_children: current} -> current < max
    end
  end

  @doc """
  Record that a child run has started.

  Increments the active_children counter.
  """
  @spec child_started(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def child_started(parent_id, child_id, opts \\ []) do
    result =
      RunGraphServer.atomic_modify(parent_id, fn record ->
        budget = record |> Map.get(:budget, create_budget()) |> normalize_child_tracking()
        active_ids = budget.active_child_ids
        completed_ids = budget.completed_child_ids

        cond do
          child_id in active_ids or child_id in completed_ids ->
            {:ok, record, :already_reserved}

          budget.max_children && budget.active_children >= budget.max_children ->
            {:error, :max_children_exceeded}

          true ->
            updated_budget = %{
              budget
              | active_children: budget.active_children + 1,
                active_child_ids: [child_id | active_ids]
            }

            {:ok, Map.put(record, :budget, updated_budget), :reserved}
        end
      end)

    case result do
      :reserved ->
        child_budget = create_subagent_budget(parent_id, opts)
        store_budget(child_id, child_budget)

      :already_reserved ->
        :ok

      {:error, :not_found} ->
        # Compatibility for callers that use opaque parent ids without a
        # RunGraph record: there is no persisted budget to reserve against.
        :ok

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Record that a child run has completed.

  Decrements the active_children counter and aggregates usage.
  """
  @spec child_completed(String.t(), String.t()) :: :ok | {:error, term()}
  def child_completed(parent_id, child_id) do
    child_usage = get_usage(child_id)

    case RunGraphServer.atomic_modify(parent_id, fn record ->
           budget = record |> Map.get(:budget, create_budget()) |> normalize_child_tracking()

           if child_id in budget.completed_child_ids do
             {:ok, record, :already_completed}
           else
             active_ids = List.delete(budget.active_child_ids, child_id)

             budget = %{
               budget
               | active_children: max(budget.active_children - 1, 0),
                 active_child_ids: active_ids,
                 completed_child_ids: [child_id | budget.completed_child_ids]
             }

             updated_budget =
               case child_usage do
                 %{tokens: child_tokens, cost: child_cost} ->
                   %{
                     budget
                     | used_tokens: budget.used_tokens + child_tokens,
                       used_cost: budget.used_cost + child_cost
                   }

                 _ ->
                   budget
               end

             {:ok, Map.put(record, :budget, updated_budget), :completed}
           end
         end) do
      result when result in [:completed, :already_completed] -> :ok
      {:error, _reason} = error -> error
    end
  end

  # ============================================================================
  # Budget Storage (via RunGraph)
  # ============================================================================

  @doc """
  Store a budget for a run.

  The budget is stored as metadata in the RunGraph.
  """
  @spec store_budget(String.t(), budget()) :: :ok
  def store_budget(run_id, budget) do
    case RunGraphServer.atomic_modify(run_id, fn record ->
           {:ok, Map.put(record, :budget, normalize_child_tracking(budget)), :ok}
         end) do
      {:error, :not_found} -> :ok
      result -> result
    end
  rescue
    _ -> :ok
  end

  @doc """
  Get the budget for a run.
  """
  @spec get_budget(String.t()) :: budget() | nil
  def get_budget(run_id) do
    case RunGraph.get(run_id) do
      {:ok, record} -> Map.get(record, :budget)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Update a run's budget.
  """
  @spec update_budget(String.t(), (budget() -> budget())) :: :ok | {:error, term()}
  def update_budget(run_id, update_fn) do
    case RunGraphServer.atomic_modify(run_id, fn record ->
           budget = record |> Map.get(:budget, create_budget()) |> normalize_child_tracking()
           updated_budget = budget |> update_fn.() |> normalize_child_tracking()
           {:ok, Map.put(record, :budget, updated_budget), :ok}
         end) do
      {:error, :not_found} -> :ok
      result -> result
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp check_limits(budget) do
    token_check =
      if budget.max_tokens && budget.used_tokens > budget.max_tokens do
        {:error, :token_limit_exceeded, %{limit: budget.max_tokens, used: budget.used_tokens}}
      else
        :ok
      end

    cost_check =
      if budget.max_cost && budget.used_cost > budget.max_cost do
        {:error, :cost_limit_exceeded, %{limit: budget.max_cost, used: budget.used_cost}}
      else
        :ok
      end

    case {token_check, cost_check} do
      {{:error, reason, details}, _} ->
        {:error, :budget_exceeded, Map.put(details, :type, reason)}

      {_, {:error, reason, details}} ->
        {:error, :budget_exceeded, Map.put(details, :type, reason)}

      _ ->
        remaining = %{
          tokens_remaining:
            if(budget.max_tokens, do: max(budget.max_tokens - budget.used_tokens, 0), else: nil),
          cost_remaining:
            if(budget.max_cost, do: max(budget.max_cost - budget.used_cost, 0.0), else: nil)
        }

        {:ok, remaining}
    end
  end

  defp extract_usage(response) do
    usage = Map.get(response, :usage) || Map.get(response, "usage", %{})

    tokens =
      case usage do
        %{total_tokens: t} when is_integer(t) -> t
        %{"total_tokens" => t} when is_integer(t) -> t
        %{input: i, output: o} when is_integer(i) and is_integer(o) -> i + o
        %{"input" => i, "output" => o} when is_integer(i) and is_integer(o) -> i + o
        _ -> 0
      end

    cost =
      case usage do
        %{cost: c} when is_number(c) -> c
        %{"cost" => c} when is_number(c) -> c
        _ -> 0.0
      end

    %{tokens: tokens, cost: cost}
  end

  defp min_opt(nil, nil), do: nil
  defp min_opt(a, nil), do: a
  defp min_opt(nil, b), do: b
  defp min_opt(a, b) when is_number(a) and is_number(b), do: min(a, b)
  defp min_opt(a, _), do: a

  defp normalize_child_tracking(budget) do
    active_child_ids = Map.get(budget, :active_child_ids, [])
    completed_child_ids = Map.get(budget, :completed_child_ids, [])

    budget
    |> Map.put(:active_child_ids, active_child_ids)
    |> Map.put(:completed_child_ids, completed_child_ids)
    |> Map.put(
      :active_children,
      max(Map.get(budget, :active_children, 0), length(active_child_ids))
    )
  end
end
