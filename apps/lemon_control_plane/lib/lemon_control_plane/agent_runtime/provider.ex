defmodule LemonControlPlane.AgentRuntime.Provider do
  @moduledoc """
  What the control plane needs from an agent runtime in order to introspect it.

  The control plane's ops methods (tasks, sessions, extensions, run graph,
  progress) report on a running agent, but the control plane must not depend on
  a particular agent product. An agent implements the callbacks it can support
  and registers itself — see `LemonControlPlane.AgentRuntime`.

  Every callback is optional. A provider that implements none is equivalent to
  no provider at all: each method falls back to its documented empty or
  unavailable response rather than failing.

  Return shapes mirror what the coding agent already returned, so the wire
  format of the methods is unchanged.

  Implementations may retain detailed failures internally, but callbacks used
  by background-command and side-query methods should prefer stable reason
  atoms. The control plane still treats every callback value as untrusted and
  never projects arbitrary reason terms or map fields onto the public wire.
  """

  @type task_id :: String.t()
  @type session_key :: String.t()

  @doc "All known tasks as `{task_id, record}` pairs."
  @callback list_tasks() :: [{task_id(), map()}]

  @doc "One task: `{:ok, record, events}` when known."
  @callback get_task(task_id()) :: {:ok, map(), [map()]} | term()

  @doc """
  Task-list progress for a session, including an `:actionable_count` key.

  Returns `nil` when the session has no task-list state.
  """
  @callback todo_progress(session_key()) :: map() | nil

  @doc "Feature-requirement progress for a working directory."
  @callback feature_progress(Path.t()) :: {:ok, map()} | term()

  @doc "Compacts a live session. `{:error, :session_not_found}` when it is not running."
  @callback compact_session(session_key(), keyword()) :: :ok | {:error, term()}

  @doc "Starts an isolated durable background agent session."
  @callback background_start(String.t(), keyword()) :: {:ok, map()} | {:error, term()}

  @doc "Lists durable background sessions, optionally filtered by status."
  @callback background_list(keyword()) :: [map()] | {:error, term()}

  @doc "Returns one background session's sanitized lifecycle summary."
  @callback background_status(String.t()) :: {:ok, map()} | {:error, term()}

  @doc "Returns one completed background session's visible answer."
  @callback background_result(String.t()) :: {:ok, String.t()} | {:error, term()}

  @doc "Cancels one queued or running background session."
  @callback background_cancel(String.t()) :: :ok | {:error, term()}

  @doc "Answers a bounded no-tools question against a frozen session context."
  @callback side_query(pid() | session_key() | map(), String.t(), keyword()) ::
              {:ok, String.t()} | {:error, term()}

  @doc "Run-graph record for a run id."
  @callback run_graph(String.t()) :: {:ok, map()} | term()

  @doc "Progress snapshot for a session id and working directory."
  @callback progress_snapshot(String.t() | nil, Path.t() | nil) :: map()

  @doc "Loads extensions: `{:ok, extensions, load_errors, validation_errors}`."
  @callback load_extensions([Path.t()]) :: {:ok, [module()], [term()], [term()]}

  @doc "Provider specs declared by loaded extensions."
  @callback extension_providers([module()]) :: [map()]

  @doc "Display info for loaded extensions."
  @callback extension_info([module()]) :: [map()]

  @doc "Tool-name conflict report for a working directory."
  @callback tool_conflicts(Path.t(), keyword()) :: map()

  @doc "Default extension directories: global first, then project-local."
  @callback extension_dirs(Path.t()) :: [Path.t()]

  @doc "Whether the WASM sidecar supervisor is running."
  @callback wasm_sidecar_running?() :: boolean()

  @optional_callbacks list_tasks: 0,
                      get_task: 1,
                      todo_progress: 1,
                      feature_progress: 1,
                      compact_session: 2,
                      background_start: 2,
                      background_list: 1,
                      background_status: 1,
                      background_result: 1,
                      background_cancel: 1,
                      side_query: 3,
                      run_graph: 1,
                      progress_snapshot: 2,
                      load_extensions: 1,
                      extension_providers: 1,
                      extension_info: 1,
                      tool_conflicts: 2,
                      extension_dirs: 1,
                      wasm_sidecar_running?: 0
end
