defmodule LemonControlPlane.Methods.Status do
  @moduledoc """
  System status method.

  Returns comprehensive status information about the Lemon system including
  active runs, connected clients, release/build identity, offline provider
  credential presence, channel health, lifecycle availability, and skills status.

  Requires `read` scope.

  ## Response

      %{
        "server" => %{
          "version" => "2026.10.10",
          "build" => %{"runtimeMode" => "source-dev", "channel" => nil, "commit" => nil},
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
          "connected" => ["telegram"],
          "details" => [%{"id" => "telegram", "state" => "connected", "lastError" => nil}]
        },
        "providers" => [
          %{"id" => "openai", "configured" => true, "credential" => "missing",
            "default" => true, "lastError" => nil}
        ],
        "lifecycle" => %{"restart" => true, "stop" => true, "reason" => nil},
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
    server = server_status()
    connections = connection_status()
    runs = run_status()
    channels = channel_status()
    skills = skills_status()

    providers = optional([], &LemonControlPlane.ProviderStatus.snapshot/0)

    {:ok,
     %{
       "server" => server,
       "connections" => connections,
       "runs" => runs,
       "channels" => channels,
       "skills" => skills,
       "providers" => providers,
       "lifecycle" => LemonControlPlane.Lifecycle.availability(),
       "summary" => summary(server, connections, runs, channels, skills, providers)
     }}
  end

  defp summary(server, connections, runs, channels, skills, providers) do
    beam = server["beam"] || %{}

    %{
      "action" => "status",
      "version" => server["version"],
      "uptimeMs" => server["uptime_ms"],
      "memoryMb" => server["memory_mb"],
      "schedulerCount" => server["schedulers"],
      "processCount" => beam["processCount"],
      "processLimit" => beam["processLimit"],
      "portCount" => beam["portCount"],
      "portLimit" => beam["portLimit"],
      "atomCount" => beam["atomCount"],
      "atomLimit" => beam["atomLimit"],
      "runQueue" => beam["runQueue"],
      "connectionCount" => connections["active"],
      "operatorCount" => connections["operators"],
      "nodeCount" => connections["nodes"],
      "activeRunCount" => runs["active"],
      "queuedRunCount" => runs["queued"],
      "completedTodayCount" => runs["completed_today"],
      "configuredChannelCount" => length(channels["configured"] || []),
      "connectedChannelCount" => length(channels["connected"] || []),
      "channelErrorCount" => Enum.count(channels["details"] || [], &(&1["state"] == "error")),
      "providerCount" => length(providers),
      "providersMissingCredentials" => Enum.count(providers, &(&1["credential"] == "missing")),
      "installedSkillCount" => skills["installed"],
      "enabledSkillCount" => skills["enabled"],
      "cleanup" => %{
        "includesRawProcessState" => false,
        "includesChannelCredentials" => false,
        "includesSkillSources" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp server_status do
    {uptime, _} = :erlang.statistics(:wall_clock)
    memory_bytes = :erlang.memory(:total)

    %{
      "version" => LemonControlPlane.server_version(),
      "build" =>
        optional(%{"runtimeMode" => "source-dev", "channel" => nil, "commit" => nil}, fn ->
          info = LemonCore.BuildInfo.current(include_git: false)

          %{
            "runtimeMode" => info.runtime_mode,
            "channel" => info.release_channel,
            "commit" => info.git.commit
          }
        end),
      "uptime_ms" => uptime,
      "memory_mb" => Float.round(memory_bytes / 1_048_576, 2),
      "otp_release" => to_string(:erlang.system_info(:otp_release)),
      "schedulers" => System.schedulers_online(),
      "beam" => beam_status()
    }
  end

  defp beam_status do
    %{
      "processCount" => :erlang.system_info(:process_count),
      "processLimit" => :erlang.system_info(:process_limit),
      "portCount" => :erlang.system_info(:port_count),
      "portLimit" => :erlang.system_info(:port_limit),
      "atomCount" => :erlang.system_info(:atom_count),
      "atomLimit" => :erlang.system_info(:atom_limit),
      "runQueue" => :erlang.statistics(:run_queue)
    }
  end

  defp connection_status do
    # Get counts from presence if available
    presence_counts = get_presence_counts()

    %{
      "active" => presence_counts.total,
      "operators" => presence_counts.operators,
      "nodes" => presence_counts.nodes
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
      "connected" => channels.connected,
      "details" => Map.get(channels, :details, [])
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

  defp get_presence_counts do
    optional(%{total: 0, operators: 0, nodes: 0}, &LemonControlPlane.Presence.counts/0)
  end

  # LemonRouter.counts/0 always returns the full shape, zeroed when the router
  # is not running.
  defp get_run_counts, do: LemonRouter.counts()

  defp get_channel_status do
    optional(%{configured: [], connected: [], details: []}, &LemonChannels.Registry.status/0)
  end

  defp get_skills_status do
    optional(%{installed: 0, enabled: 0}, &LemonSkills.Registry.counts/0)
  end

  # Presence, channels and skills are reported as empty while their server is
  # not running. A call to a stopped or restarting GenServer exits rather than
  # raises, and that exit must not fail the whole status request.
  defp optional(default, fun) do
    fun.()
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end
end
