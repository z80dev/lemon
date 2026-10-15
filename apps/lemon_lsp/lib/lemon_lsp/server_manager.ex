defmodule LemonLsp.ServerManager do
  @moduledoc """
  Supervised status manager for Lemon language-server capability metadata.
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
    GenServer.call(@name, {:stop_session, session_id}, 5_000)
  end

  @doc "Release one owner's lease; the last release starts the configured idle timer."
  def release_session(session_id, owner \\ self()) do
    GenServer.call(@name, {:release_session, session_id, owner}, 5_000)
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

    GenServer.call(
      @name,
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
                @name,
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
            _ = GenServer.call(@name, {:apply_edit_result, session_id, token, result})
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
    GenServer.call(@name, {:document_diagnostics, session_id, uri}, 5_000)
  end

  @doc "Return a bounded snapshot of published diagnostics, including unopened files."
  def workspace_diagnostics(session_id) when is_binary(session_id) do
    GenServer.call(@name, {:workspace_diagnostics, session_id}, 5_000)
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
    GenServer.call(@name, {:sync_file, session_id, path, language_id}, 5_000)
  end

  @spec notify_session(String.t(), String.t(), map() | list() | nil) :: :ok | {:error, atom()}
  def notify_session(session_id, method, params \\ %{})
      when is_binary(session_id) and is_binary(method) do
    GenServer.call(@name, {:notify_session, session_id, method, params}, 5_000)
  end

  @spec open_document(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          document_result()
  def open_document(session_id, uri, language_id, text, opts \\ [])
      when is_binary(session_id) do
    GenServer.call(
      @name,
      {:open_document, session_id, uri, language_id, text, Keyword.get(opts, :version, 1)},
      5_000
    )
  end

  @spec change_document(String.t(), String.t(), String.t(), keyword()) :: document_result()
  def change_document(session_id, uri, text, opts \\ []) when is_binary(session_id) do
    GenServer.call(
      @name,
      {:change_document, session_id, uri, text, Keyword.get(opts, :version, 1)},
      5_000
    )
  end

  @spec close_document(String.t(), String.t()) :: document_result()
  def close_document(session_id, uri) when is_binary(session_id) do
    GenServer.call(@name, {:close_document, session_id, uri}, 5_000)
  end

  @impl true
  def init(_opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     refresh_state(%{
       started_at: now_iso8601(),
       refresh_count: 0,
       next_request_id: 0,
       sessions: %{},
       recent_sessions: []
     })}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_from_state(state), state}
  end

  def handle_call(:refresh, _from, state) do
    state = refresh_state(state)
    {:reply, status_from_state(state), state}
  end

  def handle_call({:start_session, server_id, opts}, {caller, _}, state) do
    config_root = Keyword.get(opts, :config_root, opts[:cwd])

    with {:ok, command} <- LemonLsp.Servers.resolve_command(server_id, config_root),
         {:ok, cwd} <- validate_cwd(Keyword.get(opts, :cwd)) do
      key = {command.server.id, cwd, command.server.config_hash}
      owner = Keyword.get(opts, :owner) || caller

      case Enum.find(state.sessions, fn {_id, session} -> session.pool_key == key end) do
        {id, session} ->
          session = acquire_owner(session, owner)

          {:reply, {:ok, session_info(session, include_session_id: true)},
           put_in(state.sessions[id], session)}

        nil ->
          id = session_id(server_id, opts)

          if Map.has_key?(state.sessions, id) do
            {:reply, {:error, :duplicate_lsp_session}, state}
          else
            {:ok, session} = start_port(command, cwd)
            lsp = get_in(LemonCore.Config.load(config_root).agent, [:tools, :lsp])

            session =
              session
              |> Map.merge(%{
                session_id: id,
                pool_key: key,
                owners: %{},
                idle_timer: nil,
                idle_timeout_ms: Map.get(lsp, "idle_timeout_ms", 30_000),
                initialization_response: nil
              })
              |> acquire_owner(owner)

            {:reply, {:ok, session_info(session, include_session_id: true)},
             put_in(state.sessions[id], session)}
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release_session, session_id, owner}, _from, state) do
    case fetch_session(state, session_id) do
      {:ok, session} ->
        {:reply, :ok, release_owner(state, session, owner, false)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:stop_session, session_id}, _from, state) do
    case Map.pop(state.sessions, session_id) do
      {nil, _sessions} ->
        {:reply, {:error, :unknown_lsp_session}, state}

      {session, sessions} ->
        info = stopped_session_info(session, :stopped)

        state =
          state
          |> Map.put(:sessions, sessions)
          |> remember_session(Map.delete(info, :session_id))

        {:reply, {:ok, info}, state}
    end
  end

  def handle_call(
        {:request_session, session_id, method, params, timeout_ms, request_opts},
        from,
        state
      ) do
    with {:ok, session} <- fetch_session(state, session_id),
         :ok <- edit_capture_available(session, request_opts),
         :ok <- validate_method(method),
         {:ok, params} <- validate_params(params),
         {:ok, timeout_ms} <- validate_timeout(timeout_ms) do
      case initialize_request(session, method, from) do
        {:cached, response} ->
          {:reply, {:ok, response}, state}

        {:waiting, session} ->
          {:noreply, put_in(state.sessions[session_id], session)}

        :new ->
          params =
            if method == "initialize" and is_map(params),
              do: Map.put(params, "initializationOptions", session.initialization_options),
              else: params

          request_id = state.next_request_id + 1

          payload = %{
            "jsonrpc" => "2.0",
            "id" => request_id,
            "method" => method,
            "params" => params
          }

          timer =
            Process.send_after(self(), {:lsp_request_timeout, session_id, request_id}, timeout_ms)

          true = Port.command(session.port, frame_message(payload))

          pending =
            Map.put(session.pending, request_id, %{
              from: from,
              timer: timer,
              method: method,
              params: params,
              on_timeout: request_opts.on_timeout,
              capture_edits: request_opts.capture_edits,
              caller_ref: Process.monitor(elem(from, 0)),
              waiters: [],
              edits: [],
              started_at: now_iso8601()
            })

          session =
            session
            |> Map.put(:pending, pending)
            |> Map.update(:request_count, 1, &(&1 + 1))

          state =
            state
            |> put_in([:sessions, session_id], session)
            |> Map.put(:next_request_id, request_id)

          {:noreply, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:apply_edit_result, session_id, token, result}, {caller, _}, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         {pending_id, server_id} <- Map.get(Map.get(session, :applying_edits, %{}), token),
         %{from: {^caller, _}} = pending <- Map.get(session.pending, pending_id) do
      response =
        case result do
          {:ok, _} -> %{"applied" => true}
          {:error, reason} -> %{"applied" => false, "failureReason" => reason}
        end

      pending = Map.update!(pending, :edits, &[result | &1])

      session =
        session
        |> put_in([:pending, pending_id], pending)
        |> Map.update!(:applying_edits, &Map.delete(&1, token))
        |> send_lsp_response(server_id, response)
        |> finish_deferred_request(pending_id)

      {:reply, :ok, put_in(state.sessions[session_id], session)}
    else
      _ -> {:reply, {:error, :request_expired}, state}
    end
  end

  def handle_call({:notify_session, session_id, method, params}, _from, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         :ok <- validate_method(method),
         {:ok, params} <- validate_params(params) do
      session =
        if method == "initialized" and session.initialized do
          session
        else
          session
          |> send_lsp_notification(method, params)
          |> maybe_mark_initialized(method)
        end

      {:reply, :ok, put_in(state, [:sessions, session_id], session)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:sync_file, session_id, path, language_id}, {owner, _}, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, text} <- File.read(path) do
      uri = "file://" <> URI.encode(Path.expand(path), &(URI.char_unreserved?(&1) or &1 == ?/))
      seq = session.diagnostic_seq
      {session, synced} = sync_document(session, owner, uri, language_id, text, 1)
      info = Map.merge(document_info(session, uri), %{synced: synced, diagnostics_seq: seq})
      {:reply, {:ok, info}, put_in(state.sessions[session_id], session)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:open_document, session_id, uri, language_id, text, version},
        {owner, _},
        state
      ) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, uri} <- validate_document_uri(uri),
         {:ok, language_id} <- validate_language_id(language_id),
         {:ok, text} <- validate_document_text(text),
         {:ok, version} <- validate_document_version(version) do
      {session, synced} = sync_document(session, owner, uri, language_id, text, version)

      {:reply, {:ok, Map.put(document_info(session, uri), :synced, synced)},
       put_in(state, [:sessions, session_id], session)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:change_document, session_id, uri, text, version}, {owner, _}, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, uri} <- validate_document_uri(uri),
         {:ok, text} <- validate_document_text(text),
         {:ok, version} <- validate_document_version(version) do
      language_id = get_in(session.documents, [hash_value(uri), :language_id]) || "plaintext"
      {session, synced} = sync_document(session, owner, uri, language_id, text, version)

      {:reply, {:ok, Map.put(document_info(session, uri), :synced, synced)},
       put_in(state, [:sessions, session_id], session)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close_document, session_id, uri}, {owner, _}, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, uri} <- validate_document_uri(uri) do
      session = close_owned_document(session, uri, owner)

      {:reply, {:ok, document_info(session, uri)},
       put_in(state, [:sessions, session_id], session)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:document_diagnostics, session_id, uri}, _from, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, uri} <- validate_document_uri(uri) do
      entry = get_in(session, [:diagnostics_by_uri, uri])
      {:reply, {:ok, %{seq: Map.get(session, :diagnostic_seq, 0), entry: entry}}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:workspace_diagnostics, session_id}, _from, state) do
    case fetch_session(state, session_id) do
      {:ok, session} ->
        entries =
          session
          |> Map.get(:diagnostics_by_uri, %{})
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.take(200)
          |> Enum.map(fn {uri, entry} -> {uri, Enum.take(entry.diagnostics, 100)} end)

        {:reply, {:ok, entries}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, data}}, state) when is_port(port) do
    case find_session_by_port(state.sessions, port) do
      nil ->
        {:noreply, state}

      {session_id, session} ->
        {messages, buffer} = parse_messages(session.buffer <> data)

        session =
          session
          |> Map.put(:buffer, buffer)
          |> handle_messages(messages)

        {:noreply, put_in(state, [:sessions, session_id], session)}
    end
  end

  def handle_info({port, {:exit_status, exit_status}}, state) when is_port(port) do
    case pop_session_by_port(state.sessions, port) do
      {nil, _sessions} ->
        {:noreply, state}

      {session, sessions} ->
        demonitor_owner(session)
        reply_pending(session, {:error, :session_exited})

        info =
          session
          |> Map.merge(%{status: :exited, exit_status: exit_status, stopped_at: now_iso8601()})
          |> session_info()

        state =
          state
          |> Map.put(:sessions, sessions)
          |> remember_session(info)

        {:noreply, state}
    end
  end

  def handle_info({:EXIT, port, _reason}, state) when is_port(port) do
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Enum.find(state.sessions, fn {_id, session} ->
           Enum.any?(session.owners, fn {_owner, lease} -> lease.ref == ref end)
         end) do
      nil ->
        sessions =
          Map.new(state.sessions, fn {session_id, session} ->
            session =
              Enum.reduce(Map.keys(session.pending), session, fn id, session ->
                drop_request_caller(session, id, ref)
              end)

            {session_id, session}
          end)

        {:noreply, %{state | sessions: sessions}}

      {_session_id, session} ->
        {owner, _lease} = Enum.find(session.owners, fn {_owner, lease} -> lease.ref == ref end)
        {:noreply, release_owner(state, session, owner, true)}
    end
  end

  def handle_info({:idle_shutdown, session_id, token}, state) do
    case Map.get(state.sessions, session_id) do
      %{owners: owners, idle_timer: {_timer, ^token}} = session when map_size(owners) == 0 ->
        info = stopped_session_info(session, :idle)

        state =
          state
          |> update_in([:sessions], &Map.delete(&1, session_id))
          |> remember_session(Map.delete(info, :session_id))

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:lsp_request_timeout, session_id, request_id}, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:noreply, state}

      session ->
        case Map.pop(session.pending, request_id) do
          {nil, _pending} ->
            {:noreply, state}

          {%{on_timeout: :cancel} = pending, remaining_pending} ->
            _ = Process.cancel_timer(pending.timer)
            Process.demonitor(pending.caller_ref, [:flush])
            reply_request(pending, {:error, :request_timeout})

            session =
              session
              |> Map.put(:pending, remaining_pending)
              |> send_lsp_notification("$/cancelRequest", %{"id" => request_id})
              |> expire_edits(request_id)

            {:noreply, put_in(state, [:sessions, session_id], session)}

          {pending, remaining_pending} ->
            _ = Process.cancel_timer(pending.timer)
            Process.demonitor(pending.caller_ref, [:flush])
            reply_request(pending, {:error, :request_timeout})
            demonitor_owner(session)

            session =
              session
              |> Map.put(:pending, remaining_pending)
              |> Map.merge(%{status: :request_timeout, stopped_at: now_iso8601()})

            terminate_port(session)
            reply_pending(session, {:error, :session_stopped})

            info =
              session
              |> Map.put(:pending, %{})
              |> session_info()

            state =
              state
              |> update_in([:sessions], &Map.delete(&1, session_id))
              |> remember_session(info)

            {:noreply, state}
        end
    end
  end

  defp initialize_request(session, "initialize", from) do
    cond do
      session.initialization_response ->
        {:cached, session.initialization_response}

      pending =
          Enum.find(session.pending, fn {_id, request} -> request.method == "initialize" end) ->
        {id, request} = pending
        waiter = %{from: from, caller_ref: Process.monitor(elem(from, 0))}
        {:waiting, put_in(session.pending[id], %{request | waiters: [waiter | request.waiters]})}

      true ->
        :new
    end
  end

  defp initialize_request(_session, _method, _from), do: :new

  defp refresh_state(state) do
    registry = LemonLsp.Servers.diagnostics()

    state
    |> Map.put(:registry, registry)
    |> Map.put(:refreshed_at, now_iso8601())
    |> Map.update(:refresh_count, 1, &(&1 + 1))
  end

  defp status_from_state(state) do
    %{
      supervised: true,
      running: true,
      mode: :registry_and_sessions,
      started_at: state.started_at,
      refreshed_at: state.refreshed_at,
      refresh_count: state.refresh_count,
      registry: state.registry,
      active_servers: active_sessions(state),
      active_count: map_size(state.sessions),
      pending_request_count: pending_request_count(state.sessions),
      recent_sessions: state.recent_sessions,
      planned_capabilities: [
        :json_rpc_diagnostics,
        :workspace_root_detection,
        :restart_policy,
        :semantic_diagnostic_streaming
      ],
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

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp start_port(command, cwd) do
    {executable, args} = launch_spec(command)

    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, {:args, args}]
      |> maybe_env(command.env)
      |> maybe_cd(cwd)

    port = Port.open({:spawn_executable, executable}, port_opts)
    os_pid = port_os_pid(port)

    {:ok,
     %{
       port: port,
       os_pid: os_pid,
       buffer: "",
       pending: %{},
       request_count: 0,
       response_count: 0,
       notification_count: 0,
       diagnostic_count: 0,
       diagnostic_batch_count: 0,
       last_diagnostics: [],
       documents: %{},
       diagnostics_by_uri: %{},
       diagnostic_seq: 0,
       root: cwd,
       initialization_options: command.initialization_options,
       initialized: false,
       server_id: command.server.id,
       label: command.server.label,
       language: command.server.language,
       command: command.command,
       args_count: length(command.args),
       cwd_hash: hash_value(cwd),
       started_at: now_iso8601(),
       status: :running,
       protocol: command.server.protocol
     }}
  end

  # Language servers log heavily to stderr. Sharing the stdout pipe lets those
  # writes land inside a JSON-RPC frame, so the launcher discards stderr and the
  # port carries protocol output only. `exec` keeps the server's own pid.
  defp launch_spec(command) do
    case System.find_executable("sh") do
      nil ->
        {command.executable, command.args}

      sh ->
        {sh, ["-c", ~S(exec "$0" "$@" 2>/dev/null), command.executable | command.args]}
    end
  end

  defp acquire_owner(session, owner) do
    _ = if session.idle_timer, do: Process.cancel_timer(elem(session.idle_timer, 0))

    lease =
      case Map.get(session.owners, owner) do
        nil -> %{ref: Process.monitor(owner), count: 1}
        lease -> %{lease | count: lease.count + 1}
      end

    %{session | owners: Map.put(session.owners, owner, lease), idle_timer: nil}
  end

  defp release_owner(state, session, owner, all?) do
    owners =
      case Map.get(session.owners, owner) do
        nil ->
          session.owners

        %{count: count} = lease when count > 1 and not all? ->
          Map.put(session.owners, owner, %{lease | count: count - 1})

        lease ->
          Process.demonitor(lease.ref, [:flush])
          Map.delete(session.owners, owner)
      end

    session = %{session | owners: owners}
    session = if Map.has_key?(owners, owner), do: session, else: release_documents(session, owner)

    cond do
      map_size(owners) == 0 and session.idle_timeout_ms == 0 ->
        info = stopped_session_info(session, :idle)

        state
        |> update_in([:sessions], &Map.delete(&1, session.session_id))
        |> remember_session(Map.delete(info, :session_id))

      map_size(owners) == 0 ->
        token = make_ref()

        timer =
          Process.send_after(
            self(),
            {:idle_shutdown, session.session_id, token},
            session.idle_timeout_ms
          )

        put_in(state.sessions[session.session_id], %{session | idle_timer: {timer, token}})

      true ->
        put_in(state.sessions[session.session_id], session)
    end
  end

  defp demonitor_owner(session) do
    Enum.each(session.owners, fn {_owner, lease} -> Process.demonitor(lease.ref, [:flush]) end)
    _ = if session.idle_timer, do: Process.cancel_timer(elem(session.idle_timer, 0))

    Enum.each(
      Map.keys(session.owners),
      &send(&1, {__MODULE__, :server_stopped, session.session_id})
    )
  end

  defp stopped_session_info(session, status) do
    demonitor_owner(session)
    terminate_port(session)
    reply_pending(session, {:error, :session_stopped})

    session
    |> Map.merge(%{status: status, stopped_at: now_iso8601()})
    |> session_info(include_session_id: true)
  end

  defp request_opts(opts, capture_edits?) do
    %{on_timeout: Keyword.get(opts, :on_timeout, :terminate), capture_edits: capture_edits?}
  end

  defp edit_capture_available(session, %{capture_edits: true}) do
    if capturing_request(session),
      do: {:error, :edit_request_in_progress},
      else: :ok
  end

  defp edit_capture_available(_session, _opts), do: :ok

  defp call_timeout(timeout_ms) when is_integer(timeout_ms), do: max(timeout_ms, 0) + 1_000
  defp call_timeout(_timeout_ms), do: 6_000

  defp validate_cwd(nil), do: validate_cwd(File.cwd!())

  defp validate_cwd(cwd) when is_binary(cwd) do
    expanded = Path.expand(cwd)

    if File.dir?(expanded) do
      {:ok, expanded}
    else
      {:error, :invalid_cwd}
    end
  end

  defp validate_cwd(_cwd), do: {:error, :invalid_cwd}

  defp maybe_cd(opts, cwd), do: [{:cd, cwd} | opts]

  defp maybe_env(opts, env) when env == %{}, do: opts

  defp maybe_env(opts, env) when is_map(env) do
    port_env =
      Enum.map(env, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)

    [{:env, port_env} | opts]
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  end

  defp terminate_port(session) do
    _ = terminate_descendants(Map.get(session, :os_pid))
    _ = terminate_os_pid(Map.get(session, :os_pid))

    try do
      Port.close(session.port)
    rescue
      ArgumentError -> :ok
    catch
      :exit, _reason -> :ok
    end

    _ = terminate_descendants(Map.get(session, :os_pid))
    _ = terminate_os_pid(Map.get(session, :os_pid))
  end

  defp terminate_descendants(os_pid) when is_integer(os_pid) and os_pid > 0 do
    os_pid
    |> descendant_pids()
    |> Enum.reverse()
    |> Enum.each(&terminate_os_pid/1)

    :ok
  end

  defp terminate_descendants(_os_pid), do: :ok

  defp descendant_pids(parent_pid) do
    case System.find_executable("pgrep") do
      nil ->
        []

      pgrep ->
        case System.cmd(pgrep, ["-P", to_string(parent_pid)], stderr_to_stdout: true) do
          {output, 0} ->
            child_pids = parse_pids(output)
            Enum.uniq(child_pids ++ Enum.flat_map(child_pids, &descendant_pids/1))

          {_output, _status} ->
            []
        end
    end
  end

  defp parse_pids(output) do
    output
    |> String.split()
    |> Enum.flat_map(fn value ->
      case Integer.parse(value) do
        {pid, ""} when pid > 0 -> [pid]
        _ -> []
      end
    end)
  end

  defp terminate_os_pid(pid) when is_integer(pid) and pid > 0 do
    terminate_os_target(to_string(pid))
  end

  defp terminate_os_pid(_pid), do: :ok

  defp terminate_os_target(target) do
    kill = System.find_executable("kill")

    _ =
      if kill do
        _ = System.cmd(kill, ["-TERM", target], stderr_to_stdout: true)
        Process.sleep(25)

        if os_process_alive?(kill, target) do
          _ = System.cmd(kill, ["-KILL", target], stderr_to_stdout: true)
        end
      end

    :ok
  end

  defp os_process_alive?(kill, target) do
    case System.cmd(kill, ["-0", target], stderr_to_stdout: true) do
      {_output, 0} -> true
      {_output, _status} -> false
    end
  end

  defp session_id(server_id, opts) do
    case Keyword.get(opts, :session_id) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        server =
          server_id
          |> to_string()
          |> String.replace(~r/[^a-zA-Z0-9_.:-]/, "_")

        "#{server}:#{System.unique_integer([:positive])}"
    end
  end

  defp active_sessions(state) do
    state.sessions
    |> Map.values()
    |> Enum.map(&session_info/1)
    |> Enum.sort_by(& &1.session_hash)
  end

  defp fetch_session(state, session_id) do
    case Map.get(state.sessions, session_id) do
      nil -> {:error, :unknown_lsp_session}
      session -> {:ok, session}
    end
  end

  defp validate_method(method) when is_binary(method) do
    if String.trim(method) == "", do: {:error, :invalid_method}, else: :ok
  end

  defp validate_method(_method), do: {:error, :invalid_method}

  defp validate_params(nil), do: {:ok, %{}}
  defp validate_params(params) when is_map(params) or is_list(params), do: {:ok, params}
  defp validate_params(_params), do: {:error, :invalid_params}

  defp validate_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms in 50..300_000,
    do: {:ok, timeout_ms}

  defp validate_timeout(_timeout_ms), do: {:error, :invalid_timeout}

  defp validate_document_uri(uri) when is_binary(uri) do
    if String.trim(uri) == "", do: {:error, :invalid_document_uri}, else: {:ok, uri}
  end

  defp validate_document_uri(_uri), do: {:error, :invalid_document_uri}

  defp validate_language_id(language_id) when is_binary(language_id) do
    if String.trim(language_id) == "",
      do: {:error, :invalid_language_id},
      else: {:ok, language_id}
  end

  defp validate_language_id(_language_id), do: {:error, :invalid_language_id}

  defp validate_document_text(text) when is_binary(text), do: {:ok, text}
  defp validate_document_text(_text), do: {:error, :invalid_document_text}

  defp validate_document_version(version) when is_integer(version) and version >= 0,
    do: {:ok, version}

  defp validate_document_version(_version), do: {:error, :invalid_document_version}

  defp send_lsp_notification(session, method, params) do
    payload = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
    true = Port.command(session.port, frame_message(payload))
    Map.update(session, :notification_count, 1, &(&1 + 1))
  end

  defp frame_message(payload) do
    body = Jason.encode!(payload)
    "Content-Length: #{byte_size(body)}\r\n\r\n#{body}"
  end

  defp parse_messages(buffer), do: parse_messages(buffer, [])

  defp parse_messages(buffer, acc) do
    buffer = discard_non_lsp_prefix(buffer)

    case :binary.match(buffer, "\r\n\r\n") do
      :nomatch ->
        {Enum.reverse(acc), buffer}

      {header_end, 4} ->
        header = binary_part(buffer, 0, header_end)
        rest_offset = header_end + 4
        rest_size = byte_size(buffer) - rest_offset
        rest = binary_part(buffer, rest_offset, rest_size)

        with {:ok, content_length} <- content_length(header),
             true <- byte_size(rest) >= content_length do
          body = binary_part(rest, 0, content_length)
          remaining = binary_part(rest, content_length, byte_size(rest) - content_length)
          parse_messages(remaining, [decode_message(body) | acc])
        else
          false -> {Enum.reverse(acc), buffer}
          {:error, _reason} -> {Enum.reverse(acc), ""}
        end
    end
  end

  defp discard_non_lsp_prefix(buffer) do
    case lsp_frame_start(buffer) do
      0 ->
        buffer

      index when is_integer(index) ->
        binary_part(buffer, index, byte_size(buffer) - index)

      nil ->
        binary_part(buffer, max(byte_size(buffer) - 128, 0), min(byte_size(buffer), 128))
    end
  end

  defp lsp_frame_start(buffer) do
    ["Content-Length:", "content-length:"]
    |> Enum.map(&:binary.match(buffer, &1))
    |> Enum.filter(&match?({_, _}, &1))
    |> Enum.map(fn {index, _length} -> index end)
    |> Enum.min(fn -> nil end)
  end

  defp content_length(header) do
    header
    |> String.split("\r\n")
    |> Enum.find_value(fn line ->
      case String.split(line, ":", parts: 2) do
        [key, value] ->
          if String.downcase(String.trim(key)) == "content-length" do
            value |> String.trim() |> Integer.parse()
          end

        _ ->
          nil
      end
    end)
    |> case do
      {length, ""} when length >= 0 -> {:ok, length}
      _ -> {:error, :missing_content_length}
    end
  end

  defp decode_message(body) do
    case Jason.decode(body) do
      {:ok, message} -> {:ok, message}
      {:error, _error} -> {:error, :invalid_json}
    end
  end

  defp handle_messages(session, messages) do
    Enum.reduce(messages, session, fn
      # Server-initiated requests carry both an id and a method. Their ids live
      # in the server's id space and may collide with pending client requests.
      {:ok, %{"id" => request_id, "method" => method} = message}, session ->
        handle_server_request(session, request_id, method, Map.get(message, "params"))

      {:ok, %{"id" => request_id} = message}, session ->
        complete_request(session, request_id, message)

      {:ok, %{"method" => "textDocument/publishDiagnostics"} = message}, session ->
        capture_diagnostics(session, Map.get(message, "params", %{}))

      _message, session ->
        session
    end)
  end

  # The manager is a headless client: it acknowledges progress and capability
  # registration, answers configuration with defaults, and accepts edits only
  # on behalf of a caller that asked for them via `request_with_edits/4`.
  defp handle_server_request(session, request_id, "workspace/applyEdit", params) do
    case capturing_request(session) do
      {pending_id, pending} when is_map(params) and is_map_key(params, "edit") ->
        token = make_ref()
        send(elem(pending.from, 0), {__MODULE__, :apply_edit, token, params["edit"]})

        Map.update(
          session,
          :applying_edits,
          %{token => {pending_id, request_id}},
          &Map.put(&1, token, {pending_id, request_id})
        )

      _ ->
        send_lsp_response(session, request_id, %{
          "applied" => false,
          "failureReason" => "client applies edits only while executing a requested command"
        })
    end
  end

  defp handle_server_request(session, request_id, "workspace/configuration", params) do
    items =
      case params do
        %{"items" => items} when is_list(items) -> items
        _ -> []
      end

    send_lsp_response(session, request_id, Enum.map(items, fn _item -> nil end))
  end

  defp handle_server_request(session, request_id, "workspace/workspaceFolders", _params) do
    folders =
      case session.root do
        root when is_binary(root) ->
          [%{"uri" => "file://" <> URI.encode(root), "name" => Path.basename(root)}]

        _ ->
          nil
      end

    send_lsp_response(session, request_id, folders)
  end

  defp handle_server_request(session, request_id, "window/showDocument", _params) do
    send_lsp_response(session, request_id, %{"success" => false})
  end

  defp handle_server_request(session, request_id, method, _params)
       when method in [
              "window/workDoneProgress/create",
              "client/registerCapability",
              "client/unregisterCapability",
              "window/showMessageRequest"
            ] do
    send_lsp_response(session, request_id, nil)
  end

  defp handle_server_request(session, request_id, "workspace/" <> rest, _params) do
    if String.ends_with?(rest, "/refresh") do
      send_lsp_response(session, request_id, nil)
    else
      send_lsp_error(session, request_id, -32_601, "Method not found")
    end
  end

  defp handle_server_request(session, request_id, _method, _params) do
    send_lsp_error(session, request_id, -32_601, "Method not found")
  end

  defp capturing_request(session) do
    session.pending
    |> Enum.filter(fn {_id, pending} -> Map.get(pending, :capture_edits, false) end)
    |> Enum.max_by(fn {id, _pending} -> id end, fn -> nil end)
  end

  defp send_lsp_response(session, request_id, result) do
    payload = %{"jsonrpc" => "2.0", "id" => request_id, "result" => result}
    true = Port.command(session.port, frame_message(payload))
    session
  end

  defp send_lsp_error(session, request_id, code, message) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "error" => %{"code" => code, "message" => message}
    }

    true = Port.command(session.port, frame_message(payload))
    session
  end

  @max_diagnostic_documents 256

  defp capture_diagnostics(session, params) when is_map(params) do
    summary = diagnostic_summary(params)

    session
    |> Map.update(:diagnostic_count, summary.diagnostic_count, &(&1 + summary.diagnostic_count))
    |> Map.update(:diagnostic_batch_count, 1, &(&1 + 1))
    |> Map.put(:last_diagnostic_at, summary.received_at)
    |> Map.update(:last_diagnostics, [summary], fn summaries ->
      [summary | summaries] |> Enum.take(5)
    end)
    |> store_raw_diagnostics(params)
  end

  defp capture_diagnostics(session, _params), do: session

  # Raw diagnostics stay inside the manager for `document_diagnostics/2`;
  # status projections only ever see the redacted summaries above.
  defp store_raw_diagnostics(session, %{"uri" => uri} = params) when is_binary(uri) do
    seq = Map.get(session, :diagnostic_seq, 0) + 1

    diagnostics =
      case Map.get(params, "diagnostics") do
        list when is_list(list) -> Enum.filter(list, &is_map/1)
        _ -> []
      end

    entry = %{
      diagnostics: diagnostics,
      version: numeric_value(Map.get(params, "version")),
      seq: seq
    }

    Enum.each(Map.keys(session.owners), fn owner ->
      send(owner, {__MODULE__, :diagnostics, session.session_id, uri, entry})
    end)

    by_uri =
      session
      |> Map.get(:diagnostics_by_uri, %{})
      |> Map.put(uri, entry)
      |> bound_diagnostic_documents()

    session
    |> Map.put(:diagnostic_seq, seq)
    |> Map.put(:diagnostics_by_uri, by_uri)
  end

  defp store_raw_diagnostics(session, _params), do: session

  defp bound_diagnostic_documents(by_uri) when map_size(by_uri) > @max_diagnostic_documents do
    {oldest_uri, _entry} = Enum.min_by(by_uri, fn {_uri, entry} -> entry.seq end)
    Map.delete(by_uri, oldest_uri)
  end

  defp bound_diagnostic_documents(by_uri), do: by_uri

  defp diagnostic_summary(params) do
    diagnostics = Map.get(params, "diagnostics", [])
    diagnostics = if is_list(diagnostics), do: diagnostics, else: []

    %{
      uri_hash: hash_value(Map.get(params, "uri")),
      version: numeric_value(Map.get(params, "version")),
      diagnostic_count: length(diagnostics),
      severities: severity_counts(diagnostics),
      received_at: now_iso8601()
    }
  end

  defp severity_counts(diagnostics) do
    base = %{error: 0, warning: 0, information: 0, hint: 0, unknown: 0}

    Enum.reduce(diagnostics, base, fn diagnostic, counts ->
      severity =
        if is_map(diagnostic) do
          diagnostic
          |> Map.get("severity")
          |> severity_label()
        else
          :unknown
        end

      Map.update!(counts, severity, &(&1 + 1))
    end)
  end

  defp severity_label(1), do: :error
  defp severity_label(2), do: :warning
  defp severity_label(3), do: :information
  defp severity_label(4), do: :hint
  defp severity_label(_severity), do: :unknown

  defp numeric_value(value) when is_integer(value), do: value
  defp numeric_value(_value), do: nil

  defp sync_document(session, owner, uri, language_id, text, requested_version) do
    digest = :crypto.hash(:sha256, text)
    document = Map.get(session.documents, hash_value(uri))

    synced =
      cond do
        is_nil(document) or document.status == :closed -> :opened
        document.digest == digest -> :unchanged
        true -> :changed
      end

    previous_version = if document, do: document.version, else: requested_version - 1

    version =
      if synced == :unchanged,
        do: previous_version,
        else: max(requested_version, previous_version + 1)

    session = send_document_sync(session, synced, uri, language_id, text, version)

    document =
      Map.merge(document || %{}, %{
        uri: uri,
        uri_hash: hash_value(uri),
        owners: MapSet.put(if(document, do: document.owners, else: MapSet.new()), owner),
        digest: digest,
        version: version,
        language_id: language_id,
        status:
          if(synced == :unchanged,
            do: document.status,
            else: if(synced == :opened, do: :open, else: :changed)
          ),
        opened_at: if(document, do: document.opened_at, else: now_iso8601()),
        updated_at: now_iso8601(),
        text_bytes: byte_size(text),
        change_count:
          Map.get(document || %{}, :change_count, 0) + if(synced == :changed, do: 1, else: 0),
        notification_count:
          Map.get(document || %{}, :notification_count, 0) +
            if(synced == :unchanged, do: 0, else: 1)
      })

    {put_in(session.documents[hash_value(uri)], document), synced}
  end

  defp send_document_sync(session, :opened, uri, language_id, text, version) do
    send_lsp_notification(session, "textDocument/didOpen", %{
      "textDocument" => %{
        "uri" => uri,
        "languageId" => language_id,
        "text" => text,
        "version" => version
      }
    })
  end

  defp send_document_sync(session, :changed, uri, _language_id, text, version) do
    send_lsp_notification(session, "textDocument/didChange", %{
      "textDocument" => %{"uri" => uri, "version" => version},
      "contentChanges" => [%{"text" => text}]
    })
  end

  defp send_document_sync(session, :unchanged, _uri, _language_id, _text, _version), do: session

  defp close_owned_document(session, uri, owner) do
    case Map.get(session.documents, hash_value(uri)) do
      nil ->
        session

      document ->
        owners = MapSet.delete(document.owners, owner)
        document = %{document | owners: owners}

        if MapSet.size(owners) == 0 and document.status != :closed do
          session =
            send_lsp_notification(session, "textDocument/didClose", %{
              "textDocument" => %{"uri" => uri}
            })

          document =
            Map.merge(document, %{
              status: :closed,
              closed_at: now_iso8601(),
              updated_at: now_iso8601(),
              notification_count: document.notification_count + 1
            })

          put_in(session.documents[hash_value(uri)], document)
        else
          put_in(session.documents[hash_value(uri)], document)
        end
    end
  end

  defp release_documents(session, owner) do
    Enum.reduce(session.documents, session, fn {_hash, document}, session ->
      close_owned_document(session, document.uri, owner)
    end)
  end

  defp document_projection(document), do: Map.drop(document, [:owners, :uri, :digest])

  defp document_info(session, uri) do
    session
    |> get_in([:documents, hash_value(uri)])
    |> case do
      nil -> %{uri_hash: hash_value(uri), status: :unknown}
      document -> document_projection(document)
    end
  end

  defp recent_documents(session) do
    session
    |> Map.get(:documents, %{})
    |> Map.values()
    |> Enum.sort_by(&Map.get(&1, :updated_at, ""), :desc)
    |> Enum.take(5)
    |> Enum.map(&document_projection/1)
  end

  defp open_document_count(session) do
    session
    |> Map.get(:documents, %{})
    |> Map.values()
    |> Enum.count(&(&1.status in [:open, :changed]))
  end

  defp expire_edits(session, pending_id) do
    {expired, remaining} =
      Map.get(session, :applying_edits, %{})
      |> Enum.split_with(fn {_token, {id, _server_id}} -> id == pending_id end)

    Enum.reduce(expired, Map.put(session, :applying_edits, Map.new(remaining)), fn
      {_token, {_id, server_id}}, session ->
        send_lsp_response(session, server_id, %{
          "applied" => false,
          "failureReason" => "Request expired"
        })
    end)
  end

  defp edits_pending?(session, pending_id),
    do:
      Enum.any?(Map.get(session, :applying_edits, %{}), fn {_token, {id, _}} ->
        id == pending_id
      end)

  defp finish_deferred_request(session, pending_id) do
    case Map.get(session.pending, pending_id) do
      %{deferred_response: response} ->
        if edits_pending?(session, pending_id),
          do: session,
          else: complete_request(session, pending_id, response)

      _ ->
        session
    end
  end

  defp complete_request(session, request_id, message) do
    if edits_pending?(session, request_id) do
      pending = Map.put(Map.fetch!(session.pending, request_id), :deferred_response, message)
      put_in(session.pending[request_id], pending)
    else
      complete_ready_request(session, request_id, message)
    end
  end

  defp complete_ready_request(session, request_id, message) do
    case Map.pop(session.pending, request_id) do
      {nil, pending} ->
        Map.put(session, :pending, pending)

      {request, pending} ->
        reply =
          if Map.get(request, :capture_edits, false),
            do: {:ok, message, Enum.reverse(request.edits)},
            else: {:ok, message}

        reply_request(request, reply)

        session
        |> Map.put(:pending, pending)
        |> Map.update(:response_count, 1, &(&1 + 1))
        |> Map.put(:last_response_at, now_iso8601())
        |> maybe_capture_pull_diagnostics(request, message)
        |> cache_initialization(request, message)
    end
  end

  defp cache_initialization(session, %{method: "initialize"}, message),
    do: %{session | initialization_response: message}

  defp cache_initialization(session, _request, _message), do: session

  defp maybe_capture_pull_diagnostics(
         session,
         %{method: "textDocument/diagnostic"} = request,
         message
       ) do
    result = Map.get(message, "result")

    case pull_diagnostics(result) do
      {:ok, diagnostics} ->
        uri = get_in(request, [:params, "textDocument", "uri"])
        capture_diagnostics(session, %{"uri" => uri, "diagnostics" => diagnostics})

      :ignore ->
        session
    end
  end

  defp maybe_capture_pull_diagnostics(session, _request, _message), do: session

  defp pull_diagnostics(%{"items" => items}) when is_list(items), do: {:ok, items}

  defp pull_diagnostics(%{"diagnostics" => diagnostics}) when is_list(diagnostics),
    do: {:ok, diagnostics}

  defp pull_diagnostics(%{"relatedDocuments" => related}) when is_map(related) do
    diagnostics =
      related
      |> Map.values()
      |> Enum.flat_map(fn result ->
        case pull_diagnostics(result) do
          {:ok, diagnostics} -> diagnostics
          :ignore -> []
        end
      end)

    {:ok, diagnostics}
  end

  defp pull_diagnostics(_result), do: :ignore

  defp session_info(session, opts \\ []) do
    include_session_id? = Keyword.get(opts, :include_session_id, false)

    info =
      session
      |> Map.take([
        :server_id,
        :label,
        :language,
        :command,
        :args_count,
        :cwd_hash,
        :started_at,
        :stopped_at,
        :status,
        :exit_status,
        :protocol,
        :initialized,
        :initialized_at
      ])
      |> Map.put(:session_hash, hash_value(session.session_id))
      |> Map.put(
        :owner_count,
        Enum.reduce(session.owners, 0, fn {_pid, lease}, count -> count + lease.count end)
      )
      |> Map.put(:pending_request_count, map_size(session.pending || %{}))
      |> Map.put(:request_count, Map.get(session, :request_count, 0))
      |> Map.put(:response_count, Map.get(session, :response_count, 0))
      |> Map.put(:notification_count, Map.get(session, :notification_count, 0))
      |> Map.put(:diagnostic_count, Map.get(session, :diagnostic_count, 0))
      |> Map.put(:diagnostic_batch_count, Map.get(session, :diagnostic_batch_count, 0))
      |> Map.put(:last_diagnostics, Map.get(session, :last_diagnostics, []))
      |> Map.put(:document_count, map_size(Map.get(session, :documents, %{})))
      |> Map.put(:open_document_count, open_document_count(session))
      |> Map.put(:recent_documents, recent_documents(session))
      |> maybe_put_info(:last_response_at, Map.get(session, :last_response_at))
      |> maybe_put_info(:last_diagnostic_at, Map.get(session, :last_diagnostic_at))
      |> Map.put(:supervised, true)

    if include_session_id? do
      Map.put(info, :session_id, session.session_id)
    else
      info
    end
  end

  defp maybe_put_info(map, _key, nil), do: map
  defp maybe_put_info(map, key, value), do: Map.put(map, key, value)

  defp maybe_mark_initialized(session, "initialized") do
    session
    |> Map.put(:initialized, true)
    |> Map.put_new(:initialized_at, now_iso8601())
  end

  defp maybe_mark_initialized(session, _method), do: session

  defp pop_session_by_port(sessions, port) do
    case Enum.find(sessions, fn {_id, session} -> session.port == port end) do
      nil -> {nil, sessions}
      {session_id, session} -> {session, Map.delete(sessions, session_id)}
    end
  end

  defp find_session_by_port(sessions, port) do
    Enum.find(sessions, fn {_id, session} -> session.port == port end)
  end

  defp reply_pending(session, response) do
    session.pending
    |> Map.values()
    |> Enum.each(&reply_request(&1, response))
  end

  defp reply_request(request, response) do
    _ = Process.cancel_timer(request.timer)

    Enum.each([request | request.waiters], fn waiter ->
      Process.demonitor(waiter.caller_ref, [:flush])
      GenServer.reply(waiter.from, response)
    end)
  end

  defp drop_request_caller(session, id, ref) do
    request = session.pending[id]
    waiters = Enum.reject(request.waiters, &(&1.caller_ref == ref))

    cond do
      request.caller_ref != ref ->
        put_in(session.pending[id], %{request | waiters: waiters})

      waiters != [] ->
        [first | rest] = waiters
        request = %{request | from: first.from, caller_ref: first.caller_ref, waiters: rest}
        put_in(session.pending[id], request)

      true ->
        _ = Process.cancel_timer(request.timer)

        session
        |> update_in([:pending], &Map.delete(&1, id))
        |> send_lsp_notification("$/cancelRequest", %{"id" => id})
        |> expire_edits(id)
    end
  end

  defp pending_request_count(sessions) do
    sessions
    |> Map.values()
    |> Enum.reduce(0, fn session, count -> count + map_size(session.pending || %{}) end)
  end

  defp remember_session(state, session) do
    recent_sessions =
      [session | state.recent_sessions]
      |> Enum.uniq_by(& &1.session_hash)
      |> Enum.take(5)

    Map.put(state, :recent_sessions, recent_sessions)
  end

  defp hash_value(nil), do: nil

  defp hash_value(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end
end
