defmodule LemonLsp.ServerManager do
  @moduledoc """
  Public facade and redacted status projection for language-server sessions.

  Each pooled server/root/configuration owns an isolated supervised process and
  shared RPC client. Session processes own document state, request deadlines and
  native process-group cleanup; this facade never waits for protocol responses.

  At most eight sessions are live at once (`max_active_count` in `status/0`).
  Acquiring a new pool beyond that asks
  the least-recently-used session with no in-flight request to stop (its owners
  receive `{LemonLsp.ServerManager, :server_stopped, session_id}` and reconnect
  on next use); when every live session is busy, or no slot frees within the
  admission deadline (4 s, inside `start_session/2`'s 5 s call), the acquire
  fails with `{:error, :lsp_session_limit}`.
  """

  use GenServer

  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, _} -> {:state, :redacted}
      {:message, _} -> {:message, :redacted}
      {:reason, _} -> {:reason, :redacted}
      {:log, _} -> {:log, []}
      pair -> pair
    end)
  end

  @name __MODULE__

  # Live language servers per manager. One server process per workspace root
  # costs from 55 MiB peak RSS (clangd after opening a one-file C project) to
  # ~350 MiB for BEAM-hosted servers: a BEAM with every module of this umbrella
  # and its deps loaded peaks at 353 MiB RSS, a floor for ElixirLS, which also
  # compiles the project in its VM (measured 2026-11-24 on darwin/arm64, see
  # docs/tools/lsp.md). Eight covers one root per language of a polyglot
  # session; outermost-root detection keeps a monorepo at one root.
  @max_live_sessions 8
  # A session answers eviction from its own loop; one that cannot within this
  # window (suspended or stuck) is skipped for the next candidate. The probe
  # carries its expiry, so a late-read probe never evicts.
  @eviction_timeout_ms 1_000
  # The manager waits this long past a probe's expiry for an answer sent before it.
  @eviction_reply_margin_ms 100
  # Admission never outlives `start_session/2`'s 5 s call: a request still
  # unplaced at its deadline fails instead of starting or joining a session for
  # a caller that may have given up (an orphan lease).
  @admission_timeout_ms 4_000

  @type server :: GenServer.server()
  @typedoc """
  Session call failure. `{:session_crashed, class}` reports a session that
  exited abnormally or did not answer in time; the call's outcome is unknown and
  callers must not retry it automatically.
  """
  @type error_reason :: atom() | {:session_crashed, :timeout | :abnormal_exit}
  @type request_result :: {:ok, map()} | {:error, error_reason()}
  @type document_result :: {:ok, map()} | {:error, error_reason()}

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

  @spec stop_session(String.t()) :: {:ok, map()} | {:error, error_reason()}
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
  Subscribe to `diagnostics_topic/1` before reading to receive
  `{:lsp_diagnostics, session_id, uri}` whenever a batch is published.
  """
  @spec document_diagnostics(String.t(), String.t()) ::
          {:ok, %{seq: non_neg_integer(), entry: map() | nil}} | {:error, error_reason()}
  def document_diagnostics(session_id, uri) when is_binary(session_id) and is_binary(uri) do
    call_session(session_id, {:document_diagnostics, session_id, uri}, 5_000)
  end

  @doc "Bus topic for diagnostics and server-stop notifications for a session."
  def diagnostics_topic(session_id) when is_binary(session_id),
    do: "lsp_diagnostics:#{session_id}"

  @doc "Monitor the process owning a session before reading its diagnostics."
  def monitor_session(session_id) when is_binary(session_id),
    do: Process.monitor(session_target(session_id))

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

  @spec notify_session(String.t(), String.t(), map() | list() | nil) ::
          :ok | {:error, error_reason()}
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
       last_used: %{},
       refs: %{},
       recent: [],
       evictions: %{},
       evicting: MapSet.new(),
       parked: %{},
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

    with {:ok, cwd} <- validate_cwd(Keyword.get(opts, :cwd)),
         {:ok, command} <- LemonLsp.Servers.resolve_command(server_id, root) do
      key = {command.server.id, cwd, command.server.config_hash}
      opts = Keyword.put(opts, :owner, opts[:owner] || caller)

      request = %{
        id: make_ref(),
        server_id: server_id,
        opts: opts,
        key: key,
        from: from,
        tried: MapSet.new(),
        deadline: System.monotonic_time(:millisecond) + @admission_timeout_ms
      }

      {:noreply, admit(request, state)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
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
  def handle_info({:session_status, pid, status, last_used}, state) do
    {:noreply,
     %{
       state
       | sessions: Map.put(state.sessions, pid, status),
         last_used: Map.put(state.last_used, pid, last_used)
     }}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    {status, sessions} = Map.pop(state.sessions, pid)

    recent =
      if status, do: Enum.take(status.recent_sessions ++ state.recent, 5), else: state.recent

    {parked, waiting} = Map.pop(state.parked, pid, [])

    {targeted, evictions} =
      Enum.split_with(state.evictions, fn {_ref, request} -> request.pid == pid end)

    state = %{
      state
      | sessions: sessions,
        last_used: Map.delete(state.last_used, pid),
        refs: Map.delete(state.refs, ref),
        recent: recent,
        evicting: MapSet.delete(state.evicting, pid),
        evictions: Map.new(evictions),
        parked: waiting
    }

    # The slot this session held is free: admit whoever waited on it.
    requests =
      Enum.reverse(parked) ++
        Enum.map(targeted, fn {_ref, request} ->
          Process.cancel_timer(request.timer)
          request
        end)

    {:noreply, Enum.reduce(requests, state, &admit/2)}
  end

  def handle_info({:eviction_timeout, ref}, state) do
    case Map.pop(state.evictions, ref) do
      {nil, _evictions} ->
        {:noreply, state}

      {request, evictions} ->
        request = %{request | tried: MapSet.put(request.tried, request.pid)}
        {:noreply, admit(request, %{state | evictions: evictions})}
    end
  end

  # A request parked behind an evicting session fails at its deadline if that
  # session has not exited by then.
  def handle_info({:admission_timeout, pid, id}, state) do
    {timed_out, waiting} =
      Enum.split_with(Map.get(state.parked, pid, []), &(&1.id == id))

    Enum.each(timed_out, &GenServer.reply(&1.from, {:error, :lsp_session_limit}))

    parked =
      if waiting == [], do: Map.delete(state.parked, pid), else: %{state.parked | pid => waiting}

    {:noreply, %{state | parked: parked}}
  end

  def handle_info({ref, reply}, state) when is_reference(ref) do
    case Map.pop(state.evictions, ref) do
      {nil, _evictions} ->
        {:noreply, state}

      {request, evictions} ->
        Process.cancel_timer(request.timer)
        state = %{state | evictions: evictions}

        case reply do
          :ok ->
            {:noreply,
             admit(request, %{state | evicting: MapSet.put(state.evicting, request.pid)})}

          _busy ->
            request = %{request | tried: MapSet.put(request.tried, request.pid)}
            {:noreply, admit(request, state)}
        end
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.refs, fn {_ref, pid} ->
      DynamicSupervisor.terminate_child(LemonLsp.SessionSupervisor, pid)
    end)

    :ok
  end

  # Joins the pooled session for the key, else starts one when a live slot is
  # free, else asks the least-recently-used session without in-flight requests to
  # stop. A request for a pool whose session is being evicted waits for its exit.
  # Past its deadline a request is refused rather than placed.
  defp admit(request, state) do
    if System.monotonic_time(:millisecond) >= request.deadline do
      GenServer.reply(request.from, {:error, :lsp_session_limit})
      state
    else
      place(request, state)
    end
  end

  defp place(request, state) do
    case Registry.lookup(LemonLsp.SessionRegistry, {:pool, self(), request.key}) do
      [{pid, _}] ->
        if MapSet.member?(state.evicting, pid) do
          Process.send_after(self(), {:admission_timeout, pid, request.id}, request.deadline,
            abs: true
          )

          update_in(state.parked[pid], &[request | &1 || []])
        else
          forward(pid, {:start_session, request.server_id, request.opts}, request.from)
          state
        end

      [] ->
        if live_count(state) < @max_live_sessions,
          do: start_session_child(request, state),
          else: evict_for(request, state)
    end
  end

  defp live_count(state), do: map_size(state.refs) - MapSet.size(state.evicting)

  defp evict_for(request, state) do
    targeted = MapSet.new(state.evictions, fn {_ref, eviction} -> eviction.pid end)

    candidate =
      state.sessions
      |> Enum.reject(fn {pid, status} ->
        MapSet.member?(state.evicting, pid) or MapSet.member?(targeted, pid) or
          MapSet.member?(request.tried, pid) or status.pending_request_count > 0
      end)
      |> Enum.min_by(fn {pid, _status} -> Map.get(state.last_used, pid, 0) end, fn -> nil end)

    case candidate do
      nil ->
        GenServer.reply(request.from, {:error, :lsp_session_limit})
        state

      {pid, _status} ->
        # The session decides atomically: it stops only while nothing is in
        # flight and before `expires_at`, and answers an error otherwise.
        ref = make_ref()

        expires_at =
          min(System.monotonic_time(:millisecond) + @eviction_timeout_ms, request.deadline)

        forward(pid, {:evict_if_idle, expires_at}, {self(), ref})

        timer =
          Process.send_after(
            self(),
            {:eviction_timeout, ref},
            expires_at + @eviction_reply_margin_ms,
            abs: true
          )

        eviction = Map.merge(request, %{pid: pid, timer: timer})
        %{state | evictions: Map.put(state.evictions, ref, eviction)}
    end
  end

  defp start_session_child(request, state) do
    id = request.opts[:session_id] || "#{request.server_id}:#{System.unique_integer([:positive])}"

    case Registry.lookup(LemonLsp.SessionRegistry, {:id, self(), id}) do
      [] ->
        opts =
          Keyword.merge(request.opts,
            manager: self(),
            pool_key: request.key,
            session_id: id,
            server_id: request.server_id
          )

        launch_session_child(opts, request.from, state)

      _ ->
        GenServer.reply(request.from, {:error, :duplicate_lsp_session})
        state
    end
  end

  defp launch_session_child(opts, from, state) do
    case DynamicSupervisor.start_child(LemonLsp.SessionSupervisor, {LemonLsp.Session, opts}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        forward(pid, :acquired_info, from)
        %{state | refs: Map.put(state.refs, ref, pid)}

      {:error, _} ->
        GenServer.reply(from, {:error, :session_start_failed})
        state
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

  # Every exit becomes an error reply: a session failure must not take its
  # callers down. Crash reasons can embed protocol payloads, so only their
  # class is reported.
  defp call_session(session_id, message, timeout \\ 5_000) do
    GenServer.call(session_target(session_id), message, timeout)
  catch
    :exit, {reason, _call} when reason in [:normal, :noproc] -> {:error, :unknown_lsp_session}
    :exit, {reason, _call} when reason in [:shutdown, :killed] -> {:error, :session_exited}
    :exit, {{:shutdown, _}, _call} -> {:error, :session_exited}
    :exit, {:timeout, _call} -> {:error, {:session_crashed, :timeout}}
    :exit, _reason -> {:error, {:session_crashed, :abnormal_exit}}
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
          :redacted_health_status,
          :workspace_root_detection,
          :live_session_cap
        ],
        planned_capabilities: [
          :json_rpc_diagnostics,
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
      max_active_count: @max_live_sessions,
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
      max_active_count: @max_live_sessions,
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
