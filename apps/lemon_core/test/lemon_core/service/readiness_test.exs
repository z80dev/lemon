defmodule LemonCore.Service.ReadinessTest do
  use ExUnit.Case, async: true
  alias LemonCore.Service.{Readiness, Role}
  @moduletag :tmp_dir
  @started "Tue Nov 10 12:00:00 2026"

  setup %{tmp_dir: home} do
    {:ok,
     opts: [home: home, env: %{}, login_path: "/usr/bin:/bin"],
     manager: %{pid: 123, loaded: true, failed: false}}
  end

  test "controller needs true health and the exact manager PID", %{opts: opts, manager: manager} do
    {:ok, spec} = Role.build("controller", "launchd", opts)
    path = Path.join(opts[:home], ".lemon/run/lemon-4040.pid")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "123\n")
    healthy = Keyword.put(opts, :http_get, fn _ -> {:ok, %{"ok" => true}} end)
    assert {"ready", nil} = Readiness.probe(spec, manager, healthy)
    assert {"unsupervised", nil} = Readiness.probe(spec, %{manager | pid: 124}, healthy)
    bad = Keyword.put(opts, :http_get, fn _ -> {:ok, %{"ok" => "true"}} end)
    assert {"starting", nil} = Readiness.probe(spec, manager, bad)
  end

  test "backend requires matching instance and process birth identity", %{
    opts: opts,
    manager: manager
  } do
    spec = %{role: "backend", port: 4100, env: %{}}
    path = Readiness.backend_record(spec, opts)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{pid: 123, startedAt: @started, instanceId: "ours"}))
    File.chmod!(path, 0o600)

    opts =
      Keyword.merge(opts,
        uid: "501",
        command_runner: fn "ps", _, _ -> {"501 #{@started} /bin/bot\n", 0} end,
        http_get: fn _ -> {:ok, %{"product" => "lemon_bot", "instanceId" => "ours"}} end
      )

    assert {"ready", nil} = Readiness.probe(spec, manager, opts)

    mismatch =
      Keyword.put(opts, :http_get, fn _ ->
        {:ok, %{"product" => "lemon_bot", "instanceId" => "other"}}
      end)

    assert {"unsupervised", nil} = Readiness.probe(spec, manager, mismatch)
    assert {"unsupervised", nil} = Readiness.probe(spec, %{manager | pid: 125}, opts)
  end

  test "worker parking states and bounded reasons pass through only for the manager PID", %{
    opts: opts,
    manager: manager
  } do
    spec = %{role: "worker", name: "studio"}

    for state <- ~w(online starting reconnecting needs_reauthorization needs_enrollment conflict) do
      opts =
        Keyword.put(opts, :status_reader, fn "studio" ->
          {:ok, %{"state" => state, "osPid" => 123, "reason" => "session_expired"}}
        end)

      assert {^state, "session_expired"} = Readiness.probe(spec, manager, opts)
      assert {"unsupervised", nil} = Readiness.probe(spec, %{manager | pid: 124}, opts)
      assert {"stopped", nil} = Readiness.probe(spec, %{manager | pid: nil}, opts)
    end
  end

  test "absent optional worker module reports unknown", %{opts: opts, manager: manager} do
    opts = Keyword.put(opts, :status_reader, fn _ -> {:error, :module_unavailable} end)
    assert {"unknown", nil} = Readiness.probe(%{role: "worker", name: "studio"}, manager, opts)
  end

  test "unknown status reasons cannot expose a path or credential", %{
    opts: opts,
    manager: manager
  } do
    opts =
      Keyword.put(opts, :status_reader, fn _ ->
        {:ok, %{"state" => "needs_enrollment", "osPid" => 123, "reason" => "/private/secret"}}
      end)

    assert {"needs_enrollment", nil} =
             Readiness.probe(%{role: "worker", name: "studio"}, manager, opts)
  end
end
