defmodule XApi.Application do
  @moduledoc false

  use Application

  require Logger

  @tools [
    {:x_search, XApi.Tools.XSearch},
    {:post_to_x, XApi.Tools.PostToX},
    {:get_x_mentions, XApi.Tools.GetXMentions}
  ]

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:x_api, :start_token_manager, true) != false do
        [XApi.TokenManager]
      else
        []
      end

    case Supervisor.start_link(children, strategy: :one_for_one, name: XApi.Supervisor) do
      {:ok, pid} ->
        register_channel_adapter()
        register_tools()
        {:ok, pid}

      error ->
        error
    end
  end

  # The platform must not know X exists at compile time, so this integration
  # contributes itself on the way up.
  #
  # The guard is on the channel registry being *running*, not on the module
  # being loadable: lemon_channels is a hard dependency, so the module is always
  # loadable and the only meaningful "no channels here" is "not started" — which
  # is what a standalone or partially-started runtime looks like. Registering
  # into a registry that is not up exits `:noproc`, and an exit here would take
  # the whole application down on the way up, so it is caught as well.
  defp register_channel_adapter do
    if is_pid(Process.whereis(LemonChannels.Registry)) do
      case LemonChannels.Application.register_and_start_adapter(XApi.ChannelAdapter) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.debug("x_api channel adapter not started: #{inspect(reason)}")
          :ok
      end
    else
      Logger.debug("x_api channel adapter not started: lemon_channels registry not running")
      :ok
    end
  catch
    :exit, reason ->
      Logger.debug("x_api channel adapter not started: #{inspect(reason)}")
      :ok
  end

  # Same for the three agent tools: they register with the agent runtime rather
  # than appearing in any platform-owned tool list.
  defp register_tools do
    if Code.ensure_loaded?(AgentCore.ToolRegistry) do
      Enum.each(@tools, fn {name, module} ->
        AgentCore.ToolRegistry.register(name, module)
      end)
    end

    :ok
  end
end
