# Simple smoke test: prompt the agent and print the assistant response.

Application.ensure_all_started(:ai)
Application.ensure_all_started(:agent_core)
Application.ensure_all_started(:coding_agent)
Application.ensure_all_started(:coding_agent_ui)

defmodule HelloKimi do
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [cwd: :string, model: :string, base_url: :string, timeout: :integer, debug: :boolean]
      )

    cwd = opts[:cwd] || File.cwd!()
    timeout = opts[:timeout] || 120_000
    debug = opts[:debug] == true

    settings = CodingAgent.SettingsManager.load(cwd)
    model = resolve_model(opts[:model], settings)
    model = maybe_override_base_url(model, opts[:base_url], settings)

    if debug do
      IO.puts(:stderr, "[debug] argv=#{inspect(System.argv())}")
      IO.puts(:stderr, "[debug] model=#{inspect(%{provider: model.provider, id: model.id, base_url: model.base_url})}")
    end

    {:ok, session} =
      CodingAgent.Session.start_link(
        cwd: cwd,
        model: model,
        ui_context: nil
      )

    _unsub = CodingAgent.Session.subscribe(session)

    :ok = CodingAgent.Session.prompt(session, "hello")

    case wait_for_response(timeout, debug) do
      {:ok, %Ai.Types.AssistantMessage{} = msg} ->
        text = Ai.get_text(msg)
        IO.puts(text)

      {:error, {:empty_response, %Ai.Types.AssistantMessage{} = msg}} ->
        IO.puts(:stderr, "empty response (stop_reason=#{inspect(msg.stop_reason)})")
        IO.puts(:stderr, "assistant_content=#{inspect(msg.content)}")
        if is_binary(msg.error_message) and msg.error_message != "" do
          IO.puts(:stderr, "error_message: #{msg.error_message}")
        end
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "error: #{inspect(reason)}")
        System.halt(1)
    end
  end

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

    if is_binary(base_url) and base_url != "" and base_url != model.base_url do
      %{model | base_url: base_url}
    else
      model
    end
  end

  defp wait_for_response(timeout, debug) do
    receive do
      {:session_event, {:message_end, %Ai.Types.AssistantMessage{} = msg}} ->
        text = Ai.get_text(msg)
        tool_calls = Ai.get_tool_calls(msg)

        if debug do
          IO.puts(:stderr, "[debug] message_end stop_reason=#{inspect(msg.stop_reason)} text_len=#{String.length(text)} tool_calls=#{length(tool_calls)}")
        end

        cond do
          String.trim(text) != "" ->
            {:ok, msg}

          tool_calls != [] or msg.stop_reason == :tool_use ->
            if debug do
              IO.puts(:stderr, "[debug] empty assistant message with tool calls; waiting for next response")
            end
            wait_for_response(timeout, debug)

          true ->
            {:error, {:empty_response, msg}}
        end

      {:session_event, {:error, reason, _partial}} ->
        if debug do
          IO.puts(:stderr, "[debug] error event=#{inspect(reason)}")
        end
        {:error, reason}

      {:session_event, {:agent_end, _messages}} ->
        if debug do
          IO.puts(:stderr, "[debug] agent_end without assistant message")
        end
        {:error, :no_assistant_message}
      {:session_event, event} ->
        if debug do
          IO.puts(:stderr, "[debug] event=#{inspect(event)}")
        end
        wait_for_response(timeout, debug)
    after
      timeout ->
        {:error, :timeout}
    end
  end
end

HelloKimi.run(System.argv())
