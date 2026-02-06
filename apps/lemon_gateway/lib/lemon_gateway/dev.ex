defmodule LemonGateway.Dev do
  @moduledoc """
  Development helpers.

  These helpers are meant for nodes started with `mix run ...` (source-based dev).
  They are not expected to work in releases where Mix is unavailable.
  """

  @apps_to_reload [
    :agent_core,
    :ai,
    :coding_agent,
    :coding_agent_ui,
    :lemon_core,
    :lemon_gateway,
    :lemon_router,
    :lemon_channels,
    :lemon_control_plane,
    :lemon_automation,
    :lemon_skills
  ]

  @type reload_result :: %{
          compile_ms: non_neg_integer(),
          compile_ran: boolean(),
          apps: [atom()],
          modules: non_neg_integer(),
          reloaded: non_neg_integer(),
          skipped: non_neg_integer(),
          errors: [{module(), term()}]
        }

  @spec recompile_and_reload(keyword()) :: {:ok, reload_result()} | {:error, term()}
  def recompile_and_reload(opts \\ []) do
    force? = Keyword.get(opts, :force, false)

    unless mix_available?() do
      {:error, :mix_unavailable}
    else
      compile_ms =
        measure_ms(fn ->
          Mix.Task.reenable("compile")
          args = if force?, do: ["--force"], else: []
          _ = Mix.Task.run("compile", args)
          :ok
        end)

      reload = reload_loaded_apps(@apps_to_reload)

      {:ok,
       %{
         compile_ms: compile_ms,
         compile_ran: true,
         apps: reload.apps,
         modules: reload.modules,
         reloaded: reload.reloaded,
         skipped: reload.skipped,
         errors: reload.errors
       }}
    end
  rescue
    e ->
      {:error, {:exception, Exception.message(e)}}
  catch
    kind, value ->
      {:error, {kind, value}}
  end

  defp mix_available? do
    Code.ensure_loaded?(Mix) and function_exported?(Mix.Task, :run, 2)
  end

  defp reload_loaded_apps(apps) do
    loaded =
      Application.loaded_applications()
      |> Enum.map(fn {app, _desc, _vsn} -> app end)
      |> MapSet.new()

    apps = Enum.filter(apps, &MapSet.member?(loaded, &1))

    modules =
      apps
      |> Enum.flat_map(fn app -> Application.spec(app, :modules) || [] end)
      |> Enum.uniq()

    {reloaded, skipped, errors} =
      Enum.reduce(modules, {0, 0, []}, fn mod, {ok, skip, errs} ->
        # Best-effort: if we already have two versions loaded, try to purge the old one.
        _ = :code.soft_purge(mod)

        case :code.load_file(mod) do
          {:module, _} ->
            {ok + 1, skip, errs}

          {:error, reason} ->
            {ok, skip + 1, [{mod, reason} | errs]}
        end
      end)

    %{
      apps: apps,
      modules: length(modules),
      reloaded: reloaded,
      skipped: skipped,
      errors: Enum.reverse(errors)
    }
  end

  defp measure_ms(fun) when is_function(fun, 0) do
    start = System.monotonic_time()
    _ = fun.()
    elapsed = System.monotonic_time() - start
    System.convert_time_unit(elapsed, :native, :millisecond)
  end
end
