defmodule CodingAgent.Session.Diagnostics do
  @moduledoc """
  Builds diagnostic and health information for a session.

  Provides health checks, detailed diagnostics including message counts,
  error rates, tool call statistics, and subscriber counts.
  """

  # ============================================================================
  # Diagnostics Building
  # ============================================================================

  @doc """
  Build a full diagnostics map for the given session state.

  Returns a map with status, session_id, uptime, streaming state, agent health,
  message counts, tool call statistics, error rates, subscriber counts, and
  model information.
  """
  @spec build(map()) :: map()
  def build(state) do
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
      status: determine_health_status(agent_alive, error_rate, state),
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

  # ============================================================================
  # Health Check
  # ============================================================================

  @doc """
  Build a lightweight health check map from diagnostics.
  """
  @spec health_check(map()) :: map()
  def health_check(state) do
    diag = build(state)

    %{
      status: diag.status,
      session_id: diag.session_id,
      uptime_ms: diag.uptime_ms,
      is_streaming: diag.is_streaming,
      agent_alive: diag.agent_alive
    }
  end

  # ============================================================================
  # Stats
  # ============================================================================

  @doc """
  Build session statistics including message count, turn count, model info, etc.
  """
  @spec stats(map()) :: map()
  def stats(state) do
    agent_state = AgentCore.Agent.get_state(state.agent)
    messages = agent_state.messages

    %{
      message_count: length(messages),
      turn_count: state.turn_index,
      is_streaming: state.is_streaming,
      session_id: state.session_manager.header.id,
      cwd: state.cwd,
      model: %{
        provider: state.model.provider,
        id: state.model.id
      },
      thinking_level: state.thinking_level
    }
  end

  # ============================================================================
  # Internal Helpers
  # ============================================================================

  @doc false
  @spec count_tool_results([map()]) :: {non_neg_integer(), non_neg_integer()}
  def count_tool_results(messages) do
    results = Enum.filter(messages, &match?(%Ai.Types.ToolResultMessage{}, &1))
    tool_call_count = length(results)
    error_count = Enum.count(results, fn msg -> Map.get(msg, :is_error, false) end)
    {tool_call_count, error_count}
  end

  @doc false
  @spec latest_activity_timestamp([map()], non_neg_integer()) :: non_neg_integer()
  def latest_activity_timestamp(messages, fallback) do
    Enum.reduce(messages, fallback, fn msg, acc ->
      ts = Map.get(msg, :timestamp)

      cond do
        is_integer(ts) and ts > acc -> ts
        true -> acc
      end
    end)
  end

  @doc false
  @spec determine_health_status(boolean() | nil, float(), map()) ::
          :healthy | :degraded | :unhealthy
  def determine_health_status(false, _error_rate, _state), do: :unhealthy
  def determine_health_status(nil, _error_rate, _state), do: :unhealthy
  def determine_health_status(true, error_rate, _state) when error_rate > 0.2, do: :degraded
  def determine_health_status(true, _error_rate, _state), do: :healthy
end
