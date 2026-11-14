defmodule LemonControlPlane.Methods.SystemReloadCode do
  @moduledoc "Soft-reloads source runtime code and optionally refreshes idle session tools."
  @behaviour LemonControlPlane.Method

  @max_modules 200

  @impl true
  def name, do: "system.reload_code"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) when is_map(params) do
    if valid_params?(params) do
      if System.get_env("LEMON_CLI_LAUNCHER") == "source" and :code.get_mode() == :interactive do
        reload(Map.get(params, "sessions", true))
      else
        {:error, {:unavailable, "Code reload requires an interactive source launcher runtime."}}
      end
    else
      invalid_params()
    end
  end

  def handle(_, _), do: invalid_params()

  defp valid_params?(params) do
    Enum.all?(params, fn
      {"sessions", value} -> is_boolean(value)
      _ -> false
    end)
  end

  defp invalid_params do
    {:error,
     {:invalid_request, "system.reload_code expects an object with optional boolean sessions."}}
  end

  defp reload(refresh_sessions?) do
    reloader = Application.get_env(:lemon_control_plane, :code_reloader, LemonCore.CodeReload)

    refresher =
      Application.get_env(
        :lemon_control_plane,
        :code_reload_session_refresher,
        LemonCore.CodeReload
      )

    initial = reloader.reload_modified([])

    sessions =
      if refresh_sessions?,
        do: refresher.refresh_sessions(),
        else: %{refreshed: 0, busy: 0, failed: 0}

    retried = reloader.retry_in_use(initial.in_use)
    reloaded = Enum.uniq(initial.reloaded ++ retried.reloaded)
    in_use = Enum.uniq(retried.in_use)
    failed = Enum.uniq_by(initial.failed ++ retried.failed, &elem(&1, 0))

    {:ok,
     %{
       "reloaded" => module_names(reloaded),
       "inUse" => module_names(in_use),
       "failed" =>
         Enum.map(Enum.take(failed, @max_modules), fn {module, reason} ->
           %{"module" => Atom.to_string(module), "reason" => safe_reason(reason)}
         end),
       "reloadedCount" => length(reloaded),
       "inUseCount" => length(in_use),
       "failedCount" => length(failed),
       "sessions" => %{
         "refreshed" => sessions.refreshed,
         "busy" => sessions.busy,
         "failed" => sessions.failed
       }
     }}
  rescue
    _ ->
      {:error, {:unavailable, "Code reload failed; some changes may already have been applied."}}
  catch
    _, _ ->
      {:error, {:unavailable, "Code reload failed; some changes may already have been applied."}}
  end

  defp module_names(modules) do
    modules |> Enum.take(@max_modules) |> Enum.map(&Atom.to_string/1)
  end

  defp safe_reason(reason)
       when reason in [:nofile, :badfile, :on_load_failure, :not_purged, :sticky_directory],
       do: Atom.to_string(reason)

  defp safe_reason(_), do: "load_failed"
end
