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

  @spec start_session(atom() | String.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def start_session(server_id, opts \\ []) do
    GenServer.call(@name, {:start_session, server_id, opts}, 5_000)
  end

  @spec stop_session(String.t()) :: {:ok, map()} | {:error, :unknown_lsp_session}
  def stop_session(session_id) when is_binary(session_id) do
    GenServer.call(@name, {:stop_session, session_id}, 5_000)
  end

  @spec request_session(String.t(), String.t(), map() | list() | nil, keyword()) ::
          request_result()
  def request_session(session_id, method, params \\ %{}, opts \\ [])
      when is_binary(session_id) and is_binary(method) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5_000)

    GenServer.call(
      @name,
      {:request_session, session_id, method, params, timeout_ms},
      timeout_ms + 1_000
    )
  end

  @spec initialize_session(String.t(), map() | list() | nil, keyword()) :: request_result()
  def initialize_session(session_id, params \\ %{}, opts \\ []) when is_binary(session_id) do
    with {:ok, response} <- request_session(session_id, "initialize", params, opts),
         :ok <- notify_session(session_id, "initialized", %{}) do
      {:ok, response}
    end
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

  def handle_call({:start_session, server_id, opts}, _from, state) do
    session_id = session_id(server_id, opts)

    cond do
      Map.has_key?(state.sessions, session_id) ->
        {:reply, {:error, :duplicate_lsp_session}, state}

      true ->
        case start_port(server_id, opts) do
          {:ok, session} ->
            session = Map.put(session, :session_id, session_id)
            state = put_in(state.sessions[session_id], session)
            {:reply, {:ok, session_info(session, include_session_id: true)}, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call({:stop_session, session_id}, _from, state) do
    case Map.pop(state.sessions, session_id) do
      {nil, _sessions} ->
        {:reply, {:error, :unknown_lsp_session}, state}

      {session, sessions} ->
        terminate_port(session)
        reply_pending(session, {:error, :session_stopped})

        info =
          session
          |> Map.merge(%{status: :stopped, stopped_at: now_iso8601()})
          |> session_info(include_session_id: true)

        state =
          state
          |> Map.put(:sessions, sessions)
          |> remember_session(Map.delete(info, :session_id))

        {:reply, {:ok, info}, state}
    end
  end

  def handle_call({:request_session, session_id, method, params, timeout_ms}, from, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         :ok <- validate_method(method),
         {:ok, params} <- validate_params(params),
         {:ok, timeout_ms} <- validate_timeout(timeout_ms) do
      request_id = state.next_request_id + 1
      payload = %{"jsonrpc" => "2.0", "id" => request_id, "method" => method, "params" => params}

      timer =
        Process.send_after(self(), {:lsp_request_timeout, session_id, request_id}, timeout_ms)

      true = Port.command(session.port, frame_message(payload))

      pending =
        Map.put(session.pending, request_id, %{
          from: from,
          timer: timer,
          method: method,
          params: params,
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
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:notify_session, session_id, method, params}, _from, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         :ok <- validate_method(method),
         {:ok, params} <- validate_params(params) do
      payload = %{"jsonrpc" => "2.0", "method" => method, "params" => params}
      true = Port.command(session.port, frame_message(payload))

      session =
        session
        |> Map.update(:notification_count, 1, &(&1 + 1))
        |> maybe_mark_initialized(method)

      {:reply, :ok, put_in(state, [:sessions, session_id], session)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(
        {:open_document, session_id, uri, language_id, text, version},
        _from,
        state
      ) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, uri} <- validate_document_uri(uri),
         {:ok, language_id} <- validate_language_id(language_id),
         {:ok, text} <- validate_document_text(text),
         {:ok, version} <- validate_document_version(version) do
      params = %{
        "textDocument" => %{
          "uri" => uri,
          "languageId" => language_id,
          "version" => version,
          "text" => text
        }
      }

      session =
        session
        |> send_lsp_notification("textDocument/didOpen", params)
        |> put_document(uri, %{
          status: :open,
          language_id: language_id,
          version: version,
          opened_at: now_iso8601(),
          updated_at: now_iso8601(),
          text_bytes: byte_size(text),
          change_count: 0
        })

      {:reply, {:ok, document_info(session, uri)},
       put_in(state, [:sessions, session_id], session)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:change_document, session_id, uri, text, version}, _from, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, uri} <- validate_document_uri(uri),
         {:ok, text} <- validate_document_text(text),
         {:ok, version} <- validate_document_version(version) do
      params = %{
        "textDocument" => %{"uri" => uri, "version" => version},
        "contentChanges" => [%{"text" => text}]
      }

      session =
        session
        |> send_lsp_notification("textDocument/didChange", params)
        |> update_document(uri, fn document ->
          document
          |> Map.put(:status, :changed)
          |> Map.put(:version, version)
          |> Map.put(:updated_at, now_iso8601())
          |> Map.put(:text_bytes, byte_size(text))
          |> Map.update(:change_count, 1, &(&1 + 1))
        end)

      {:reply, {:ok, document_info(session, uri)},
       put_in(state, [:sessions, session_id], session)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:close_document, session_id, uri}, _from, state) do
    with {:ok, session} <- fetch_session(state, session_id),
         {:ok, uri} <- validate_document_uri(uri) do
      params = %{"textDocument" => %{"uri" => uri}}

      session =
        session
        |> send_lsp_notification("textDocument/didClose", params)
        |> update_document(uri, fn document ->
          document
          |> Map.put(:status, :closed)
          |> Map.put(:closed_at, now_iso8601())
          |> Map.put(:updated_at, now_iso8601())
        end)

      {:reply, {:ok, document_info(session, uri)},
       put_in(state, [:sessions, session_id], session)}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
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

  def handle_info({:lsp_request_timeout, session_id, request_id}, state) do
    case Map.get(state.sessions, session_id) do
      nil ->
        {:noreply, state}

      session ->
        case Map.pop(session.pending, request_id) do
          {nil, _pending} ->
            {:noreply, state}

          {pending, remaining_pending} ->
            Process.cancel_timer(pending.timer)
            GenServer.reply(pending.from, {:error, :request_timeout})

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

  defp start_port(server_id, opts) do
    with {:ok, command} <- LemonLsp.Servers.resolve_command(server_id),
         {:ok, cwd} <- validate_cwd(Keyword.get(opts, :cwd)) do
      port_opts =
        [:binary, :exit_status, :stderr_to_stdout, {:args, command.args}]
        |> maybe_env(command.env)
        |> maybe_cd(cwd)

      port = Port.open({:spawn_executable, command.executable}, port_opts)
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
  end

  defp validate_cwd(nil), do: {:ok, nil}

  defp validate_cwd(cwd) when is_binary(cwd) do
    expanded = Path.expand(cwd)

    if File.dir?(expanded) do
      {:ok, expanded}
    else
      {:error, :invalid_cwd}
    end
  end

  defp validate_cwd(_cwd), do: {:error, :invalid_cwd}

  defp maybe_cd(opts, nil), do: opts
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

  defp validate_timeout(timeout_ms) when is_integer(timeout_ms) and timeout_ms in 50..60_000,
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
      {:ok, %{"id" => request_id} = message}, session ->
        complete_request(session, request_id, message)

      {:ok, %{"method" => "textDocument/publishDiagnostics"} = message}, session ->
        capture_diagnostics(session, Map.get(message, "params", %{}))

      _message, session ->
        session
    end)
  end

  defp capture_diagnostics(session, params) when is_map(params) do
    summary = diagnostic_summary(params)

    session
    |> Map.update(:diagnostic_count, summary.diagnostic_count, &(&1 + summary.diagnostic_count))
    |> Map.update(:diagnostic_batch_count, 1, &(&1 + 1))
    |> Map.put(:last_diagnostic_at, summary.received_at)
    |> Map.update(:last_diagnostics, [summary], fn summaries ->
      [summary | summaries] |> Enum.take(5)
    end)
  end

  defp capture_diagnostics(session, _params), do: session

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

  defp put_document(session, uri, document) do
    document =
      document
      |> Map.put(:uri_hash, hash_value(uri))
      |> Map.put(:notification_count, 1)

    put_in(session, [:documents, hash_value(uri)], document)
  end

  defp update_document(session, uri, fun) do
    uri_hash = hash_value(uri)

    document =
      session
      |> get_in([:documents, uri_hash])
      |> case do
        nil -> %{uri_hash: uri_hash, status: :unknown, change_count: 0, notification_count: 0}
        document -> document
      end
      |> fun.()
      |> Map.update(:notification_count, 1, &(&1 + 1))

    put_in(session, [:documents, uri_hash], document)
  end

  defp document_info(session, uri) do
    session
    |> get_in([:documents, hash_value(uri)])
    |> case do
      nil -> %{uri_hash: hash_value(uri), status: :unknown}
      document -> document
    end
  end

  defp recent_documents(session) do
    session
    |> Map.get(:documents, %{})
    |> Map.values()
    |> Enum.sort_by(&Map.get(&1, :updated_at, ""), :desc)
    |> Enum.take(5)
  end

  defp open_document_count(session) do
    session
    |> Map.get(:documents, %{})
    |> Map.values()
    |> Enum.count(&(&1.status in [:open, :changed]))
  end

  defp complete_request(session, request_id, message) do
    case Map.pop(session.pending, request_id) do
      {nil, pending} ->
        Map.put(session, :pending, pending)

      {request, pending} ->
        Process.cancel_timer(request.timer)
        GenServer.reply(request.from, {:ok, message})

        session
        |> Map.put(:pending, pending)
        |> Map.update(:response_count, 1, &(&1 + 1))
        |> Map.put(:last_response_at, now_iso8601())
        |> maybe_capture_pull_diagnostics(request, message)
    end
  end

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
    |> Enum.each(fn pending ->
      Process.cancel_timer(pending.timer)
      GenServer.reply(pending.from, response)
    end)
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
