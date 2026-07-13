defmodule LemonSimUi.HealthController do
  use LemonSimUi, :controller

  def index(conn, _params) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> text("ok")
  end

  def ready(conn, _params) do
    checks = %{
      arenas: processes_ready?(Enum.map(LemonSimUi.Arena.domains(), &LemonSimUi.Arena.name/1)),
      hosted_games: hosted_games_ready?(),
      sim_manager: process_ready?(LemonSimUi.SimManager),
      store: store_ready?()
    }

    ready? = Enum.all?(checks, fn {_name, status} -> status == "ok" end)

    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_status(if(ready?, do: :ok, else: :service_unavailable))
    |> json(%{
      ok: ready?,
      status: if(ready?, do: "ready", else: "unavailable"),
      checks: checks,
      simulations: simulation_capacity(),
      build: build_identity()
    })
  end

  defp processes_ready?(names) do
    if Enum.all?(names, &(process_ready?(&1) == "ok")), do: "ok", else: "unavailable"
  end

  defp process_ready?(name) do
    case Process.whereis(name) do
      pid when is_pid(pid) -> "ok"
      _ -> "unavailable"
    end
  end

  defp hosted_games_ready? do
    processes =
      processes_ready?([
        LemonSimUi.HostedGame,
        LemonSimUi.HostedGame.Supervisor,
        LemonSimUi.HostedGame.Registry,
        LemonSimUi.HostedGame.RoomSupervisor,
        LemonSimUi.HostedGame.AiTaskSupervisor
      ])

    recovery = LemonSimUi.HostedGame.recovery_status()

    if processes == "ok" and recovery.status == "ok", do: "ok", else: "unavailable"
  rescue
    _ -> "unavailable"
  catch
    :exit, _ -> "unavailable"
  end

  defp store_ready? do
    case LemonCore.Store.ping() do
      :ok -> "ok"
      _ -> "unavailable"
    end
  rescue
    _ -> "unavailable"
  catch
    :exit, _ -> "unavailable"
  end

  defp simulation_capacity do
    LemonSimUi.SimManager.runtime_status()
  rescue
    _ -> %{status: "unavailable"}
  catch
    :exit, _ -> %{status: "unavailable"}
  end

  defp build_identity do
    info = LemonCore.BuildInfo.current()

    %{
      commit: info.git.commit,
      release: info.release_name,
      version:
        info.release_version || info.lemon_version ||
          Application.spec(:lemon_sim_ui, :vsn) |> to_string()
    }
  end
end
