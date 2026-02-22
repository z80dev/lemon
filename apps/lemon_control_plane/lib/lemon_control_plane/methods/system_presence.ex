defmodule LemonControlPlane.Methods.SystemPresence do
  @moduledoc """
  Handler for the system-presence control plane method.

  Reports system presence information including connected clients,
  active runs, and resource usage.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "system-presence"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, ctx) do
    presence = build_presence(ctx)
    {:ok, presence}
  end

  defp build_presence(ctx) do
    %{
      "connId" => ctx[:conn_id],
      "connections" => count_connections(),
      "activeRuns" => count_active_runs(),
      "timestamp" => System.system_time(:millisecond),
      "health" => get_health_status(),
      "resources" => get_resource_usage()
    }
  end

  defp count_connections do
    if Code.ensure_loaded?(LemonControlPlane.WS.ConnectionSup) do
      safe_active_count(LemonControlPlane.WS.ConnectionSup)
    else
      0
    end
  end

  defp count_active_runs do
    if Code.ensure_loaded?(LemonRouter.RunSupervisor) do
      safe_active_count(LemonRouter.RunSupervisor)
    else
      0
    end
  end

  defp safe_active_count(supervisor) do
    case Process.whereis(supervisor) do
      pid when is_pid(pid) ->
        try do
          DynamicSupervisor.count_children(pid)[:active] || 0
        rescue
          _ -> 0
        catch
          :exit, _ -> 0
        end

      _ ->
        0
    end
  end

  defp get_health_status do
    %{
      "status" => "healthy",
      "uptime" => get_uptime_ms()
    }
  end

  defp get_uptime_ms do
    # Get system uptime in milliseconds
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    uptime_ms
  end

  defp get_resource_usage do
    memory = :erlang.memory()

    %{
      "memoryTotal" => memory[:total],
      "memoryProcesses" => memory[:processes],
      "memorySystem" => memory[:system],
      "processCount" => :erlang.system_info(:process_count),
      "schedulers" => :erlang.system_info(:schedulers_online)
    }
  end
end
