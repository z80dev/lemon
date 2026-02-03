defmodule CodingAgent.BudgetEnforcer do
  @moduledoc """
  Budget enforcement hooks for the agent lifecycle.

  Integrates with Session to enforce budget limits at key points:
  - Before starting a new run
  - Before making API calls
  - When spawning subagents
  - During compaction (if budget exceeded)

  ## Features

  - Pre-flight budget checks
  - Automatic run cancellation on budget exceeded
  - Budget-aware subagent spawning
  - Graceful degradation

  ## Configuration

  Configure default budgets in `config/config.exs`:

      config :coding_agent, :budget_defaults,
        max_tokens: 100_000,
        max_cost: 10.0,
        max_children: 3
  """

  require Logger

  alias CodingAgent.BudgetTracker

  @type enforcement_result :: :ok | {:error, :budget_exceeded, map()}

  # ============================================================================
  # Pre-flight Checks
  # ============================================================================

  @doc """
  Check if a run can start with the given budget.

  Called before starting a new run to verify budget availability.

  ## Examples

      BudgetEnforcer.check_run_start(session_id, max_tokens: 50000)
      # => :ok
      # => {:error, :budget_exceeded, %{reason: :token_limit_exceeded, ...}}
  """
  @spec check_run_start(String.t(), keyword()) :: enforcement_result()
  def check_run_start(run_id, opts \\ []) do
    # Create budget if not exists
    _budget = BudgetTracker.get_budget(run_id) || create_budget_for_run(run_id, opts)

    case BudgetTracker.check_budget(run_id) do
      {:ok, remaining} ->
        Logger.debug("Run #{run_id} has budget: #{inspect(remaining)}")
        :ok

      {:error, reason, details} ->
        Logger.warning("Run #{run_id} budget exceeded: #{reason} - #{inspect(details)}")
        {:error, :budget_exceeded, Map.put(details, :run_id, run_id)}
    end
  end

  @doc """
  Check if an API call can be made.

  Called before making an AI API call to ensure sufficient budget.

  ## Options

  - `:estimated_tokens` - Estimated tokens for this call (default: 4000)
  - `:estimated_cost` - Estimated cost for this call (default: 0.1)
  """
  @spec check_api_call(String.t(), keyword()) :: enforcement_result()
  def check_api_call(run_id, opts \\ []) do
    estimated_tokens = Keyword.get(opts, :estimated_tokens, 4000)
    estimated_cost = Keyword.get(opts, :estimated_cost, 0.1)

    case BudgetTracker.get_budget(run_id) do
      nil ->
        :ok

      budget ->
        cond do
          budget.max_tokens && budget.used_tokens + estimated_tokens > budget.max_tokens ->
            {:error, :budget_exceeded,
             %{
               type: :token_limit_would_exceed,
               limit: budget.max_tokens,
               used: budget.used_tokens,
               estimated: estimated_tokens
             }}

          budget.max_cost && budget.used_cost + estimated_cost > budget.max_cost ->
            {:error, :budget_exceeded,
             %{
               type: :cost_limit_would_exceed,
               limit: budget.max_cost,
               used: budget.used_cost,
               estimated: estimated_cost
             }}

          true ->
            :ok
        end
    end
  end

  @doc """
  Check if a subagent can be spawned.

  Enforces per-parent concurrency limits and budget inheritance.
  """
  @spec check_subagent_spawn(String.t(), keyword()) :: enforcement_result()
  def check_subagent_spawn(parent_id, _opts \\ []) do
    # Check concurrency limit
    if BudgetTracker.can_spawn_child?(parent_id) do
      # Check if parent has budget remaining
      case BudgetTracker.check_budget(parent_id) do
        {:ok, _} ->
          :ok

        {:error, reason, details} ->
          {:error, reason, Map.put(details, :parent_id, parent_id)}
      end
    else
      budget = BudgetTracker.get_budget(parent_id) || %{max_children: nil, active_children: 0}

      {:error, :budget_exceeded,
       %{
         type: :max_children_exceeded,
         limit: budget.max_children,
         active: budget.active_children
       }}
    end
  end

  # ============================================================================
  # Lifecycle Hooks
  # ============================================================================

  @doc """
  Hook called when a run starts.

  Initializes budget tracking for the run.
  """
  @spec on_run_start(String.t(), keyword()) :: :ok
  def on_run_start(run_id, opts \\ []) do
    budget = create_budget_for_run(run_id, opts)
    BudgetTracker.store_budget(run_id, budget)

    Logger.debug("Initialized budget for run #{run_id}: #{inspect(budget)}")
    :ok
  end

  @doc """
  Hook called when a run completes.

  Aggregates usage into parent if applicable.
  """
  @spec on_run_complete(String.t(), map()) :: :ok
  def on_run_complete(run_id, result) do
    # Record final usage from result
    if usage = Map.get(result, :usage) do
      BudgetTracker.record_response_usage(run_id, %{usage: usage})
    end

    # Notify parent if this is a child run
    case get_parent_id(run_id) do
      nil -> :ok
      parent_id -> BudgetTracker.child_completed(parent_id, run_id)
    end

    :ok
  end

  @doc """
  Hook called when a subagent is spawned.

  Records the child and initializes its budget.
  """
  @spec on_subagent_spawn(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def on_subagent_spawn(parent_id, child_id, opts \\ []) do
    # Record child started
    :ok = BudgetTracker.child_started(parent_id, child_id)

    # Create child budget with inherited limits
    child_budget = BudgetTracker.create_subagent_budget(parent_id, opts)
    BudgetTracker.store_budget(child_id, child_budget)

    Logger.debug("Spawned subagent #{child_id} from #{parent_id}")
    :ok
  end

  @doc """
  Hook called when an API response is received.

  Records the token/cost usage from the response.
  """
  @spec on_api_response(String.t(), map()) :: :ok
  def on_api_response(run_id, response) do
    BudgetTracker.record_response_usage(run_id, response)
    :ok
  end

  # ============================================================================
  # Budget Exceeded Handling
  # ============================================================================

  @doc """
  Handle budget exceeded condition.

  Called when a budget limit is exceeded. Can:
  - Cancel the run
  - Trigger compaction
  - Send notification
  - Return error to user

  ## Options

  - `:action` - Action to take: :cancel, :compact, :notify, :error (default: :error)
  - `:message` - Custom error message
  """
  @spec handle_budget_exceeded(String.t(), map(), keyword()) ::
          {:cancel, String.t()} | {:compact, String.t()} | {:error, String.t()}
  def handle_budget_exceeded(run_id, details, opts \\ []) do
    action = Keyword.get(opts, :action, :error)
    default_msg = format_budget_error(details)
    message = Keyword.get(opts, :message, default_msg)

    Logger.warning("Budget exceeded for run #{run_id}: #{message}")

    case action do
      :cancel ->
        {:cancel, message}

      :compact ->
        # Suggest compaction to free up context
        {:compact, "Budget exceeded. Consider compacting context to continue."}

      :notify ->
        # Just notify, don't stop
        {:error, message}

      :error ->
        {:error, message}

      _ ->
        {:error, message}
    end
  end

  @doc """
  Get a summary of budget status for a run.

  Returns a human-readable summary of budget usage.
  """
  @spec budget_summary(String.t()) :: map()
  def budget_summary(run_id) do
    case BudgetTracker.get_budget(run_id) do
      nil ->
        %{status: :no_budget}

      budget ->
        token_pct =
          if budget.max_tokens do
            Float.round(budget.used_tokens / budget.max_tokens * 100, 1)
          else
            nil
          end

        cost_pct =
          if budget.max_cost do
            Float.round(budget.used_cost / budget.max_cost * 100, 1)
          else
            nil
          end

        %{
          status: :active,
          tokens: %{
            used: budget.used_tokens,
            limit: budget.max_tokens,
            percentage: token_pct
          },
          cost: %{
            used: budget.used_cost,
            limit: budget.max_cost,
            percentage: cost_pct
          },
          children: %{
            active: budget.active_children,
            limit: budget.max_children
          }
        }
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp create_budget_for_run(run_id, opts) do
    defaults = Application.get_env(:coding_agent, :budget_defaults, %{})

    budget =
      BudgetTracker.create_budget(
        max_tokens: Keyword.get(opts, :max_tokens, Map.get(defaults, :max_tokens)),
        max_cost: Keyword.get(opts, :max_cost, Map.get(defaults, :max_cost)),
        max_children: Keyword.get(opts, :max_children, Map.get(defaults, :max_children, 3))
      )

    BudgetTracker.store_budget(run_id, budget)
    budget
  end

  defp get_parent_id(run_id) do
    case CodingAgent.RunGraph.get(run_id) do
      {:ok, record} -> Map.get(record, :parent)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp format_budget_error(details) do
    case Map.get(details, :type) do
      :token_limit_exceeded ->
        "Token budget exceeded: #{details.used}/#{details.limit} tokens used"

      :cost_limit_exceeded ->
        "Cost budget exceeded: $#{:erlang.float_to_binary(details.used, decimals: 2)}/" <>
          "$#{:erlang.float_to_binary(details.limit, decimals: 2)} used"

      :max_children_exceeded ->
        "Maximum concurrent subagents reached: #{details.active}/#{details.limit}"

      _ ->
        "Budget limit exceeded"
    end
  end
end
