defmodule LemonComputerUse.Application do
  @moduledoc false

  use Application

  require Logger

  alias LemonComputerUse.Config

  @tools [
    {:cua_js, LemonComputerUse.Tools.Js},
    {:cua_js_reset, LemonComputerUse.Tools.JsReset}
  ]

  @impl true
  def start(_type, _args) do
    enabled? = Config.enabled?()

    # Native apps remain opt-in. A connected, selected LCU browser also needs
    # this bridge; no Chrome surface is added for any other resolved provider.
    children =
      if enabled?, do: [{LemonComputerUse.Server, connect: true}], else: []

    with {:ok, pid} <-
           Supervisor.start_link(children,
             strategy: :one_for_one,
             name: LemonComputerUse.Supervisor
           ) do
      if enabled?, do: contribute()
      {:ok, pid}
    end
  end

  # The coding product must not name this app, so the tools and the prompt
  # section contribute themselves through the platform registries.
  defp contribute do
    if Code.ensure_loaded?(LemonAgent.ToolRegistry) do
      # LCU owns native-app effects outside Lemon's managed launch seams.
      # Keep the default unknown provenance for construction and execution fences.
      Enum.each(@tools, fn {name, module} -> LemonAgent.ToolRegistry.register(name, module) end)
    end

    if Code.ensure_loaded?(LemonAgent.ContextRegistry) do
      LemonAgent.ContextRegistry.register(:computer_use, LemonComputerUse.ContextContributor)
    end

    :ok
  rescue
    error ->
      Logger.debug("computer_use: not registered: #{inspect(error)}")
      :ok
  end
end
