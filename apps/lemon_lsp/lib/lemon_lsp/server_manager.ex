defmodule LemonLsp.ServerManager do
  @moduledoc """
  Public facade and redacted status projection for language-server sessions.

  Each pooled server/root/configuration owns an isolated supervised process and
  shared RPC client. Session processes own document state, request deadlines and
  native process-group cleanup; this facade never waits for protocol responses.
  """

  use GenServer

  @name __MODULE__

  @type server :: GenServer.server()
  @type request_result :: {:ok, map()} | {:error, atom()}
  @type document_result :: {:ok, map()} | {:error, atom()}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec status() :: map()
  def status, do: status(@name)

  @spec status(server()) :: map()
  def status(server) do
    GenServer.call(server, :status, 1_000)
  catch
    :exit, reason ->
      Map.merge(unavailable_status(), %{error: inspect(reason)})
  end

  @spec refresh() :: map()
  def refresh, do: refresh(@name)

  @spec refresh(server()) :: map()
  def refresh(server) do
    GenServer.call(server, :refresh, 1_000)
  catch
    :exit, reason ->
      Map.merge(unavailable_status(), %{error: inspect(reason)})
  end

  @doc """
  Acquire a shared language-server process for the server and workspace root.
  Configuration changes produce a different pool key.

  Options:

    * `:cwd` - workspace root the server process starts in
    * `:config_root` - project whose merged configuration to use (defaults to cwd)
    * `:session_id` - id for a newly started process (an existing process keeps its id)
    * `:owner` - monitored lease owner (defaults to the calling process)
  """
  @spec start_session(atom() | String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def start_session(server_id, opts \\ []) do
    GenServer.call(@name, {:start_session, server_id, opts}, 5_000)
  end

  @spec stop_session(String.t()) :: {:ok, map()} | {:error, :unknown_lsp_session}
  def stop_session(session_id) when is_binary(session_id) do
    call_session(session_id, {:stop_session, session_id}, 5_000)
  end

  @doc "Release one owner's lease; the last release starts the configured idle timer."
  def release_session(session_id, owner \\ self()) do
    call_session(session_id, {:release_session, session_id, owner}, 5_000)
  end

  @doc """
  Send a JSON-RPC request and wait for its response.

  Options:

    * `:timeout_ms` - response deadline, 50..300_000 (default 5_000)
    * `:on_timeout` - `:terminate` (default) treats the server as stuck and
      stops the session; `:cancel` sends `$/cancelRequest` and keeps it running
  """
  @spec request_session(String.t(), String.t(), map() | list() | nil, keyword()) ::
          request_result()
  def request_session(session_id, method, params \\ %{}, opts \\ [])
      when is_binary(session_id) and is_binary(method) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

    call_session(
      session_id,
      {:request_session, session_id, method, params, timeout_ms, request_opts(opts, false)},
      call_timeout(timeout_ms)
    )
  end

  @doc """
  Send a request while accepting server-initiated `workspace/applyEdit` requests.

  Servers commonly implement code-action commands by sending the client a
  `workspace/applyEdit` request before answering `workspace/executeCommand`.
  `:apply_edit` is a required callback returning `{:ok, receipt}` or
  `{:error, reason}`. It runs in a caller-owned task, not the manager, and the
  server is acknowledged only after it completes. Receipts are returned in
  application order. Outside such a request the manager declines server edits.
  """
  @spec request_with_edits(String.t(), String.t(), map() | list() | nil, keyword()) ::
          {:ok, map(), [term()]} | {:error, atom()}
  def request_with_edits(session_id, method, params \\ %{}, opts \\ [])
      when is_binary(session_id) and is_binary(method) do
    case Keyword.get(opts, :apply_edit) do
      apply_edit when is_function(apply_edit, 1) ->
        timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)
        owner = self()

        task =
          Task.async(fn ->
            owner_ref = Process.monitor(owner)

            request =
              :gen_server.send_request(
                session_target(session_id),
                {:request_session, session_id, method, params, timeout_ms,
                 request_opts(opts, true)}
              )

            deadline = System.monotonic_time(:millisecond) + call_timeout(timeout_ms)
            await_edit_response(request, session_id, apply_edit, deadline, owner_ref)
          end)

        Task.await(task, call_timeout(timeout_ms) + 1_000)

      _ ->
        {:error, :missing_edit_handler}
    end
  end

  defp await_edit_response(request, session_id, apply_edit, deadline, owner_ref) do
    receive do
      {__MODULE__, :apply_edit, token, edit} ->
        task = Task.async(fn -> apply_edit_result(apply_edit, edit) end)

        case await_edit_callback(task, request, deadline, owner_ref) do
          {:applied, result} ->
            _ = call_session(session_id, {:apply_edit_result, session_id, token, result})
            await_edit_response(request, session_id, apply_edit, deadline, owner_ref)

          {:finished, reply} ->
            reply
        end

      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        exit(:caller_exited)

      message ->
        case :gen_server.check_response(message, request) do
          {:reply, reply} -> reply
          {:error, reason} -> exit(reason)
          :no_reply -> await_edit_response(request, session_id, apply_edit, deadline, owner_ref)
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :request_timeout}
    end
  end

  defp apply_edit_result(apply_edit, edit) do
    case apply_edit.(edit) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      _ -> {:error, "Workspace edit failed"}
    end
  catch
    _, _ -> {:error, "Workspace edit failed"}
  end

  defp await_edit_callback(%Task{ref: ref} = task, request, deadline, owner_ref) do
    receive do
      {^ref, result} ->
        _ = Task.ignore(task)
        {:applied, result}

      {:DOWN, ^ref, :process, _pid, _reason} ->
        {:applied, {:error, "Workspace edit failed"}}

      {:DOWN, ^owner_ref, :process, _pid, _reason} ->
        _ = Task.shutdown(task, :brutal_kill)
        exit(:caller_exited)

      message
      when not (is_tuple(message) and tuple_size(message) == 4 and
                  elem(message, 0) == __MODULE__ and elem(message, 1) == :apply_edit) ->
        case :gen_server.check_response(message, request) do
          {:reply, reply} ->
            _ = Task.shutdown(task, :brutal_kill)
            {:finished, reply}

          {:error, reason} ->
            _ = Task.shutdown(task, :brutal_kill)
            exit(reason)

          :no_reply ->
            await_edit_callback(task, request, deadline, owner_ref)
        end
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        _ = Task.shutdown(task, :brutal_kill)
        {:finished, {:error, :request_timeout}}
    end
  end

  @doc """
  Return the latest raw diagnostics the server reported for `uri`.

  `seq` increases with every diagnostics batch the session receives, so a
  caller can capture it before syncing a document and wait for a newer entry.
  Raw diagnostics stay in-process; status projections keep only counts.
  """
  @spec document_diagnostics(String.t(), String.t()) ::
          {:ok, %{seq: non_neg_integer(), entry: map() | nil}} | {:error, atom()}
  def document_diagnostics(session_id, uri) when is_binary(session_id) and is_binary(uri) do
    call_session(session_id, {:document_diagnostics, session_id, uri}, 5_000)
  end

  @doc "Return a bounded snapshot of published diagnostics, including unopened files."
  def workspace_diagnostics(session_id) when is_binary(session_id) do
    call_session(session_id, {:workspace_diagnostics, session_id}, 5_000)
  end

  @spec initialize_session(String.t(), map() | list() | nil, keyword()) :: request_result()
  def initialize_session(session_id, params \\ %{}, opts \\ []) when is_binary(session_id) do
    with {:ok, response} <- request_session(session_id, "initialize", params, opts),
         :ok <- notify_session(session_id, "initialized", %{}) do
      {:ok, response}
    end
  end

  @doc "Synchronize current on-disk text and return its centrally assigned version."
  def sync_file(session_id, path, language_id) do
    call_session(session_id, {:sync_file, session_id, path, language_id}, 5_000)
  end

  @spec notify_session(String.t(), String.t(), map() | list() | nil) :: :ok | {:error, atom()}
  def notify_session(session_id, method, params \\ %{})
      when is_binary(session_id) and is_binary(method) do
    call_session(session_id, {:notify_session, session_id, method, params}, 5_000)
  end

  @spec open_document(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          document_result()
  def open_document(session_id, uri, language_id, text, opts \\ [])
      when is_binary(session_id) do
    call_session(
      session_id,
      {:open_document, session_id, uri, language_id, text, Keyword.get(opts, :version, 1)},
      5_000
    )
  end

  @spec change_document(String.t(), String.t(), String.t(), keyword()) :: document_result()
  def change_document(session_id, uri, text, opts \\ []) when is_binary(session_id) do
    call_session(
      session_id,
      {:change_document, session_id, uri, text, Keyword.get(opts, :version, 1)},
      5_000
    )
  end

  @spec close_document(String.t(), String.t()) :: document_result()
  def close_document(session_id, uri) when is_binary(session_id) do
    call_session(session_id, {:close_document, session_id, uri}, 5_000)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       sessions: %{},
       refs: %{},
       recent: [],
       started_at: DateTime.to_iso8601(DateTime.utc_now()),
       refresh_count: 1
     }}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, projection(state), state}

  def handle_call(:refresh, _from, state) do
    state = %{state | refresh_count: state.refresh_count + 1}
    {:reply, projection(state), state}
  end

  def handle_call({:start_session, server_id, opts}, {caller, _} = from, state) do
    root = Keyword.get(opts, :config_root, opts[:cwd])

    result =
      with {:ok, cwd} <- validate_cwd(Keyword.get(opts, :cwd)),
           {:ok, command} <- LemonLsp.Servers.resolve_command(server_id, root) do
        key = {command.server.id, cwd, command.server.config_hash}
        acquire_session(server_id, opts, key, caller, from, state)
      end

    case result do
      {:error, reason} -> {:reply, {:error, reason}, state}
      reply -> reply
    end
  end

  def handle_call(message, from, state) when is_tuple(message) do
    id = elem(message, 1)

    case Registry.lookup(LemonLsp.SessionRegistry, {:id, self(), id}) do
      [{pid, _}] ->
        forward(pid, message, from)
        {:noreply, state}

      [] ->
        {:reply, {:error, :unknown_lsp_session}, state}
    end
  end

  @impl true
  def handle_info({:session_status, pid, status}, state) do
    {:noreply, %{state | sessions: Map.put(state.sessions, pid, status)}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {status, sessions} = Map.pop(state.sessions, pid)

    recent =
      if status, do: Enum.take(status.recent_sessions ++ state.recent, 5), else: state.recent

    {:noreply, %{state | sessions: sessions, refs: Map.delete(state.refs, ref), recent: recent}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.refs, fn {_ref, pid} ->
      DynamicSupervisor.terminate_child(LemonLsp.SessionSupervisor, pid)
    end)

    :ok
  end

  defp acquire_session(server_id, opts, key, caller, from, state) do
    case Registry.lookup(LemonLsp.SessionRegistry, {:pool, self(), key}) do
      [{pid, _}] ->
        forward(
          pid,
          {:start_session, server_id, Keyword.put(opts, :owner, opts[:owner] || caller)},
          from
        )

        {:noreply, state}

      [] ->
        start_session_child(server_id, opts, key, caller, from, state)
    end
  end

  defp start_session_child(server_id, opts, key, caller, from, state) do
    id = opts[:session_id] || "#{server_id}:#{System.unique_integer([:positive])}"

    case Registry.lookup(LemonLsp.SessionRegistry, {:id, self(), id}) do
      [] ->
        opts =
          Keyword.merge(opts,
            manager: self(),
            pool_key: key,
            session_id: id,
            server_id: server_id,
            owner: opts[:owner] || caller
          )

        launch_session_child(opts, from, state)

      _ ->
        {:reply, {:error, :duplicate_lsp_session}, state}
    end
  end

  defp launch_session_child(opts, from, state) do
    case DynamicSupervisor.start_child(LemonLsp.SessionSupervisor, {LemonLsp.Session, opts}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        forward(pid, :acquired_info, from)
        {:noreply, %{state | refs: Map.put(state.refs, ref, pid)}}

      {:error, _} ->
        {:reply, {:error, :session_start_failed}, state}
    end
  end

  defp validate_cwd(nil), do: validate_cwd(File.cwd!())

  defp validate_cwd(cwd) when is_binary(cwd) do
    expanded = Path.expand(cwd)
    if File.dir?(expanded), do: {:ok, expanded}, else: {:error, :invalid_cwd}
  end

  defp validate_cwd(_cwd), do: {:error, :invalid_cwd}

  defp session_target(session_id) do
    manager = Process.whereis(@name)

    case Registry.lookup(LemonLsp.SessionRegistry, {:id, manager, session_id}) do
      [{pid, _}] -> pid
      [] -> @name
    end
  end

  defp call_session(session_id, message, timeout \\ 5_000) do
    GenServer.call(session_target(session_id), message, timeout)
  catch
    :exit, {:normal, _call} -> {:error, :unknown_lsp_session}
    :exit, {:noproc, _call} -> {:error, :unknown_lsp_session}
    :exit, {:shutdown, _call} -> {:error, :session_exited}
    :exit, {:killed, _call} -> {:error, :session_exited}
  end

  defp forward(pid, message, from), do: send(pid, {:forward, message, from})

  defp projection(state) do
    statuses = Map.values(state.sessions)
    active = Enum.flat_map(statuses, & &1.active_servers)

    base =
      Map.merge(unavailable_status(), %{
        capabilities: [
          :server_registry,
          :stdio_session_supervision,
          :json_rpc_framing,
          :json_rpc_request_response,
          :json_rpc_initialize,
          :document_sync_notifications,
          :redacted_diagnostic_notifications,
          :redacted_diagnostic_pull_responses,
          :stderr_containment,
          :launcher_child_cleanup,
          :server_request_responses,
          :owner_scoped_sessions,
          :redacted_health_status
        ],
        planned_capabilities: [
          :json_rpc_diagnostics,
          :workspace_root_detection,
          :restart_policy,
          :semantic_diagnostic_streaming
        ]
      })

    Map.merge(base, %{
      supervised: true,
      running: true,
      mode: :registry_and_sessions,
      started_at: state.started_at,
      refreshed_at: DateTime.to_iso8601(DateTime.utc_now()),
      refresh_count: state.refresh_count,
      active_servers: Enum.sort_by(active, & &1.session_hash),
      active_count: length(active),
      pending_request_count: Enum.sum(Enum.map(active, & &1.pending_request_count)),
      recent_sessions: Enum.take(Enum.flat_map(statuses, & &1.recent_sessions) ++ state.recent, 5)
    })
  end

  defp request_opts(opts, capture_edits?) do
    %{on_timeout: Keyword.get(opts, :on_timeout, :terminate), capture_edits: capture_edits?}
  end

  defp call_timeout(timeout_ms) when is_integer(timeout_ms), do: max(timeout_ms, 0) + 1_000
  defp call_timeout(_timeout_ms), do: 6_000

  defp unavailable_status do
    %{
      supervised: false,
      running: false,
      mode: :unavailable,
      started_at: nil,
      refreshed_at: nil,
      refresh_count: 0,
      registry: LemonLsp.Servers.diagnostics(),
      active_servers: [],
      active_count: 0,
      pending_request_count: 0,
      recent_sessions: [],
      planned_capabilities: [],
      capabilities: [],
      cleanup: %{
        includes_executable_paths: false,
        includes_workspace_roots: false,
        includes_file_contents: false,
        includes_diagnostics_output: false,
        includes_server_io: false,
        includes_raw_session_ids: false
      }
    }
  end
end
