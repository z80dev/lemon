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
end
