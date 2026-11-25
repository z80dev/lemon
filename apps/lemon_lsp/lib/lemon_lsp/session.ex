defmodule LemonLsp.Session do
  @moduledoc false
  use GenServer, restart: :temporary

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # Document text, diagnostics, launch settings and protocol traffic never
  # reach crash reports or `:sys.get_status/1`.
  def format_status(status) do
    Map.new(status, fn
      {:state, _} -> {:state, :redacted}
      {:message, _} -> {:message, :redacted}
      {:reason, _} -> {:reason, :redacted}
      {:log, _} -> {:log, []}
      pair -> pair
    end)
  end

  def init(opts) do
    Process.flag(:trap_exit, true)
    manager = Keyword.fetch!(opts, :manager)
    id = Keyword.fetch!(opts, :session_id)
    Process.monitor(manager)
    {:ok, _} = Registry.register(LemonLsp.SessionRegistry, {:id, manager, id}, nil)
    {:ok, _} = Registry.register(LemonLsp.SessionRegistry, {:pool, manager, opts[:pool_key]}, nil)

    state =
      refresh_state(%{
        started_at: now_iso8601(),
        refresh_count: 0,
        next_request_id: 0,
        sessions: %{},
        recent_sessions: [],
        manager: manager,
        last_used: System.unique_integer([:monotonic])
      })

    {:reply, {:ok, _info}, state} =
      session_call(
        {:start_session, opts[:server_id], opts},
        {opts[:owner], make_ref()},
        state
      )

    publish(state)
    {:ok, state}
  end

  def handle_call(message, from, state),
    do: finish(session_call(message, from, touch(message, state)))

  def handle_info({:forward, :acquired_info, from}, state) do
    [session] = Map.values(state.sessions)
    publish(state)
    GenServer.reply(from, {:ok, session_info(session, include_session_id: true)})
    {:noreply, state}
  end

  def handle_info({:forward, message, from}, state) do
    case session_call(message, from, touch(message, state)) do
      {:reply, reply, state} ->
        publish(state)
        GenServer.reply(from, reply)
        finish({:noreply, state})

      result ->
        finish(result)
    end
  end

  def handle_info({:DOWN, _ref, :process, manager, _reason}, %{manager: manager} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:rpc_finished, id, :timeout}, state) do
    [session_id] = Map.keys(state.sessions)
    finish(session_message({:lsp_request_timeout, session_id, id}, state))
  end

  def handle_info({:rpc_finished, _id, _reason}, state), do: {:noreply, state}
  def handle_info({{:rpc_reply, _id}, _result}, state), do: {:noreply, state}

  def handle_info({:rpc_message, message}, state) do
    sessions =
      Map.new(state.sessions, fn {id, session} ->
        {id, handle_messages(session, [{:ok, message}])}
      end)

    finish({:noreply, %{state | sessions: sessions}})
  end

  def handle_info({:EXIT, pid, _reason}, state) when is_pid(pid) do
    {:stop, :normal, state}
  end

  def handle_info(message, state), do: finish(session_message(message, state))

  defp finish({:reply, reply, state}) do
    publish(state)

    if map_size(state.sessions) == 0,
      do: {:stop, :normal, reply, state},
      else: {:reply, reply, state}
  end

  defp finish({:noreply, state}) do
    publish(state)
    if map_size(state.sessions) == 0, do: {:stop, :normal, state}, else: {:noreply, state}
  end

  # The manager evicts the least-recently-used session when the live cap is
  # reached; status reads and eviction probes are not uses.
  defp publish(state),
    do: send(state.manager, {:session_status, self(), status_from_state(state), state.last_used})

  defp touch(:status, state), do: state
  defp touch(:refresh, state), do: state
  defp touch({:evict_if_idle, _expires_at}, state), do: state
  defp touch(_message, state), do: %{state | last_used: System.unique_integer([:monotonic])}

  defp session_call(:status, _from, state) do
    {:reply, status_from_state(state), state}
  end

  defp session_call(:refresh, _from, state) do
    state = refresh_state(state)
    {:reply, status_from_state(state), state}
  end

  # Decided here, not from the manager's last published status, so a request
  # dispatched since then keeps its session alive. A probe read after its
  # monotonic expiry (the session was suspended or backlogged) is refused: the
  # manager has stopped waiting for it and may already have freed a slot elsewhere.
  defp session_call({:evict_if_idle, expires_at}, _from, state) do
    cond do
      System.monotonic_time(:millisecond) >= expires_at ->
        {:reply, {:error, :expired}, state}

      pending_request_count(state.sessions) > 0 ->
        {:reply, {:error, :busy}, state}

      true ->
        state =
          Enum.reduce(state.sessions, state, fn {session_id, session}, state ->
            info = stopped_session_info(session, :evicted)

            state
            |> update_in([:sessions], &Map.delete(&1, session_id))
            |> remember_session(Map.delete(info, :session_id))
          end)

        {:reply, :ok, state}
    end
  end

  defp session_call({:start_session, server_id, opts}, {caller, _}, state) do
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
                config_root: config_root,
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

  defp session_call({:release_session, session_id, owner}, _from, state) do
    case fetch_session(state, session_id) do
      {:ok, session} ->
        {:reply, :ok, release_owner(state, session, owner, false)}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp session_call({:stop_session, session_id}, _from, state) do
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

  defp session_call(
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
          case initialize_params(session, method, params) do
            {:error, reason} ->
              {:reply, {:error, reason}, state}

            {:ok, params} ->
              request_id = state.next_request_id + 1

              payload = %{
                "jsonrpc" => "2.0",
                "id" => request_id,
                "method" => method,
                "params" => params
              }

              # The RPC client owns the deadline and transport request. The session
              # retains LSP policy (initialization waiters and edit receipts).
              case dispatch(session, request_id, payload, timeout_ms) do
                :ok ->
                  pending =
                    Map.put(session.pending, request_id, %{
                      from: from,
                      method: method,
                      document_uri: pending_document_uri(method, params),
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

                {:error, reason} ->
                  {:reply, {:error, reason}, Map.put(state, :next_request_id, request_id)}
              end
          end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp session_call({:apply_edit_result, session_id, token, result}, {caller, _}, state) do
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

  defp session_call({:notify_session, session_id, method, params}, _from, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         :ok <- validate_method(method),
         {:ok, params} <- validate_params(params),
         {:ok, session} <- notify_once(session, method, params) do
      {:reply, :ok, put_in(state, [:sessions, session_id], session)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Document text is sent to the server as JSON, which carries only UTF-8: a
  # file in another encoding is refused here rather than failing in transport.
  defp session_call({:sync_file, session_id, path, language_id}, {owner, _}, state) do
    # Document text goes to a project-run server: never a Lemon credential.
    with {:ok, session} <- fetch_session(state, session_id),
         {:credential, :ok} <- {:credential, LemonCore.CredentialPaths.check_read(path)},
         {:ok, text} <- File.read(path),
         {:ok, text} <- validate_document_text(text),
         {:ok, language_id} <- validate_language_id(language_id),
         uri = "file://" <> URI.encode(Path.expand(path), &(URI.char_unreserved?(&1) or &1 == ?/)),
         seq = session.diagnostic_seq,
         {:ok, session, synced} <- sync_document(session, owner, uri, language_id, text, 1) do
      info = Map.merge(document_info(session, uri), %{synced: synced, diagnostics_seq: seq})
      {:reply, {:ok, info}, put_in(state.sessions[session_id], session)}
    else
      {:credential, {:error, _message}} -> {:reply, {:error, :credential_path}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp session_call(
         {:open_document, session_id, uri, language_id, text, version},
         {owner, _},
         state
       ) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, uri} <- validate_document_uri(uri),
         {:ok, language_id} <- validate_language_id(language_id),
         {:ok, text} <- validate_document_text(text),
         {:ok, version} <- validate_document_version(version),
         {:ok, session, synced} <-
           sync_document(session, owner, uri, language_id, text, version) do
      {:reply, {:ok, Map.put(document_info(session, uri), :synced, synced)},
       put_in(state, [:sessions, session_id], session)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp session_call({:change_document, session_id, uri, text, version}, {owner, _}, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, uri} <- validate_document_uri(uri),
         {:ok, text} <- validate_document_text(text),
         {:ok, version} <- validate_document_version(version),
         language_id = get_in(session.documents, [hash_value(uri), :language_id]) || "plaintext",
         {:ok, session, synced} <-
           sync_document(session, owner, uri, language_id, text, version) do
      {:reply, {:ok, Map.put(document_info(session, uri), :synced, synced)},
       put_in(state, [:sessions, session_id], session)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp session_call({:close_document, session_id, uri}, {owner, _}, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, uri} <- validate_document_uri(uri),
         {:ok, session} <- close_owned_document(session, uri, owner) do
      {:reply, {:ok, document_info(session, uri)},
       put_in(state, [:sessions, session_id], session)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp session_call({:document_diagnostics, session_id, uri}, _from, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, uri} <- validate_document_uri(uri) do
      entry = get_in(session, [:diagnostics_by_uri, uri])
      {:reply, {:ok, %{seq: Map.get(session, :diagnostic_seq, 0), entry: entry}}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp session_call({:workspace_diagnostics, session_id}, _from, state) do
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

  defp session_message({port, {:data, data}}, state) when is_port(port) do
    case find_session_by_port(state.sessions, port) do
      nil ->
        {:noreply, state}

      {_session_id, session} ->
        LemonCore.Rpc.Client.feed(session.rpc, data)
        {:noreply, state}
    end
  end

  defp session_message({port, {:exit_status, exit_status}}, state) when is_port(port) do
    case pop_session_by_port(state.sessions, port) do
      {nil, _sessions} ->
        {:noreply, state}

      {session, sessions} ->
        demonitor_owner(session)
        terminate_port(session)
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

  defp session_message({:EXIT, port, _reason}, state) when is_port(port) do
    {:noreply, state}
  end

  defp session_message({:DOWN, ref, :process, _pid, _reason}, state) do
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

  defp session_message({:idle_shutdown, session_id, token}, state) do
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

  defp session_message({:lsp_request_timeout, session_id, request_id}, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:noreply, state}

      session ->
        case Map.pop(session.pending, request_id) do
          {nil, _pending} ->
            {:noreply, state}

          {%{on_timeout: :cancel} = pending, remaining_pending} ->
            Process.demonitor(pending.caller_ref, [:flush])
            reply_request(pending, {:error, :request_timeout})

            session =
              session
              |> Map.put(:pending, remaining_pending)
              |> notify_server("$/cancelRequest", %{"id" => request_id})
              |> expire_edits(request_id)

            {:noreply, put_in(state, [:sessions, session_id], session)}

          {pending, remaining_pending} ->
            Process.demonitor(pending.caller_ref, [:flush])
            demonitor_owner(session)

            session =
              session
              |> Map.put(:pending, remaining_pending)
              |> Map.merge(%{status: :request_timeout, stopped_at: now_iso8601()})

            terminate_port(session)
            reply_request(pending, {:error, :request_timeout})
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

  def terminate(_reason, state) do
    Enum.each(state.sessions, fn {_id, session} ->
      demonitor_owner(session)
      terminate_port(session)
      reply_pending(session, {:error, :session_stopped})
    end)

    :ok
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
        :redacted_health_status,
        :workspace_root_detection,
        :live_session_cap
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

  # Initialization options can carry credentials, so they are re-resolved from
  # config at dispatch time rather than retained in session state.
  defp initialize_params(session, "initialize", params) when is_map(params) do
    {_server_id, _cwd, config_hash} = session.pool_key

    case LemonLsp.Servers.resolve_command(session.server_id, session.config_root) do
      {:ok, %{server: %{config_hash: ^config_hash}} = command} ->
        {:ok, Map.put(params, "initializationOptions", command.initialization_options)}

      {:ok, _command} ->
        {:error, :lsp_config_changed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp initialize_params(_session, _method, params), do: {:ok, params}

  defp pending_document_uri("textDocument/diagnostic", %{"textDocument" => %{"uri" => uri}}),
    do: uri

  defp pending_document_uri(_method, _params), do: nil

  defp now_iso8601 do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
  end

  defp start_port(command, cwd) do
    {executable, args} = launch_spec(command)

    port_opts =
      [:binary, :exit_status, :stderr_to_stdout, {:args, args}]
      |> put_env(command.env)
      |> maybe_cd(cwd)

    port = LemonCore.NativeProcess.open({:spawn_executable, executable}, port_opts)
    os_pid = port_os_pid(port)

    {:ok, rpc} =
      LemonCore.Rpc.Client.start_link(
        owner: self(),
        framing: LemonCore.Rpc.ContentLength,
        send: fn bytes -> if Port.command(port, bytes), do: :ok, else: {:error, :closed} end
      )

    {:ok,
     %{
       port: port,
       rpc: rpc,
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
       initialized: false,
       server_id: command.server.id,
       label: command.server.label,
       language: command.server.language,
       command: command.command,
       args_count: length(command.args),
       cwd_hash: hash_value(cwd),
       started_at: now_iso8601(),
       status: :running
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
      &send(&1, {LemonLsp.ServerManager, :server_stopped, session.session_id})
    )

    LemonCore.Bus.broadcast(
      LemonLsp.ServerManager.diagnostics_topic(session.session_id),
      {:lsp_server_stopped, session.session_id}
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

  defp edit_capture_available(session, %{capture_edits: true}) do
    if capturing_request(session),
      do: {:error, :edit_request_in_progress},
      else: :ok
  end

  defp edit_capture_available(_session, _opts), do: :ok

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

  # Language servers run project toolchains: never hand them Lemon's secrets,
  # whether or not the server config adds variables of its own.
  defp put_env(opts, env) when is_map(env), do: [{:env, LemonCore.ChildEnv.port_env(env)} | opts]

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} when is_integer(os_pid) -> os_pid
      _ -> nil
    end
  end

  defp terminate_port(session) do
    _ =
      if is_integer(session.os_pid),
        do: LemonCore.ProcessGroup.terminate(session.os_pid, grace_ms: 25)

    if Process.alive?(session.rpc), do: GenServer.stop(session.rpc, :normal)

    try do
      Port.close(session.port)
    rescue
      ArgumentError -> :ok
    catch
      :exit, _reason -> :ok
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
    if String.trim(uri) == "" or not String.valid?(uri),
      do: {:error, :invalid_document_uri},
      else: {:ok, uri}
  end

  defp validate_document_uri(_uri), do: {:error, :invalid_document_uri}

  defp validate_language_id(language_id) when is_binary(language_id) do
    if String.trim(language_id) == "" or not String.valid?(language_id),
      do: {:error, :invalid_language_id},
      else: {:ok, language_id}
  end

  defp validate_language_id(_language_id), do: {:error, :invalid_language_id}

  defp validate_document_text(text) when is_binary(text) do
    if String.valid?(text), do: {:ok, text}, else: {:error, :invalid_document_encoding}
  end

  defp validate_document_text(_text), do: {:error, :invalid_document_text}

  defp validate_document_version(version) when is_integer(version) and version >= 0,
    do: {:ok, version}

  defp validate_document_version(_version), do: {:error, :invalid_document_version}

  defp send_lsp_notification(session, method, params) do
    payload = %{"jsonrpc" => "2.0", "method" => method, "params" => params}

    with :ok <- transmit(session, payload),
         do: {:ok, Map.update(session, :notification_count, 1, &(&1 + 1))}
  end

  # Bookkeeping notifications (`$/cancelRequest`, releases) answer no caller.
  # They carry only ids and validated URIs, so a failure means the transport is
  # closing and the port exit that follows cleans up the session.
  defp notify_server(session, method, params) do
    case send_lsp_notification(session, method, params) do
      {:ok, session} -> session
      {:error, _reason} -> session
    end
  end

  defp notify_once(%{initialized: true} = session, "initialized", _params), do: {:ok, session}

  defp notify_once(session, method, params) do
    with {:ok, session} <- send_lsp_notification(session, method, params),
         do: {:ok, maybe_mark_initialized(session, method)}
  end

  defp dispatch(session, request_id, payload, timeout_ms) do
    session.rpc
    |> LemonCore.Rpc.Client.dispatch(
      request_id,
      payload,
      {self(), {:rpc_reply, request_id}},
      timeout_ms,
      self()
    )
    |> transport_result()
  catch
    :exit, _reason -> {:error, :transport_closed}
  end

  defp transmit(session, payload) do
    session.rpc
    |> LemonCore.Rpc.Client.send_message(payload)
    |> transport_result()
  catch
    :exit, _reason -> {:error, :transport_closed}
  end

  # Encoder errors embed the payload bytes: only their class leaves here.
  defp transport_result(:ok), do: :ok
  defp transport_result({:error, %{__exception__: true}}), do: {:error, :invalid_message_encoding}
  defp transport_result({:error, :duplicate_id}), do: {:error, :duplicate_request_id}
  defp transport_result({:error, _reason}), do: {:error, :transport_closed}

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
        send(elem(pending.from, 0), {LemonLsp.ServerManager, :apply_edit, token, params["edit"]})

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

  # Answers to server-initiated requests have no caller to report to. A result
  # that cannot be encoded (for example a non-UTF-8 edit failure reason) is
  # answered with an internal error so the server is not left waiting; a closed
  # transport is followed by the port exit that cleans up the session.
  defp send_lsp_response(session, request_id, result) do
    payload = %{"jsonrpc" => "2.0", "id" => request_id, "result" => result}

    case transmit(session, payload) do
      {:error, :invalid_message_encoding} ->
        send_lsp_error(session, request_id, -32_603, "Response could not be encoded")

      _sent_or_closed ->
        session
    end
  end

  defp send_lsp_error(session, request_id, code, message) do
    payload = %{
      "jsonrpc" => "2.0",
      "id" => request_id,
      "error" => %{"code" => code, "message" => message}
    }

    _ = transmit(session, payload)
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
      send(owner, {LemonLsp.ServerManager, :diagnostics, session.session_id, uri, entry})
    end)

    LemonCore.Bus.broadcast(
      LemonLsp.ServerManager.diagnostics_topic(session.session_id),
      {:lsp_diagnostics, session.session_id, uri}
    )

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

    with {:ok, session} <- send_document_sync(session, synced, uri, language_id, text, version) do
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

      {:ok, put_in(session.documents[hash_value(uri)], document), synced}
    end
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

  defp send_document_sync(session, :unchanged, _uri, _language_id, _text, _version),
    do: {:ok, session}

  defp close_owned_document(session, uri, owner) do
    case Map.get(session.documents, hash_value(uri)) do
      nil ->
        {:ok, session}

      document ->
        owners = MapSet.delete(document.owners, owner)
        document = %{document | owners: owners}

        if MapSet.size(owners) == 0 and document.status != :closed do
          with {:ok, session} <-
                 send_lsp_notification(session, "textDocument/didClose", %{
                   "textDocument" => %{"uri" => uri}
                 }) do
            document =
              Map.merge(document, %{
                status: :closed,
                closed_at: now_iso8601(),
                updated_at: now_iso8601(),
                notification_count: document.notification_count + 1
              })

            {:ok, put_in(session.documents[hash_value(uri)], document)}
          end
        else
          {:ok, put_in(session.documents[hash_value(uri)], document)}
        end
    end
  end

  # A released owner's documents close best-effort: their URIs were validated
  # when opened, so a failed didClose means the transport is already closing.
  defp release_documents(session, owner) do
    Enum.reduce(session.documents, session, fn {_hash, document}, session ->
      case close_owned_document(session, document.uri, owner) do
        {:ok, session} -> session
        {:error, _reason} -> session
      end
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

        _ = LemonCore.Rpc.Client.complete(session.rpc, request_id, reply)

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
        uri = Map.get(request, :document_uri)
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
        cancel_dispatch(session, id)

        session
        |> update_in([:pending], &Map.delete(&1, id))
        |> notify_server("$/cancelRequest", %{"id" => id})
        |> expire_edits(id)
    end
  end

  defp cancel_dispatch(session, id) do
    LemonCore.Rpc.Client.cancel(session.rpc, id)
  catch
    :exit, _reason -> :ok
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
