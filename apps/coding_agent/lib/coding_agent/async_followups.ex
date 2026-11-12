defmodule CodingAgent.AsyncFollowups do
  @moduledoc false

  @type queue_mode :: :collect | :followup | :interrupt | :steer | :steer_backlog
  @valid_queue_modes [:collect, :followup, :interrupt, :steer, :steer_backlog]

  @spec resolve_async_followup_queue_mode(queue_mode() | nil, queue_mode()) :: queue_mode()
  def resolve_async_followup_queue_mode(tool_queue_mode, fallback \\ :followup) do
    cond do
      not is_nil(tool_queue_mode) ->
        tool_queue_mode

      true ->
        configured_default_queue_mode() || fallback
    end
  end

  @spec dispatch_target(queue_mode(), module(), pid() | nil) ::
          {:live, :followup} | {:router, queue_mode()}
  def dispatch_target(queue_mode, session_module, session_pid) do
    cond do
      queue_mode in [:followup, :steer, :steer_backlog] and
          live_session_available?(session_module, session_pid) ->
        {:live, :followup}

      queue_mode in [:steer, :steer_backlog] ->
        {:router, :followup}

      true ->
        {:router, queue_mode}
    end
  end

  @spec router_fallback_queue_mode(:followup) :: :followup
  def router_fallback_queue_mode(:followup), do: :followup
  @spec live_session_available?(module(), pid() | nil) :: boolean()
  def live_session_available?(session_module, session_pid) do
    is_pid(session_pid) and Process.alive?(session_pid) and
      function_exported?(session_module, :handle_async_followup, 2)
  end

  defp configured_default_queue_mode do
    case Application.get_env(:coding_agent, :async_followups, []) do
      config when is_map(config) ->
        normalize_queue_mode(
          Map.get(config, :default_queue_mode) || Map.get(config, "default_queue_mode")
        )

      config when is_list(config) ->
        normalize_queue_mode(Keyword.get(config, :default_queue_mode))

      _other ->
        nil
    end
  end

  defp normalize_queue_mode(queue_mode) when queue_mode in @valid_queue_modes, do: queue_mode

  defp normalize_queue_mode(queue_mode) when is_binary(queue_mode) do
    case String.trim(queue_mode) do
      "collect" -> :collect
      "followup" -> :followup
      "interrupt" -> :interrupt
      "steer" -> :steer
      "steer_backlog" -> :steer_backlog
      _ -> nil
    end
  end

  defp normalize_queue_mode(_queue_mode), do: nil
end
