defmodule CodingAgent.Session.State do
  @moduledoc false

  alias AgentCore.Types.AgentTool
  alias Ai.Types.{ImageContent, TextContent, UserMessage}
  alias CodingAgent.Config
  alias CodingAgent.ContextGuardrails
  alias CodingAgent.Security.UntrustedToolBoundary

  @spec normalize_extra_tools(term()) :: [AgentTool.t()]
  def normalize_extra_tools(tools) when is_list(tools) do
    Enum.filter(tools, &match?(%AgentTool{}, &1))
  end

  def normalize_extra_tools(_), do: []

  @spec build_transform_context(nil | (list(), reference() | nil -> term()), map()) ::
          (list(), reference() | nil -> {:ok, list()} | {:error, term()})
  def build_transform_context(nil, context_guardrail_opts) do
    fn messages, signal ->
      with {:ok, guarded} <-
             normalize_transform_result(
               ContextGuardrails.transform(messages, signal, context_guardrail_opts)
             ),
           {:ok, wrapped} <-
             normalize_transform_result(UntrustedToolBoundary.transform(guarded, signal)) do
        {:ok, wrapped}
      end
    end
  end

  def build_transform_context(transform_fn, context_guardrail_opts)
      when is_function(transform_fn, 2) do
    fn messages, signal ->
      with {:ok, guarded} <-
             normalize_transform_result(
               ContextGuardrails.transform(messages, signal, context_guardrail_opts)
             ),
           {:ok, wrapped} <-
             normalize_transform_result(UntrustedToolBoundary.transform(guarded, signal)),
           {:ok, transformed} <- normalize_transform_result(transform_fn.(wrapped, signal)) do
        {:ok, transformed}
      end
    end
  end

  @spec build_context_guardrail_opts(String.t(), String.t(), term()) :: map()
  def build_context_guardrail_opts(cwd, session_id, nil) do
    default_context_guardrail_opts(cwd, session_id)
  end

  def build_context_guardrail_opts(cwd, session_id, opts) when is_list(opts) do
    build_context_guardrail_opts(cwd, session_id, Enum.into(opts, %{}))
  end

  def build_context_guardrail_opts(cwd, session_id, opts) when is_map(opts) do
    Map.merge(default_context_guardrail_opts(cwd, session_id), opts)
  end

  def build_context_guardrail_opts(cwd, session_id, _other) do
    default_context_guardrail_opts(cwd, session_id)
  end

  @spec cancel_pending_prompt(map()) :: map()
  def cancel_pending_prompt(%{pending_prompt_timer_ref: nil} = state), do: state

  def cancel_pending_prompt(%{pending_prompt_timer_ref: timer_ref} = state) do
    _ = Process.cancel_timer(timer_ref)
    %{state | pending_prompt_timer_ref: nil, is_streaming: false}
  end

  @spec build_prompt_message(String.t(), keyword()) :: UserMessage.t()
  def build_prompt_message(text, opts \\ []) when is_binary(text) and is_list(opts) do
    images = Keyword.get(opts, :images, [])

    content =
      case images do
        [] ->
          text

        image_blocks ->
          [%TextContent{type: :text, text: text}] ++
            Enum.map(image_blocks, fn img ->
              %ImageContent{
                type: :image,
                data: img.data,
                mime_type: img.mime_type
              }
            end)
      end

    %UserMessage{
      role: :user,
      content: content,
      timestamp: System.system_time(:millisecond)
    }
  end

  @spec begin_prompt(map(), reference()) :: map()
  def begin_prompt(state, timer_ref) do
    %{
      state
      | is_streaming: true,
        pending_prompt_timer_ref: timer_ref,
        turn_index: state.turn_index + 1,
        overflow_recovery_in_progress: false,
        overflow_recovery_attempted: false,
        overflow_recovery_signature: nil,
        overflow_recovery_started_at_ms: nil,
        overflow_recovery_error_reason: nil,
        overflow_recovery_partial_state: nil
    }
  end

  @spec reset_runtime(map(), map(), non_neg_integer()) :: map()
  def reset_runtime(state, session_manager, started_at_ms) do
    %{
      state
      | session_manager: session_manager,
        is_streaming: false,
        pending_prompt_timer_ref: nil,
        turn_index: 0,
        started_at: started_at_ms,
        session_file: nil,
        steering_queue: :queue.new(),
        follow_up_queue: :queue.new(),
        auto_compaction_in_progress: false,
        auto_compaction_signature: nil,
        overflow_recovery_in_progress: false,
        overflow_recovery_attempted: false,
        overflow_recovery_signature: nil,
        overflow_recovery_started_at_ms: nil,
        overflow_recovery_error_reason: nil,
        overflow_recovery_partial_state: nil
    }
  end

  @spec build_diagnostics(map()) :: map()
  def build_diagnostics(state) do
    {messages, message_count} =
      if state.agent && Process.alive?(state.agent) do
        agent_state = AgentCore.Agent.get_state(state.agent)
        messages = agent_state.messages || []
        {messages, length(messages)}
      else
        {[], 0}
      end

    {tool_call_count, error_count} = count_tool_results(messages)
    error_rate = if tool_call_count == 0, do: 0.0, else: error_count / tool_call_count

    now = System.system_time(:millisecond)
    started_at = state.started_at || now
    last_activity_at = latest_activity_timestamp(messages, started_at)
    uptime_ms = max(now - started_at, 0)

    agent_alive = state.agent && Process.alive?(state.agent)

    %{
      status: determine_health_status(agent_alive, error_rate),
      session_id: state.session_manager.header.id,
      uptime_ms: uptime_ms,
      started_at: started_at,
      last_activity_at: last_activity_at,
      is_streaming: state.is_streaming,
      agent_alive: agent_alive,
      message_count: message_count,
      turn_count: state.turn_index,
      tool_call_count: tool_call_count,
      error_count: error_count,
      error_rate: error_rate,
      subscriber_count: length(state.event_listeners),
      stream_subscriber_count: map_size(state.event_streams),
      steering_queue_size: :queue.len(state.steering_queue),
      follow_up_queue_size: :queue.len(state.follow_up_queue),
      model: %{provider: state.model.provider, id: state.model.id},
      cwd: state.cwd,
      thinking_level: state.thinking_level
    }
  end

  defp default_context_guardrail_opts(cwd, session_id) do
    %{
      max_thinking_bytes: 65_536,
      max_tool_result_images: 0,
      spill_dir: Config.spill_dir(cwd, session_id)
    }
  end

  defp normalize_transform_result({:ok, transformed}) when is_list(transformed),
    do: {:ok, transformed}

  defp normalize_transform_result({:error, reason}), do: {:error, reason}
  defp normalize_transform_result(transformed) when is_list(transformed), do: {:ok, transformed}
  defp normalize_transform_result(_), do: {:error, :invalid_transform_result}

  defp count_tool_results(messages) do
    results = Enum.filter(messages, &match?(%Ai.Types.ToolResultMessage{}, &1))
    tool_call_count = length(results)
    error_count = Enum.count(results, fn msg -> Map.get(msg, :is_error, false) end)
    {tool_call_count, error_count}
  end

  defp latest_activity_timestamp(messages, fallback) do
    Enum.reduce(messages, fallback, fn msg, acc ->
      ts = Map.get(msg, :timestamp)

      cond do
        is_integer(ts) and ts > acc -> ts
        true -> acc
      end
    end)
  end

  defp determine_health_status(false, _error_rate), do: :unhealthy
  defp determine_health_status(true, error_rate) when error_rate > 0.2, do: :degraded
  defp determine_health_status(true, _error_rate), do: :healthy
end
