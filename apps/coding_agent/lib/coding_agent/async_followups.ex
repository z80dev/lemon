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
          {:live, :followup | :steer} | {:router, queue_mode()}
  def dispatch_target(queue_mode, session_module, session_pid) do
    cond do
      queue_mode == :followup and live_session_available?(session_module, session_pid) ->
        {:live, :followup}

      queue_mode == :steer and live_session_streaming?(session_module, session_pid) ->
        {:live, :steer}

      queue_mode == :steer_backlog and live_session_streaming?(session_module, session_pid) ->
        {:live, :steer}

      queue_mode == :steer_backlog and live_session_available?(session_module, session_pid) ->
        {:live, :followup}

      queue_mode == :steer ->
        {:router, :followup}

      true ->
        {:router, queue_mode}
    end
  end

  @spec router_fallback_queue_mode(:followup | :steer) :: :followup
  def router_fallback_queue_mode(:followup), do: :followup
  def router_fallback_queue_mode(:steer), do: :followup

  @spec live_delivery_mode(map()) :: :followup | :steer
  def live_delivery_mode(%{details: details}) when is_map(details) do
    case Map.get(details, :delivery) || Map.get(details, "delivery") do
      :steer -> :steer
      "steer" -> :steer
      _ -> :followup
    end
  end

  def live_delivery_mode(_message), do: :followup

  @spec live_session_available?(module(), pid() | nil) :: boolean()
  def live_session_available?(session_module, session_pid) do
    is_pid(session_pid) and Process.alive?(session_pid) and
      function_exported?(session_module, :handle_async_followup, 2)
  end

  @spec live_session_streaming?(module(), pid() | nil) :: boolean()
  def live_session_streaming?(session_module, session_pid) do
    if live_session_available?(session_module, session_pid) do
      cond do
        function_exported?(session_module, :get_state, 1) ->
          case session_module.get_state(session_pid) do
            %{is_streaming: true} -> true
            _ -> false
          end

        function_exported?(session_module, :health_check, 1) ->
          case session_module.health_check(session_pid) do
            %{is_streaming: true} -> true
            _ -> false
          end

        true ->
          true
      end
    else
      false
    end
  rescue
    _ -> false
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
