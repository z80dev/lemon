defmodule CodingAgent.ControlPlaneProvider do
  @moduledoc """
  Exposes this agent's internals to the control plane's ops methods.

  The control plane reports on tasks, sessions, extensions, the run graph and
  progress, but must not depend on this app; it calls whatever provider is
  registered (see `LemonControlPlane.AgentRuntime`). `CodingAgent.Application`
  registers this module at boot.

  Each function is a thin adapter over the agent's own modules. Shapes match
  what the control plane used to read directly, so method payloads are
  unchanged.

  The `LemonControlPlane.AgentRuntime.Provider` behaviour is deliberately *not*
  declared here: this app must stay extractable without the reference runtime,
  so it carries no compile-time reference to it. `control_plane_provider_test`
  checks this module against the behaviour's callback list at runtime instead.
  """

  def list_tasks, do: CodingAgent.TaskStore.list(:all)

  def get_task(task_id), do: CodingAgent.TaskStore.get(task_id)

  def todo_progress(session_key) do
    case CodingAgent.Tools.TodoStore.get_progress(session_key) do
      progress when is_map(progress) ->
        actionable_count = session_key |> CodingAgent.Tools.TodoStore.get_actionable() |> length()
        Map.put(progress, :actionable_count, actionable_count)

      _ ->
        nil
    end
  end

  def feature_progress(cwd), do: CodingAgent.Tools.FeatureRequirements.get_progress(cwd)

  def compact_session(session_key, opts) do
    case Registry.lookup(CodingAgent.SessionRegistry, session_key) do
      [{pid, _}] -> CodingAgent.Session.compact(pid, opts)
      [] -> {:error, :session_not_found}
    end
  end

  def session_heartbeat(session_key, action, params) do
    case CodingAgent.SessionRegistry.lookup_session_key(session_key) do
      {:ok, pid} -> dispatch_session_heartbeat(pid, action, params)
      :error -> {:error, :session_not_found}
      {:error, :ambiguous} -> {:error, :session_ambiguous}
    end
  end

  def background_start(prompt, opts), do: CodingAgent.BackgroundRun.start(prompt, opts)

  def background_list(opts) do
    opts
    |> normalize_background_list_opts()
    |> CodingAgent.BackgroundRun.list()
  end

  def background_list_scoped(session_key, opts) do
    opts
    |> normalize_background_list_opts()
    |> then(&CodingAgent.BackgroundRun.list_scoped(session_key, &1))
  end

  def background_status(id), do: CodingAgent.BackgroundRun.status(id)

  def background_status_scoped(id, session_key),
    do: CodingAgent.BackgroundRun.status_scoped(id, session_key)

  def background_result(id), do: CodingAgent.BackgroundRun.result(id)

  def background_result_scoped(id, session_key),
    do: CodingAgent.BackgroundRun.result_scoped(id, session_key)

  def background_cancel(id), do: CodingAgent.BackgroundRun.cancel(id)

  def background_cancel_scoped(id, session_key),
    do: CodingAgent.BackgroundRun.cancel_scoped(id, session_key)

  def side_query(source, question, opts), do: CodingAgent.SideQuery.ask(source, question, opts)

  def run_graph(run_id), do: CodingAgent.RunGraph.get(run_id)

  def progress_snapshot(session_id, cwd), do: CodingAgent.Progress.snapshot(session_id, cwd)

  def load_extensions(paths), do: CodingAgent.Extensions.load_extensions_with_errors(paths)

  def extension_providers(extensions), do: CodingAgent.Extensions.get_providers(extensions)

  def extension_info(extensions), do: CodingAgent.Extensions.get_info(extensions)

  def tool_conflicts(cwd, opts), do: CodingAgent.ToolRegistry.tool_conflict_report(cwd, opts)

  def extension_dirs(cwd) do
    [CodingAgent.Config.extensions_dir(), CodingAgent.Config.project_extensions_dir(cwd)]
  end

  def wasm_sidecar_running? do
    is_pid(Process.whereis(CodingAgent.Wasm.SidecarSupervisor))
  end

  defp normalize_background_list_opts(opts) do
    case Keyword.get(opts, :status) do
      status
      when status in ~w(queued running completed error lost killed cancelled tracking_lost) ->
        Keyword.put(opts, :status, String.to_existing_atom(status))

      _ ->
        Keyword.delete(opts, :status)
    end
  end

  defp dispatch_session_heartbeat(pid, :status, _params),
    do: CodingAgent.Session.heartbeat_status(pid)

  defp dispatch_session_heartbeat(pid, :set, params) do
    CodingAgent.Session.heartbeat_set(pid, params[:prompt], params[:interval_seconds])
  end

  defp dispatch_session_heartbeat(pid, :pause, _params),
    do: CodingAgent.Session.heartbeat_pause(pid)

  defp dispatch_session_heartbeat(pid, :resume, _params),
    do: CodingAgent.Session.heartbeat_resume(pid)

  defp dispatch_session_heartbeat(pid, :clear, _params),
    do: CodingAgent.Session.heartbeat_clear(pid)

  defp dispatch_session_heartbeat(_pid, _action, _params), do: {:error, :invalid_action}
end
