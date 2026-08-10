defmodule LemonSimUi.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        LemonSimUi.Telemetry,
        {DynamicSupervisor, name: LemonSimUi.SimRunnerSupervisor, strategy: :one_for_one},
        {Task.Supervisor, name: LemonSimUi.TaskSupervisor},
        LemonSimUi.SimManager,
        LemonSimUi.HostedGame.Supervisor,
        LemonSimUi.PhilosopherChat.Supervisor
      ] ++
        arena_children() ++
        [LemonSimUi.Endpoint]

    opts = [strategy: :one_for_one, name: LemonSimUi.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # One always-on arena per domain; each idles unless its config enables it.
  defp arena_children do
    Enum.map(LemonSimUi.Arena.domains(), fn domain ->
      {LemonSimUi.Arena, [domain: domain]}
    end)
  end

  @impl true
  def config_change(changed, _new, removed) do
    LemonSimUi.Endpoint.config_change(changed, removed)
    :ok
  end
end
