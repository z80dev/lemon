defmodule LemonSimUi.MetricsController do
  @moduledoc false

  use LemonSimUi, :controller

  def index(conn, _params) do
    hosted_rooms =
      LemonCore.Store.list(LemonSimUi.HostedGame.room_table())
      |> Enum.map(fn {_id, room} -> room.status end)
      |> Enum.frequencies()

    arenas =
      Map.new(LemonSimUi.Arena.domains(), fn domain ->
        status = LemonSimUi.Arena.status(domain)

        {domain,
         %{
           enabled: status.enabled,
           on_air: is_binary(status.current_sim_id),
           state: status.current_status
         }}
      end)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> json(%{
      hosted_werewolf: LemonSimUi.Telemetry.snapshot(),
      hosted_rooms: hosted_rooms,
      hosted_runtime: %{
        recovery: LemonSimUi.HostedGame.recovery_status(),
        ai_tasks_active:
          LemonSimUi.HostedGame.AiTaskSupervisor |> Task.Supervisor.children() |> length(),
        ai_tasks_limit: Application.get_env(:lemon_sim_ui, :hosted_ai_concurrency, 4)
      },
      simulations: LemonSimUi.SimManager.runtime_status(),
      arenas: arenas
    })
  end
end
