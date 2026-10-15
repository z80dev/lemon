defmodule LemonOmp.Application do
  @moduledoc false

  use Application

  require Logger

  @tools [{:omp, LemonOmp.Tools.Omp}]

  @impl true
  def start(_type, _args) do
    # The manager starts first so it outlives the sessions on shutdown: the
    # session supervisor stops every omp process (publishing its exit) while
    # the snapshot table still exists.
    children = [
      LemonOmp.Manager,
      LemonOmp.Models,
      {DynamicSupervisor, name: LemonOmp.SessionSupervisor, strategy: :one_for_one}
    ]

    with {:ok, pid} <-
           Supervisor.start_link(children, strategy: :rest_for_one, name: LemonOmp.Supervisor) do
      register_tools()
      {:ok, pid}
    end
  end

  # The coding product must not name this app, so the `omp` tool contributes
  # itself through the platform registry. It registers even when omp is not
  # installed; the tool then answers with a normal "not installed" result.
  defp register_tools do
    if Code.ensure_loaded?(LemonAgent.ToolRegistry) do
      Enum.each(@tools, fn {name, module} -> LemonAgent.ToolRegistry.register(name, module) end)
    end

    :ok
  rescue
    error ->
      Logger.debug("omp: tool not registered: #{inspect(error)}")
      :ok
  end
end
