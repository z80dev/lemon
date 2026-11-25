defmodule LemonControlPlane.HTTP.HealthzTest.ProbeApp do
  @moduledoc false
  use Application

  @worker LemonControlPlane.HTTP.HealthzTest.ProbeWorker

  def worker, do: @worker

  @impl true
  def start(_type, _args) do
    worker = %{id: :worker, start: {Agent, :start_link, [fn -> :ok end, [name: @worker]]}}
    Supervisor.start_link([worker], strategy: :one_for_one, max_restarts: 1, max_seconds: 60)
  end
end

defmodule LemonControlPlane.HTTP.HealthzTest do
  @moduledoc "/healthz reflects supervised application status (#726)."
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias LemonControlPlane.HTTP.HealthzTest.ProbeApp
  alias LemonControlPlane.HTTP.Router

  @app :lemon_healthz_probe

  setup do
    spec = [
      description: ~c"healthz probe",
      vsn: ~c"0.0.0",
      modules: [ProbeApp],
      registered: [],
      applications: [:kernel, :stdlib],
      mod: {ProbeApp, []}
    ]

    :ok = :application.load({:application, @app, spec})

    on_exit(fn ->
      Application.stop(@app)
      Application.unload(@app)
    end)
  end

  test "a supervised app that exhausts its restart budget makes /healthz unhealthy" do
    {:ok, _} = Application.ensure_all_started(@app)

    assert %{status: 200, body: %{"ok" => true}} = healthz()

    capture_log(fn ->
      for _restart <- 1..2, do: kill_worker()
      wait_until(fn -> not started?(@app) end)
    end)

    assert %{status: 503, body: body} = healthz()
    assert body == %{"ok" => false, "profile" => nil, "missing" => ["lemon_healthz_probe"]}
  end

  test "a node without a runtime profile is healthy" do
    assert %{status: 200, body: %{"ok" => true}} =
             conn() |> Router.call(health: [profile: :none]) |> json()
  end

  test "an unknown runtime profile is unhealthy" do
    assert %{status: 503, body: %{"ok" => false, "error" => "unknown_runtime_profile"}} =
             conn() |> Router.call(health: [profile: {:error, :unknown_profile}]) |> json()
  end

  defp healthz, do: conn() |> Router.call(health: [apps: [@app]]) |> json()

  defp conn, do: %{Plug.Test.conn(:get, "/healthz") | host: "localhost"}

  defp json(conn), do: %{status: conn.status, body: Jason.decode!(conn.resp_body)}

  defp kill_worker do
    pid = wait_until(fn -> Process.whereis(ProbeApp.worker()) end)
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
  end

  defp started?(app), do: List.keymember?(Application.started_applications(), app, 0)

  defp wait_until(fun, attempts \\ 200) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _ when attempts > 0 ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)

      _ ->
        flunk("condition not met")
    end
  end
end
