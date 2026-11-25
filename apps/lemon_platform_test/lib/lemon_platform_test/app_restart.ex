defmodule LemonPlatformTest.AppRestart do
  @moduledoc """
  Scopes OTP application restarts and other VM-wide test fixtures.

  Use only in non-async tests. List every application under test in `apps`, and
  declare the global state the test mutates:

    * `:app_env` — `{app, key}` pairs to snapshot using `Application.fetch_env/2`.
    * `:system_env` — environment variable names to snapshot.
    * `:telemetry` — fresh test-owned handler IDs to detach on cleanup.

  Each named app starts out stopped inside the scope. The test can configure and
  start it as needed. Cleanup stops named apps and any dependencies started by
  the test, restores the declared env, and starts only the originally running
  named apps. Pre-existing dependencies and unrelated apps are left alone.
  """

  @doc "Runs `fun` with the named apps stopped and restores state on return or failure."
  def with_app_restart(apps, env, fun) do
    restore = snapshot(apps, env)

    try do
      stop_apps(apps, &(&1 in apps))
      fun.()
    after
      restore.()
    end
  end

  @doc "Stops the named apps and restores them via ExUnit `on_exit` after the test ends."
  def setup_app_restart(apps, env) do
    ExUnit.Callbacks.on_exit(snapshot(apps, env))
    stop_apps(apps, &(&1 in apps))
  end

  defp snapshot(apps, env) do
    originally_running = MapSet.new(Application.started_applications(), &elem(&1, 0))

    app_env =
      for {app, key} <- env[:app_env] || [], do: {{app, key}, Application.fetch_env(app, key)}

    system_env = for key <- env[:system_env] || [], do: {key, System.get_env(key)}
    handlers = env[:telemetry] || []

    fn ->
      # Resolve after the test because a previously stopped app's spec may not
      # have been loaded until the test started it.
      stop_apps(apps, &(&1 in apps or not MapSet.member?(originally_running, &1)))

      Enum.each(handlers, fn id -> _ = :telemetry.detach(id) end)

      Enum.each(app_env, fn
        {{app, key}, {:ok, value}} -> Application.put_env(app, key, value)
        {{app, key}, :error} -> Application.delete_env(app, key)
      end)

      Enum.each(system_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      for app <- dependency_order(apps), app in apps, MapSet.member?(originally_running, app) do
        :ok = Application.start(app)
      end

      :ok
    end
  end

  defp stop_apps(apps, owned?) do
    apps
    |> dependency_order()
    |> Enum.filter(owned?)
    |> Enum.reverse()
    |> Enum.each(fn app ->
      case Application.stop(app) do
        :ok -> :ok
        {:error, {:not_started, ^app}} -> :ok
        {:error, reason} -> raise "failed to stop #{app}: #{inspect(reason)}"
      end
    end)
  end

  defp dependency_order(apps) do
    {ordered, _seen} = Enum.reduce(apps, {[], MapSet.new()}, &visit_app/2)
    Enum.reverse(ordered)
  end

  defp visit_app(app, {ordered, seen} = state) do
    if MapSet.member?(seen, app) do
      state
    else
      deps = Application.spec(app, :applications) || []
      {ordered, seen} = Enum.reduce(deps, {ordered, MapSet.put(seen, app)}, &visit_app/2)
      {[app | ordered], seen}
    end
  end
end
