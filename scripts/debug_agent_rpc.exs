# Ensure apps are started
Application.ensure_all_started(:ai)
Application.ensure_all_started(:agent_core)
Application.ensure_all_started(:coding_agent)
Application.ensure_all_started(:coding_agent_ui)


defmodule DebugAgentRPC do
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

    {:ok, session} =
      CodingAgent.Session.start_link(
        cwd: cwd,
        model: model,
        system_prompt: opts[:system_prompt],
        session_file: opts[:session_file],
        ui_context: ui_context
      )

    _unsub = CodingAgent.Session.subscribe(session)

    send_json(%{
      type: "ready",
      cwd: cwd,
      model: %{provider: model.provider, id: model.id},
      debug: debug_enabled,
      ui: ui_enabled
    })
    debug_log("ready_sent", %{cwd: cwd})

    parent = self()
    Task.start(fn -> read_input_loop(parent) end)
    if Process.get(:debug, false) do
      send_json(%{type: "debug", message: "debug mode enabled", argv: System.argv()})
    end
    loop(session, cwd)
  end

  defp loop(session, cwd) do
    receive do
      {:session_event, event} ->
        debug_log("session_event", %{type: event_type(event)})
        send_json(%{type: "event", event: encode_event(event)})
        loop(session, cwd)

      {:stdin, :eof} ->
        send_json(%{type: "error", message: "stdin closed"})
        :ok

      {:stdin, line} ->
        case handle_line(session, cwd, line) do
          :quit ->
            send_json(%{type: "event", event: %{type: "quit"}})
            :ok

          :ok ->
            loop(session, cwd)
        end

      {:debug_stats, _ref} ->
        stats = CodingAgent.Session.get_stats(session)
        send_json(%{type: "stats", stats: stats})
        loop(session, cwd)

    end
  end

  defp handle_line(session, cwd, line) when is_binary(line) do
    trimmed = String.trim(line)

    if trimmed == "" do
      :ok
    else
      debug_log("stdin", %{line: trimmed})

      case Jason.decode(trimmed) do
        {:ok, %{"type" => "prompt", "text" => text}} ->
          result = CodingAgent.Session.prompt(session, text)
          debug_log("prompt", %{text: text, result: result})

          case result do
            :ok ->
              schedule_stats()
              :ok

            {:error, reason} ->
              send_json(%{type: "error", message: inspect(reason)})
              :ok
          end

          :ok

        {:ok, %{"type" => "stats"}} ->
          stats = CodingAgent.Session.get_stats(session)
          send_json(%{type: "stats", stats: stats})
          :ok

        {:ok, %{"type" => "ping"}} ->
          send_json(%{type: "pong"})
          :ok

        {:ok, %{"type" => "debug"}} ->
          send_json(%{type: "debug", message: "debug command received"})
          :ok

        {:ok, %{"type" => "abort"}} ->
          CodingAgent.Session.abort(session)
          :ok

        {:ok, %{"type" => "reset"}} ->
          _ = CodingAgent.Session.reset(session)
          :ok

        {:ok, %{"type" => "save"}} ->
          case CodingAgent.Session.save(session) do
            :ok ->
              state = CodingAgent.Session.get_state(session)
              send_json(%{type: "save_result", ok: true, path: state.session_file})

            {:error, reason} ->
              send_json(%{type: "save_result", ok: false, error: inspect(reason)})
          end
          :ok

        {:ok, %{"type" => "list_sessions"}} ->
          case CodingAgent.SessionManager.list_sessions(cwd) do
            {:ok, sessions} ->
              send_json(%{type: "sessions_list", sessions: sessions})

            {:error, reason} ->
              send_json(%{type: "sessions_list", sessions: [], error: inspect(reason)})
          end
          :ok

        {:ok, %{"type" => "quit"}} ->
          :quit

        {:ok, %{"type" => "ui_response"} = response} ->
          # Route ui_response to the DebugRPC UI adapter
          if Process.whereis(CodingAgent.UI.DebugRPC) do
            CodingAgent.UI.DebugRPC.handle_response(response)
          else
            debug_log("ui_response ignored", %{reason: "UI not enabled"})
          end
          :ok

        {:ok, _other} ->
          send_json(%{type: "error", message: "unknown command"})
          :ok

        {:error, _} ->
          case CodingAgent.Session.prompt(session, trimmed) do
            :ok -> :ok
            {:error, reason} -> send_json(%{type: "error", message: inspect(reason)})
          end

          :ok
      end
    end
  end

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

  defp schedule_stats do
    if Process.get(:debug, false) do
      ref = make_ref()
      Process.send_after(self(), {:debug_stats, ref}, 2_000)
      ref
    else
      nil
    end
  end


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
