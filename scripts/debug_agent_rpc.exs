# Ensure apps are started
Application.ensure_all_started(:ai)
Application.ensure_all_started(:agent_core)
Application.ensure_all_started(:coding_agent)
Application.ensure_all_started(:coding_agent_ui)


defmodule DebugAgentRPC do
  @moduledoc """
  JSON-line RPC server for Lemon TUI with multi-session support.

  Maintains a session manager state that tracks:
  - sessions: %{session_id => pid}
  - pid_to_session: %{pid => session_id}
  - forwarders: %{session_id => pid}
  - active_session_id: the default session for commands without session_id
  - primary_session_id: optional session started at boot (for backwards compat)
  """

  defstruct [
    :cwd,
    :model,
    :settings,
    :ui_context,
    :debug,
    sessions: %{},
    pid_to_session: %{},
    forwarders: %{},
    active_session_id: nil,
    primary_session_id: nil,
    # Monotonic event sequence counters per session for stable ordering
    event_seqs: %{}
  ]

  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [
          cwd: :string,
          model: :string,
          system_prompt: :string,
          base_url: :string,
          session_file: :string,
          debug: :boolean,
          no_ui: :boolean
        ]
      )

    debug_enabled = opts[:debug] == true or System.get_env("LEMON_DEBUG_RPC") == "1"
    Logger.configure(level: if(debug_enabled, do: :debug, else: :warning))
    Process.put(:debug, debug_enabled)

    cwd = opts[:cwd] || File.cwd!()
    settings = CodingAgent.SettingsManager.load(cwd)
    model = resolve_model(opts[:model], settings)
    model = maybe_override_base_url(model, opts[:base_url], settings)

    debug_log("settings loaded", %{
      cwd: cwd,
      model: %{provider: model.provider, id: model.id, base_url: model.base_url},
      providers: Map.keys(settings.providers || %{})
    })

    # UI is enabled by default; use --no-ui to disable
    ui_enabled = opts[:no_ui] != true
    ui_context =
      if ui_enabled do
        {:ok, _ui_pid} = CodingAgent.UI.DebugRPC.start_link(name: CodingAgent.UI.DebugRPC)
        CodingAgent.UI.Context.new(CodingAgent.UI.DebugRPC)
      else
        nil
      end

    # Initialize state (no sessions at startup)
    state = %__MODULE__{
      cwd: cwd,
      model: model,
      settings: settings,
      ui_context: ui_context,
      debug: debug_enabled,
      sessions: %{},
      pid_to_session: %{},
      forwarders: %{},
      active_session_id: nil,
      primary_session_id: nil
    }

    send_json(%{
      type: "ready",
      cwd: cwd,
      model: %{provider: model.provider, id: model.id},
      debug: debug_enabled,
      ui: ui_enabled,
      primary_session_id: nil,
      active_session_id: nil
    })
    debug_log("ready_sent", %{cwd: cwd, primary_session_id: nil})

    parent = self()
    Task.start(fn -> read_input_loop(parent) end)
    if Process.get(:debug, false) do
      send_json(%{type: "debug", message: "debug mode enabled", argv: System.argv()})
    end

    loop(state)
  end

  defp loop(state) do
    receive do
      {:session_event, session_id, event} ->
        debug_log("session_event", %{type: event_type(event), session_id: session_id})
        # Get and increment monotonic event sequence for this session
        {event_seq, new_event_seqs} = next_event_seq(state.event_seqs, session_id)
        send_json(%{type: "event", session_id: session_id, event_seq: event_seq, event: encode_event(event)})
        loop(%{state | event_seqs: new_event_seqs})

      {:stdin, :eof} ->
        send_json(%{type: "error", message: "stdin closed"})
        :ok

      {:stdin, line} ->
        case handle_line(state, line) do
          {:quit, _state} ->
            send_json(%{type: "event", event: %{type: "quit"}})
            :ok

          {:ok, new_state} ->
            loop(new_state)
        end

      {:debug_stats, _ref, session_id} ->
        case get_session_pid(state, session_id) do
          {:ok, pid} ->
            stats = CodingAgent.Session.get_stats(pid)
            send_json(%{type: "stats", session_id: session_id, stats: stats})

          :error ->
            :ok
        end
        loop(state)

      {:DOWN, _ref, :process, pid, reason} ->
        # A session process died
        case Map.get(state.pid_to_session, pid) do
          nil ->
            loop(state)

          session_id ->
            debug_log("session_down", %{session_id: session_id, reason: inspect(reason)})

            reason_str = if reason == :normal, do: "normal", else: "error"
            send_json(%{type: "session_closed", session_id: session_id, reason: reason_str})

            # Remove from state
            forwarder_pid = Map.get(state.forwarders, session_id)
            if is_pid(forwarder_pid) and Process.alive?(forwarder_pid) do
              send(forwarder_pid, :stop_forwarder)
            end

            new_sessions = Map.delete(state.sessions, session_id)
            new_pid_to_session = Map.delete(state.pid_to_session, pid)
            new_forwarders = Map.delete(state.forwarders, session_id)
            new_event_seqs = Map.delete(state.event_seqs, session_id)

            new_active =
              if state.active_session_id == session_id do
                nil
              else
                state.active_session_id
              end

            new_state = %{
              state
              | sessions: new_sessions,
                pid_to_session: new_pid_to_session,
                forwarders: new_forwarders,
                active_session_id: new_active,
                event_seqs: new_event_seqs
            }

            if new_active != state.active_session_id do
              send_json(%{type: "active_session", session_id: new_active})
            end

            loop(new_state)
        end
    end
  end

  defp handle_line(state, line) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      {:ok, state}
    else
      debug_log("stdin", %{line: trimmed})

      case Jason.decode(trimmed) do
        {:ok, cmd} ->
          handle_command(state, cmd)

        {:error, _} ->
          # Fallback: treat as plain text prompt to active session
          case get_active_session(state) do
            {:ok, pid, session_id} ->
              case CodingAgent.Session.prompt(pid, trimmed) do
                :ok ->
                  schedule_stats(session_id)
                  {:ok, state}

                {:error, reason} ->
                  send_json(%{type: "error", message: inspect(reason), session_id: session_id})
                  {:ok, state}
              end

            :error ->
              send_json(%{type: "error", message: "no active session"})
              {:ok, state}
          end
      end
    end
  end

  # ============================================================================
  # Command Handlers
  # ============================================================================

  defp handle_command(state, %{"type" => "prompt", "text" => text} = cmd) do
    session_id = cmd["session_id"]

    case resolve_session(state, session_id) do
      {:ok, pid, resolved_id} ->
        result = CodingAgent.Session.prompt(pid, text)
        debug_log("prompt", %{text: text, session_id: resolved_id, result: result})

        case result do
          :ok ->
            schedule_stats(resolved_id)
            {:ok, state}

          {:error, reason} ->
            send_json(%{type: "error", message: inspect(reason), session_id: resolved_id})
            {:ok, state}
        end

      :error ->
        send_not_found_error(session_id)
        {:ok, state}
    end
  end

  defp handle_command(state, %{"type" => "stats"} = cmd) do
    session_id = cmd["session_id"]

    case resolve_session(state, session_id) do
      {:ok, pid, resolved_id} ->
        stats = CodingAgent.Session.get_stats(pid)
        send_json(%{type: "stats", session_id: resolved_id, stats: stats})

      :error ->
        send_not_found_error(session_id)
    end

    {:ok, state}
  end

  defp handle_command(state, %{"type" => "ping"}) do
    send_json(%{type: "pong"})
    {:ok, state}
  end

  defp handle_command(state, %{"type" => "debug"}) do
    send_json(%{type: "debug", message: "debug command received"})
    {:ok, state}
  end

  defp handle_command(state, %{"type" => "abort"} = cmd) do
    session_id = cmd["session_id"]

    case resolve_session(state, session_id) do
      {:ok, pid, _resolved_id} ->
        CodingAgent.Session.abort(pid)

      :error ->
        send_not_found_error(session_id)
    end

    {:ok, state}
  end

  defp handle_command(state, %{"type" => "reset"} = cmd) do
    session_id = cmd["session_id"]

    case resolve_session(state, session_id) do
      {:ok, pid, _resolved_id} ->
        _ = CodingAgent.Session.reset(pid)

      :error ->
        send_not_found_error(session_id)
    end

    {:ok, state}
  end

  defp handle_command(state, %{"type" => "save"} = cmd) do
    session_id = cmd["session_id"]

    case resolve_session(state, session_id) do
      {:ok, pid, resolved_id} ->
        case CodingAgent.Session.save(pid) do
          :ok ->
            sess_state = CodingAgent.Session.get_state(pid)
            send_json(%{type: "save_result", ok: true, path: sess_state.session_file, session_id: resolved_id})

          {:error, reason} ->
            send_json(%{type: "save_result", ok: false, error: inspect(reason), session_id: resolved_id})
        end

      :error ->
        send_not_found_error(session_id)
    end

    {:ok, state}
  end

  defp handle_command(state, %{"type" => "list_sessions"}) do
    # List persisted sessions on disk (existing behavior)
    case CodingAgent.SessionManager.list_sessions(state.cwd) do
      {:ok, sessions} ->
        send_json(%{type: "sessions_list", sessions: sessions})

      {:error, reason} ->
        send_json(%{type: "sessions_list", sessions: [], error: inspect(reason)})
    end

    {:ok, state}
  end

  defp handle_command(state, %{"type" => "list_models"}) do
    providers =
      Ai.Models.get_providers()
      |> Enum.map(fn provider ->
        models =
          provider
          |> Ai.Models.get_models()
          |> Enum.sort_by(& &1.id)
          |> Enum.map(fn model ->
            %{id: model.id, name: model.name}
          end)

        %{id: Atom.to_string(provider), models: models}
      end)
      |> Enum.sort_by(& &1.id)

    send_json(%{type: "models_list", providers: providers})
    {:ok, state}
  end

  defp handle_command(state, %{"type" => "list_running_sessions"}) do
    # List currently running sessions
    sessions =
      state.sessions
      |> Enum.map(fn {session_id, pid} ->
        try do
          stats = CodingAgent.Session.get_stats(pid)
          %{
            session_id: session_id,
            cwd: stats.cwd,
            is_streaming: stats.is_streaming
          }
        rescue
          _ -> nil
        catch
          :exit, _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    send_json(%{type: "running_sessions", sessions: sessions, error: nil})
    {:ok, state}
  end

  defp handle_command(state, %{"type" => "start_session"} = cmd) do
    # Start a new session
    cwd = cmd["cwd"] || state.cwd
    model_spec = cmd["model"]
    system_prompt = cmd["system_prompt"]
    session_file = cmd["session_file"]
    parent_session = cmd["parent_session"]

    # Resolve model
    model_result =
      if model_spec do
        try do
          {:ok, resolve_model(model_spec, state.settings)}
        rescue
          error -> {:error, "invalid model: #{Exception.message(error)}"}
        end
      else
        {:ok, state.model}
      end

    case model_result do
      {:error, message} ->
        send_json(%{type: "error", message: message})
        {:ok, state}

      {:ok, model} ->
        # Build session options
        opts = [
          cwd: cwd,
          model: model,
          ui_context: state.ui_context,
          register: true
        ]

        opts = if system_prompt, do: Keyword.put(opts, :system_prompt, system_prompt), else: opts
        opts = if session_file, do: Keyword.put(opts, :session_file, session_file), else: opts
        opts = if parent_session, do: Keyword.put(opts, :parent_session, parent_session), else: opts

        case start_session_process(opts) do
          {:ok, pid} ->
            # Get session_id
            stats = CodingAgent.Session.get_stats(pid)
            new_session_id = stats.session_id

            # Start event forwarder
            forwarder_pid = start_session_forwarder(new_session_id, pid, self())

            # Monitor the process
            Process.monitor(pid)

            # Update state
            new_state = %{state |
              sessions: Map.put(state.sessions, new_session_id, pid),
              pid_to_session: Map.put(state.pid_to_session, pid, new_session_id),
              forwarders: Map.put(state.forwarders, new_session_id, forwarder_pid)
            }

            # If there is no active session, make this one active
            new_state =
              if is_nil(state.active_session_id) do
                send_json(%{type: "active_session", session_id: new_session_id})
                %{new_state | active_session_id: new_session_id}
              else
                new_state
              end

            send_json(%{
              type: "session_started",
              session_id: new_session_id,
              cwd: cwd,
              model: %{provider: model.provider, id: model.id}
            })

            debug_log("session_started", %{session_id: new_session_id, cwd: cwd})
            {:ok, new_state}

          {:error, reason} ->
            send_json(%{type: "error", message: "failed to start session: #{inspect(reason)}"})
            {:ok, state}
        end
    end
  end

  defp handle_command(state, %{"type" => "close_session", "session_id" => session_id}) do
    case Map.get(state.sessions, session_id) do
      nil ->
        send_json(%{type: "session_closed", session_id: session_id, reason: "not_found"})
        {:ok, state}

      pid ->
        case stop_session_process(pid) do
          :ok ->
            # State update will happen in :DOWN handler
            {:ok, state}

          {:error, reason} ->
            send_json(%{type: "error", message: "failed to close session: #{inspect(reason)}", session_id: session_id})
            {:ok, state}
        end
    end
  end

  defp handle_command(state, %{"type" => "close_session"}) do
    send_json(%{type: "error", message: "session_id required for close_session"})
    {:ok, state}
  end

  defp handle_command(state, %{"type" => "set_active_session", "session_id" => session_id}) do
    if Map.has_key?(state.sessions, session_id) do
      new_state = %{state | active_session_id: session_id}
      send_json(%{type: "active_session", session_id: session_id})
      {:ok, new_state}
    else
      send_json(%{type: "error", message: "session not found", session_id: session_id})
      {:ok, state}
    end
  end

  defp handle_command(state, %{"type" => "set_active_session"}) do
    send_json(%{type: "error", message: "session_id required for set_active_session"})
    {:ok, state}
  end

  defp handle_command(state, %{"type" => "quit"}) do
    {:quit, state}
  end

  defp handle_command(state, %{"type" => "ui_response"} = response) do
    # Route ui_response to the DebugRPC UI adapter
    if Process.whereis(CodingAgent.UI.DebugRPC) do
      CodingAgent.UI.DebugRPC.handle_response(response)
    else
      debug_log("ui_response ignored", %{reason: "UI not enabled"})
    end

    {:ok, state}
  end

  defp handle_command(state, %{"type" => "get_config"}) do
    send_config_state()
    {:ok, state}
  end

  defp handle_command(state, %{"type" => "set_config", "key" => key, "value" => value}) do
    case key do
      "claude_skip_permissions" ->
        current_config = Application.get_env(:agent_core, :claude, [])
        new_config = Keyword.put(current_config, :dangerously_skip_permissions, value == true)
        Application.put_env(:agent_core, :claude, new_config)
        debug_log("config_updated", %{key: key, value: value})
        send_config_state()

      "codex_auto_approve" ->
        current_config = Application.get_env(:agent_core, :codex, [])
        new_config = Keyword.put(current_config, :auto_approve, value == true)
        Application.put_env(:agent_core, :codex, new_config)
        debug_log("config_updated", %{key: key, value: value})
        send_config_state()

      _ ->
        send_json(%{type: "error", message: "unknown config key: #{key}"})
    end

    {:ok, state}
  end

  defp handle_command(state, _cmd) do
    send_json(%{type: "error", message: "unknown command"})
    {:ok, state}
  end

  defp send_config_state do
    claude_config = Application.get_env(:agent_core, :claude, [])
    codex_config = Application.get_env(:agent_core, :codex, [])

    claude_skip = Keyword.get(claude_config, :dangerously_skip_permissions, false) ||
                  Keyword.get(claude_config, :yolo, false)
    codex_auto = Keyword.get(codex_config, :auto_approve, false)

    send_json(%{
      type: "config_state",
      config: %{
        claude_skip_permissions: claude_skip,
        codex_auto_approve: codex_auto
      }
    })
  end

  # ============================================================================
  # Event Sequence Helpers
  # ============================================================================

  # Get the next monotonic event sequence number for a session.
  # Returns {seq, updated_map} where seq is the current count (starting at 0).
  defp next_event_seq(event_seqs, session_id) do
    current = Map.get(event_seqs, session_id, 0)
    {current, Map.put(event_seqs, session_id, current + 1)}
  end

  # ============================================================================
  # Session Process Helpers
  # ============================================================================

  defp start_session_process(opts) do
    case CodingAgent.start_supervised_session(opts) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_started} ->
        CodingAgent.Session.start_link(opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_session_process(pid) when is_pid(pid) do
    if Process.whereis(CodingAgent.SessionSupervisor) do
      case CodingAgent.SessionSupervisor.stop_session(pid) do
        :ok -> :ok
        {:error, _} -> GenServer.stop(pid, :normal)
      end
    else
      GenServer.stop(pid, :normal)
    end
  end

  defp start_session_forwarder(session_id, session_pid, parent) do
    spawn(fn ->
      unsubscribe = CodingAgent.Session.subscribe(session_pid)
      session_ref = Process.monitor(session_pid)
      parent_ref = Process.monitor(parent)

      receive_loop = fn receive_loop ->
        receive do
          {:session_event, ^session_id, event} ->
            send(parent, {:session_event, session_id, event})
            receive_loop.(receive_loop)

          {:session_event, event} ->
            send(parent, {:session_event, session_id, event})
            receive_loop.(receive_loop)

          {:DOWN, ^session_ref, :process, _pid, _reason} ->
            unsubscribe.()
            :ok

          {:DOWN, ^parent_ref, :process, _pid, _reason} ->
            unsubscribe.()
            :ok

          :stop_forwarder ->
            unsubscribe.()
            :ok

          _ ->
            receive_loop.(receive_loop)
        end
      end

      receive_loop.(receive_loop)
    end)
  end

  # ============================================================================
  # Session Resolution Helpers
  # ============================================================================

  defp resolve_session(state, nil) do
    get_active_session(state)
  end

  defp resolve_session(state, session_id) do
    case Map.get(state.sessions, session_id) do
      nil -> :error
      pid -> {:ok, pid, session_id}
    end
  end

  defp get_active_session(state) do
    case state.active_session_id do
      nil -> :error
      id ->
        case Map.get(state.sessions, id) do
          nil -> :error
          pid -> {:ok, pid, id}
        end
    end
  end

  defp get_session_pid(state, session_id) do
    case Map.get(state.sessions, session_id) do
      nil -> :error
      pid -> {:ok, pid}
    end
  end

  defp send_not_found_error(nil) do
    send_json(%{type: "error", message: "no active session"})
  end

  defp send_not_found_error(session_id) do
    send_json(%{type: "error", message: "session not found", session_id: session_id})
  end

  # ============================================================================
  # Input Reading
  # ============================================================================

  defp read_input_loop(parent) do
    # Use :file.read_line(:standard_io) instead of IO.read for compatibility
    # with piped stdin in mix run scripts
    case :file.read_line(:standard_io) do
      {:ok, line} ->
        trimmed = String.trim_trailing(line, "\n")
        send(parent, {:stdin, trimmed})
        read_input_loop(parent)

      :eof ->
        send(parent, {:stdin, :eof})

      {:error, reason} ->
        IO.puts(:stderr, "[debug] stdin error: #{inspect(reason)}")
        send(parent, {:stdin, :eof})
    end
  end

  defp schedule_stats(session_id) do
    if Process.get(:debug, false) do
      ref = make_ref()
      Process.send_after(self(), {:debug_stats, ref, session_id}, 2_000)
      ref
    else
      nil
    end
  end

  # ============================================================================
  # Logging and Encoding
  # ============================================================================

  defp debug_log(label, payload) do
    if Process.get(:debug, false) do
      IO.puts(:stderr, "[debug] #{label}: #{inspect(payload)}")
    end
  end

  defp event_type(event) when is_tuple(event) do
    case Tuple.to_list(event) do
      [tag | _rest] -> tag
      _ -> :unknown
    end
  end

  defp event_type(_), do: :unknown

  defp resolve_model(nil, settings) do
    case settings.default_model do
      nil ->
        raise "No default model configured. Set ~/.lemon/agent/settings.json or pass --model provider:model_id"

      %{provider: provider, model_id: model_id} ->
        if provider do
          get_model(provider, model_id)
        else
          case Ai.Models.find_by_id(model_id) do
            nil -> raise "Unknown model #{inspect(model_id)}"
            model -> model
          end
        end
    end
  end

  defp resolve_model(model_spec, _settings) when is_binary(model_spec) do
    case String.split(model_spec, ":", parts: 2) do
      [provider, model_id] -> get_model(provider, model_id)
      _ -> raise "Invalid --model format. Expected provider:model_id"
    end
  end

  defp get_model(provider, model_id) do
    provider_atom =
      try do
        String.to_existing_atom(provider)
      rescue
        ArgumentError -> String.to_atom(provider)
      end

    case Ai.Models.get_model(provider_atom, model_id) do
      nil -> raise "Unknown model #{inspect(model_id)} for provider #{inspect(provider)}"
      model -> model
    end
  end

  defp maybe_override_base_url(model, cli_base_url, settings) do
    base_url =
      cond do
        is_binary(cli_base_url) and cli_base_url != "" ->
          cli_base_url

        is_map(settings.providers) ->
          provider_key =
            case model.provider do
              p when is_atom(p) -> Atom.to_string(p)
              p when is_binary(p) -> p
              _ -> nil
            end

          provider_cfg = provider_key && Map.get(settings.providers, provider_key)
          provider_cfg && Map.get(provider_cfg, :base_url)

        true ->
          nil
      end

    if is_binary(base_url) and base_url != "" do
      %{model | base_url: base_url}
    else
      model
    end
  end

  defp encode_event(event) when is_tuple(event) do
    case Tuple.to_list(event) do
      [tag] ->
        %{type: atom_to_string(tag)}

      [tag | rest] ->
        %{type: atom_to_string(tag), data: Enum.map(rest, &jsonable/1)}
    end
  end

  defp encode_event(event), do: jsonable(event)

  defp jsonable(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> Map.put("__struct__", atom_to_string(struct.__struct__))
    |> jsonable()
  end

  defp jsonable(term) when is_map(term) do
    term
    |> Map.new(fn {k, v} -> {json_key(k), jsonable(v)} end)
  end

  defp jsonable(term) when is_list(term), do: Enum.map(term, &jsonable/1)
  defp jsonable(term) when is_tuple(term), do: Enum.map(Tuple.to_list(term), &jsonable/1)
  defp jsonable(term) when is_boolean(term), do: term
  defp jsonable(nil), do: nil
  defp jsonable(term) when is_atom(term), do: atom_to_string(term)

  defp jsonable(term) when is_function(term), do: "<function>"
  defp jsonable(term) when is_reference(term), do: inspect(term)
  defp jsonable(term), do: term

  defp json_key(k) when is_atom(k), do: atom_to_string(k)
  defp json_key(k) when is_binary(k), do: k
  defp json_key(k), do: inspect(k)

  defp atom_to_string(atom) when is_atom(atom), do: Atom.to_string(atom)

  defp send_json(payload) do
    payload
    |> Jason.encode!()
    |> IO.puts()
  end
end

DebugAgentRPC.run(System.argv())
