defmodule LemonCore.Onboarding.LogSilencer do
  @moduledoc false

  @depth_key {__MODULE__, :depth}
  @state_key {__MODULE__, :state}
  @quiet_level :emergency

  @spec with_quiet_logs(boolean(), (-> result)) :: result when result: var
  def with_quiet_logs(enabled, fun) when is_boolean(enabled) and is_function(fun, 0) do
    if enabled do
      enter(fun)
    else
      fun.()
    end
  end

  defp enter(fun) do
    case Process.get(@depth_key, 0) do
      0 ->
        state = snapshot()
        Process.put(@depth_key, 1)
        Process.put(@state_key, state)
        quiet!()

        try do
          fun.()
        after
          restore!(state)
          Process.delete(@depth_key)
          Process.delete(@state_key)
        end

      depth ->
        Process.put(@depth_key, depth + 1)

        try do
          fun.()
        after
          Process.put(@depth_key, depth)
        end
    end
  end

  defp snapshot do
    %{
      primary_level: Map.get(:logger.get_primary_config(), :level),
      default_handler_level:
        case :logger.get_handler_config(:default) do
          {:ok, %{level: level}} -> level
          _ -> nil
        end
    }
  end

  defp quiet! do
    :ok = :logger.set_primary_config(:level, @quiet_level)

    case :logger.get_handler_config(:default) do
      {:ok, _config} ->
        :ok = :logger.set_handler_config(:default, :level, @quiet_level)

      _ ->
        :ok
    end
  end

  defp restore!(state) do
    if state.primary_level do
      :ok = :logger.set_primary_config(:level, state.primary_level)
    end

    if state.default_handler_level do
      :ok = :logger.set_handler_config(:default, :level, state.default_handler_level)
    end
  end
end
