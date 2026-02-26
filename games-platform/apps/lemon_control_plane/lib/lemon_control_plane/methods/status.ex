defmodule LemonControlPlane.Methods.Status do
  @moduledoc """
  System status method.

  Returns comprehensive status information about the Lemon system including
  active runs, connected clients, channels, and skills status.

  Requires `read` scope.

  ## Response

      %{
        "server" => %{
          "version" => "0.1.0",
          "uptime_ms" => 12345,
          "memory_mb" => 256.5
        },
        "connections" => %{
          "active" => 5,
          "operators" => 3,
          "nodes" => 2
        },
        "runs" => %{
          "active" => 2,
          "queued" => 0,
          "completed_today" => 15
        },
        "channels" => %{
          "configured" => ["telegram"],
          "connected" => ["telegram"]
        },
        "skills" => %{
          "installed" => 10,
          "enabled" => 8
        }
      }
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "status"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    {:ok,
     %{
       "server" => server_status(),
       "connections" => connection_status(),
       "runs" => run_status(),
       "channels" => channel_status(),
       "skills" => skills_status()
     }}
  end

  defp server_status do
    {uptime, _} = :erlang.statistics(:wall_clock)
    memory_bytes = :erlang.memory(:total)

    %{
      "version" => LemonControlPlane.server_version(),
      "uptime_ms" => uptime,
      "memory_mb" => Float.round(memory_bytes / 1_048_576, 2),
      "otp_release" => to_string(:erlang.system_info(:otp_release)),
      "schedulers" => System.schedulers_online()
    }
  end

  defp connection_status do
    # Get counts from presence if available
    presence_counts = get_presence_counts()

    %{
      "active" => presence_counts.total,
      "operators" => presence_counts.operators,
      "nodes" => presence_counts.nodes,
      "devices" => presence_counts.devices
    }
  end

  defp run_status do
    # Get run counts from router if available
    run_counts = get_run_counts()

    %{
      "active" => run_counts.active,
      "queued" => run_counts.queued,
      "completed_today" => run_counts.completed_today
    }
  end

  defp channel_status do
    # Get channel status from lemon_channels if available
    channels = get_channel_status()

    %{
      "configured" => channels.configured,
      "connected" => channels.connected
    }
  end

  defp skills_status do
    # Get skills status from lemon_skills if available
    skills = get_skills_status()

    %{
      "installed" => skills.installed,
      "enabled" => skills.enabled
    }
  end

  # Helper to get presence counts - returns defaults if presence not available
  defp get_presence_counts do
    try do
      case Process.whereis(LemonControlPlane.Presence) do
        nil ->
          %{total: 0, operators: 0, nodes: 0, devices: 0}

        pid when is_pid(pid) ->
          LemonControlPlane.Presence.counts()
      end
    rescue
      _ -> %{total: 0, operators: 0, nodes: 0, devices: 0}
    end
  end

  # Helper to get run counts - returns defaults if router not available
  defp get_run_counts do
    try do
      # Try to get from LemonRouter if available
      case Code.ensure_loaded(LemonRouter.RunOrchestrator) do
        {:module, _} ->
          LemonRouter.RunOrchestrator.counts()

        _ ->
          %{active: 0, queued: 0, completed_today: 0}
      end
    rescue
      _ -> %{active: 0, queued: 0, completed_today: 0}
    end
  end

  # Helper to get channel status - returns defaults if not available
  defp get_channel_status do
    try do
      case Code.ensure_loaded(LemonChannels.Registry) do
        {:module, _} ->
          LemonChannels.Registry.status()

        _ ->
          %{configured: [], connected: []}
      end
    rescue
      _ -> %{configured: [], connected: []}
    end
  end

  # Helper to get skills status - returns defaults if not available
  defp get_skills_status do
    try do
      case Code.ensure_loaded(LemonSkills.Registry) do
        {:module, _} ->
          LemonSkills.Registry.counts()

        _ ->
          %{installed: 0, enabled: 0}
      end
    rescue
      _ -> %{installed: 0, enabled: 0}
    end
  end
end
