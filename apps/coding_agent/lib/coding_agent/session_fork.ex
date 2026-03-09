defmodule CodingAgent.SessionFork do
  @moduledoc """
  Session forking functionality for rate-limit recovery.
  """

  require Logger

  alias CodingAgent.RateLimitRecovery

  @type fork_options :: [
          reason: :rate_limit_recovery | :healing_failed | :manual,
          preserve_messages: pos_integer(),
          custom_summary: String.t() | nil,
          auto_terminate_original: boolean()
        ]

  @type fork_result :: %{
          new_session: pid(),
          new_session_id: String.t(),
          original_session_id: String.t(),
          carryover_summary: %{
            message_count: non_neg_integer(),
            todo_count: non_neg_integer(),
            plan_count: non_neg_integer()
          }
        }

  @doc """
  Fork a session for recovery purposes.
  """
  @spec fork_session(GenServer.server(), fork_options()) ::
          {:ok, fork_result()} | {:error, term()}
  def fork_session(original_session, opts \\ []) do
    _reason = Keyword.get(opts, :reason, :rate_limit_recovery)
    preserve_messages = Keyword.get(opts, :preserve_messages, 10)
    auto_terminate = Keyword.get(opts, :auto_terminate_original, false)

    with {:ok, original_state} <- get_session_state(original_session),
         original_session_id = get_session_id(original_state),
         cwd = get_cwd(original_state),
         model = get_model(original_state) do
      fork_context =
        RateLimitRecovery.prepare_fork_context(original_state,
          preserve_message_count: preserve_messages
        )

      summary =
        opts[:custom_summary] || fork_context.summary || generate_default_summary(fork_context)

      fork_opts = [
        cwd: cwd,
        parent_session: original_session_id,
        model: model,
        system_prompt: build_fork_system_prompt(original_state, summary)
      ]

      case CodingAgent.Session.start_link(fork_opts) do
        {:ok, new_session} ->
          result = %{
            new_session: new_session,
            new_session_id: get_new_session_id(new_session),
            original_session_id: original_session_id,
            carryover_summary: %{
              message_count: length(fork_context.messages),
              todo_count: length(fork_context.todos),
              plan_count: length(fork_context.plans)
            }
          }

          if auto_terminate do
            terminate_original_session(original_session, new_session_id: result.new_session_id)
          end

          emit_fork_telemetry(:fork_completed, original_session_id, result)
          {:ok, result}

        {:error, reason} = error ->
          Logger.error("SessionFork: Failed to create new session: #{inspect(reason)}")
          emit_fork_telemetry(:fork_failed, original_session_id, %{error: reason})
          error
      end
    end
  end

  @doc """
  Build a system prompt for the forked session.
  """
  @spec build_fork_system_prompt(map(), String.t()) :: String.t()
  def build_fork_system_prompt(original_state, summary) do
    base_prompt = Map.get(original_state, :system_prompt, "")

    fork_context = """

    [SESSION FORK CONTEXT]
    This session was forked from a previous conversation due to rate limiting.

    Previous conversation summary:
    #{summary}

    You have access to the recent message history. Continue assisting the user
    from where the previous session left off.
    """

    "#{base_prompt}#{fork_context}"
  end

  @doc """
  Build the fork notification message for the user.
  """
  @spec build_fork_message(atom(), String.t(), map()) :: String.t()
  def build_fork_message(reason, summary, context) do
    RateLimitRecovery.fork_notification(%{
      fork_reason: reason,
      summary: summary,
      todos: context.todos,
      plans: context.plans
    })
  end

  @doc """
  Terminate the original session after successful fork.
  """
  @spec terminate_original_session(GenServer.server(), keyword()) :: :ok
  def terminate_original_session(original_session, opts \\ []) do
    new_session_id = Keyword.get(opts, :new_session_id, "unknown")

    original_id =
      try do
        state = CodingAgent.Session.get_state(original_session)
        get_session_id(state)
      rescue
        _ -> "unknown"
      end

    Logger.info(
      "SessionFork: Terminating original session #{original_id} (forked to #{new_session_id})"
    )

    GenServer.stop(original_session, :normal)

    emit_fork_telemetry(:original_terminated, original_id, %{forked_to: new_session_id})

    :ok
  catch
    _, _ ->
      Logger.warning("SessionFork: Failed to terminate original session")
      :ok
  end

  @doc """
  Generate a default summary when none is available.
  """
  @spec generate_default_summary(map()) :: String.t()
  def generate_default_summary(context) do
    message_info =
      case context.messages do
        [] -> "No recent messages."
        msgs -> "Recent conversation with #{length(msgs)} messages."
      end

    todo_info =
      case context.todos do
        [] -> ""
        todos -> " #{length(todos)} outstanding todo items."
      end

    "#{message_info}#{todo_info}"
  end

  @doc """
  Emit telemetry events for session forking.
  """
  @spec emit_fork_telemetry(atom(), String.t(), map()) :: :ok
  def emit_fork_telemetry(event, original_session_id, metadata) do
    :telemetry.execute(
      [:coding_agent, :session_fork, event],
      %{},
      Map.merge(metadata, %{
        original_session_id: original_session_id,
        timestamp: DateTime.utc_now()
      })
    )
  end

  # Private helpers

  defp get_session_state(session) do
    try do
      {:ok, CodingAgent.Session.get_state(session)}
    catch
      _, reason -> {:error, {:session_unavailable, reason}}
    end
  end

  defp get_session_id(state) do
    cond do
      is_map_key(state, :session_manager) and not is_nil(state.session_manager) ->
        state.session_manager.header.id

      is_map_key(state, :session_id) ->
        state.session_id

      true ->
        "unknown"
    end
  end

  defp get_cwd(state) do
    Map.get(state, :cwd, File.cwd!())
  end

  defp get_model(state) do
    Map.get(state, :model)
  end

  defp get_new_session_id(session) do
    try do
      state = CodingAgent.Session.get_state(session)
      get_session_id(state)
    catch
      _, _ -> "unknown"
    end
  end
end
