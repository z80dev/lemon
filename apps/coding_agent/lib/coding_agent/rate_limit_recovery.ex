defmodule CodingAgent.RateLimitRecovery do
  @moduledoc """
  Recovery strategies for rate-limited sessions.

  This module provides multiple strategies for recovering from persistent
  rate-limit wedges where a session remains stuck even after global limits
  should have reset.
  """

  require Logger

  alias Ai.Models

  @type strategy ::
          :reset_backoff
          | {:fallback_model, Ai.Types.Model.t()}
          | {:fallback_provider, atom()}
          | {:session_fork, keyword()}
          | :give_up

  @type strategy_selection_criteria :: %{
          required(:current_model) => Ai.Types.Model.t(),
          required(:failure_count) => non_neg_integer(),
          optional(:available_providers) => [atom()],
          optional(:max_context_tokens) => non_neg_integer(),
          optional(:requires_vision) => boolean(),
          optional(:requires_reasoning) => boolean()
        }

  @doc """
  Select the best recovery strategy based on current conditions.
  """
  @spec select_strategy(strategy_selection_criteria()) :: strategy()
  def select_strategy(criteria) do
    failure_count = Map.get(criteria, :failure_count, 0)
    current_model = Map.fetch!(criteria, :current_model)
    available_providers = Map.get(criteria, :available_providers, [])

    cond do
      failure_count < 3 ->
        :reset_backoff

      failure_count < 5 ->
        case find_fallback_model(current_model) do
          nil -> try_fallback_provider(current_model, available_providers)
          model -> {:fallback_model, model}
        end

      failure_count < 8 ->
        try_fallback_provider(current_model, available_providers)

      true ->
        :give_up
    end
  end

  @doc """
  Apply a recovery strategy to session state.
  """
  @spec apply_strategy(strategy(), map()) :: {:ok, map()} | {:error, term()}
  def apply_strategy(:reset_backoff, state) do
    Logger.info("RateLimitRecovery: Applying reset_backoff strategy")
    {:ok, Map.put(state, :backoff_reset_at, System.system_time(:millisecond))}
  end

  def apply_strategy({:fallback_model, fallback_model}, state) do
    Logger.info("RateLimitRecovery: Switching to fallback model #{fallback_model.id}")

    {:ok,
     state
     |> Map.put(:model, fallback_model)
     |> Map.put(:original_model, Map.get(state, :model))
     |> Map.put(:strategy_applied, :fallback_model)}
  end

  def apply_strategy({:fallback_provider, fallback_provider}, state) do
    Logger.info("RateLimitRecovery: Switching to fallback provider #{fallback_provider}")

    case find_model_on_provider(fallback_provider, state) do
      nil ->
        {:error, {:no_suitable_model, fallback_provider}}

      model ->
        {:ok,
         state
         |> Map.put(:model, model)
         |> Map.put(:provider, fallback_provider)
         |> Map.put(:original_model, Map.get(state, :model))
         |> Map.put(:original_provider, Map.get(state, :provider))
         |> Map.put(:strategy_applied, :fallback_provider)}
    end
  end

  def apply_strategy({:session_fork, opts}, state) do
    Logger.info("RateLimitRecovery: Initiating session fork")

    {:ok,
     state
     |> Map.put(:fork_requested, true)
     |> Map.put(:fork_opts, opts)
     |> Map.put(:strategy_applied, :session_fork)}
  end

  def apply_strategy(:give_up, _state) do
    Logger.warning("RateLimitRecovery: All strategies exhausted, giving up")
    {:error, :recovery_strategies_exhausted}
  end

  @doc """
  Find a suitable fallback model when the primary is rate-limited.
  """
  @spec find_fallback_model(Ai.Types.Model.t(), keyword()) :: Ai.Types.Model.t() | nil
  def find_fallback_model(current_model, _opts \\ []) do
    current_provider = current_model.provider

    # Get all models from the same provider first
    Models.get_models(current_provider)
    |> Enum.reject(fn m -> m.id == current_model.id end)
    |> List.first()
  end

  @doc """
  Try to find a fallback provider from the available list.
  """
  @spec try_fallback_provider(Ai.Types.Model.t(), [atom()]) :: strategy() | nil
  def try_fallback_provider(current_model, available_providers) do
    current_provider = current_model.provider

    case Enum.reject(available_providers, fn p -> p == current_provider end) do
      [] -> nil
      [fallback | _] -> {:fallback_provider, fallback}
    end
  end

  @doc """
  Find a suitable model on a specific provider.
  """
  @spec find_model_on_provider(atom(), map()) :: Ai.Types.Model.t() | nil
  def find_model_on_provider(provider, _state) do
    Models.get_models(provider) |> List.first()
  end

  @doc """
  Prepare context for a session fork.
  """
  @spec prepare_fork_context(map(), keyword()) :: %{
          messages: [map()],
          summary: String.t() | nil,
          todos: [map()],
          plans: [map()],
          metadata: map()
        }
  def prepare_fork_context(session_state, opts \\ []) do
    message_count = Keyword.get(opts, :preserve_message_count, 10)

    messages = get_recent_messages(session_state, message_count)
    summary = generate_conversation_summary(session_state)
    todos = get_active_todos(session_state)
    plans = get_active_plans(session_state)

    %{
      messages: messages,
      summary: summary,
      todos: todos,
      plans: plans,
      metadata: %{
        forked_from: get_session_id(session_state),
        forked_at: DateTime.utc_now(),
        fork_reason: :rate_limit_recovery
      }
    }
  end

  @doc """
  Create a fork notification message for the user.
  """
  @spec fork_notification(%{fork_reason: atom(), summary: String.t() | nil, todos: list()}) ::
          String.t()
  def fork_notification(context) do
    reason_msg =
      case context.fork_reason do
        :rate_limit_recovery -> "due to persistent rate limiting"
        :healing_failed -> "because automatic recovery was unsuccessful"
        _ -> "to continue the conversation"
      end

    summary_info =
      if context.summary do
        "\n\nPrevious conversation summary:\n#{context.summary}"
      else
        ""
      end

    todo_info =
      if context.todos != [] do
        todo_list = Enum.map_join(context.todos, "\n", &"- #{&1.content}")
        "\n\nOutstanding items:\n#{todo_list}"
      else
        ""
      end

    "Session forked #{reason_msg}.#{summary_info}#{todo_info}"
  end

  @doc """
  Emit telemetry events for recovery actions.
  """
  @spec emit_recovery_telemetry(atom(), map(), map()) :: :ok
  def emit_recovery_telemetry(event, state, extra_meta) do
    metadata =
      %{
        session_id: get_session_id(state),
        strategy: event
      }
      |> Map.merge(extra_meta)

    :telemetry.execute([:coding_agent, :rate_limit_recovery, event], %{}, metadata)
  end

  # Private helpers

  defp get_session_id(state) do
    cond do
      is_map_key(state, :session_id) -> state.session_id
      is_map_key(state, :session_manager) -> state.session_manager.header.id
      true -> "unknown"
    end
  end

  defp get_recent_messages(state, count) do
    cond do
      is_map_key(state, :messages) ->
        state.messages |> Enum.take(-count)

      is_map_key(state, :agent) and not is_nil(state.agent) ->
        agent_state = AgentCore.Agent.get_state(state.agent)
        Map.get(agent_state, :messages, []) |> Enum.take(-count)

      true ->
        []
    end
  end

  defp generate_conversation_summary(state) do
    cond do
      is_map_key(state, :compaction_summary) -> state.compaction_summary
      true -> nil
    end
  end

  defp get_active_todos(state) do
    cond do
      is_map_key(state, :todos) -> state.todos
      true -> []
    end
  end

  defp get_active_plans(state) do
    cond do
      is_map_key(state, :plans) -> state.plans
      true -> []
    end
  end
end
