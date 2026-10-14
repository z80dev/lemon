# Run manually, outside CI: MIX_ENV=test mix run --no-start scripts/provider_fallback_smoke.exs
# Uses only fixture credentials and a loopback endpoint; no live provider login.
defmodule LemonScripts.ProviderFallbackSmoke do
  alias CodingAgent.{Session, SettingsManager}
  alias LemonAi.Types.{AssistantMessage, TextContent}

  def main do
    root = Path.join(System.tmp_dir!(), "lemon-fallback-smoke-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    home = Path.join(root, "home")
    cwd = Path.join(root, "project")
    File.mkdir!(home)
    File.mkdir!(cwd)
    System.put_env("HOME", home)
    System.put_env("LEMON_STORE_PATH", Path.join(root, "store"))
    System.put_env("LEMON_SECRETS_MASTER_KEY", Base.encode64(:crypto.strong_rand_bytes(32)))

    # Remove ambient credentials without reading or logging their values.
    Enum.each(
      ~w(OPENAI_API_KEY ANTHROPIC_API_KEY OPENAI_CODEX_API_KEY CHATGPT_TOKEN
         AZURE_OPENAI_API_KEY GOOGLE_API_KEY GOOGLE_GENERATIVE_AI_API_KEY),
      &System.delete_env/1
    )

    try do
      {:ok, _} = Application.ensure_all_started(:coding_agent)
      Application.put_env(:lemon_ai, :provider_retry, max_attempts: 1)
      run(cwd)
    after
      File.rm_rf!(root)
    end
  end

  defp run(cwd) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    parent = self()
    spawn_link(fn -> serve(listener, parent) end)

    settings = %SettingsManager{
      default_thinking_level: :off,
      providers: %{
        "openai" => %{api_key: "fixture-only-key", base_url: "http://127.0.0.1:#{port}/v1"}
      },
      provider_routing: %{
        enabled: true,
        fallback_models: ["openai:gpt-4o-mini"],
        fallback_providers: [],
        require_credentials: true
      },
      compaction_enabled: false,
      retry_enabled: false
    }

    try do
      {:ok, session} =
        Session.start_link(
          cwd: cwd,
          workspace_dir: Path.join(cwd, "workspace"),
          session_file: Path.join(cwd, "session.jsonl"),
          settings_manager: settings,
          model: "openai:gpt-4",
          system_prompt: "Reply briefly without tools.",
          tools: [],
          thinking_level: :off
        )

      try do
        unsubscribe = Session.subscribe(session)
        :ok = Session.prompt(session, "Prove model fallback works.")
        {messages, ["gpt-4", "gpt-4o-mini"] = attempts} =
          await_completion(System.monotonic_time(:millisecond) + 10_000, [])

        [%AssistantMessage{model: "gpt-4o-mini", content: content}] =
          Enum.filter(messages, &match?(%AssistantMessage{}, &1))

        [%TextContent{text: "Fallback endpoint answered."}] = content
        true = File.regular?(Path.join(cwd, "session.jsonl"))
        unsubscribe.()
        IO.puts(Jason.encode!(%{
          status: "passed",
          attempts: attempts,
          final_model: "gpt-4o-mini",
          fallback_fired: true,
          session_persisted: true
        }))
      after
        GenServer.stop(session)
      end
    after
      :gen_tcp.close(listener)
    end
  end

  defp await_completion(deadline, attempts) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:http_attempt, model} -> await_completion(deadline, attempts ++ [model])
      {:session_event, _id, {:agent_end, messages}} -> {messages, attempts}
      {:session_event, _id, {:error, reason, _partial}} ->
        raise "fixture session failed: #{inspect(reason)}"
      {:session_event, _id, _event} -> await_completion(deadline, attempts)
    after
      remaining -> raise "fixture session did not complete"
    end
  end

  defp serve(listener, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        {headers, body} = receive_headers(socket, "")
        length = headers |> String.downcase() |> content_length()
        body = receive_body(socket, body, length)
        %{"model" => model} = Jason.decode!(body)
        send(parent, {:http_attempt, model})
        {status, content_type, response} = response(model)

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 ", status, "\r\ncontent-type: ", content_type,
            "\r\ncontent-length: ", Integer.to_string(byte_size(response)),
            "\r\nconnection: close\r\n\r\n", response
          ])

        :gen_tcp.close(socket)
        serve(listener, parent)

      {:error, :closed} ->
        :ok
    end
  end

  defp receive_headers(socket, buffer) do
    case :binary.split(buffer, "\r\n\r\n") do
      [headers, body] -> {headers, body}
      [_] ->
        {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
        receive_headers(socket, buffer <> bytes)
    end
  end

  defp content_length(headers) do
    [_, length] = Regex.run(~r/\r\ncontent-length:\s*(\d+)/, headers)
    String.to_integer(length)
  end

  defp receive_body(_socket, body, length) when byte_size(body) >= length,
    do: binary_part(body, 0, length)

  defp receive_body(socket, body, length) do
    {:ok, bytes} = :gen_tcp.recv(socket, 0, 5_000)
    receive_body(socket, body <> bytes, length)
  end

  defp response("gpt-4") do
    {"503 Service Unavailable", "application/json",
     Jason.encode!(%{"error" => %{"type" => "overloaded_error", "message" => "overloaded"}})}
  end

  defp response("gpt-4o-mini") do
    events = [
      %{"id" => "fixture", "model" => "gpt-4o-mini", "choices" => [
        %{"index" => 0, "delta" => %{"role" => "assistant", "content" => "Fallback endpoint answered."}, "finish_reason" => nil}
      ]},
      %{"id" => "fixture", "model" => "gpt-4o-mini", "choices" => [
        %{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}
      ], "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 5, "total_tokens" => 10}}
    ]

    body = Enum.map_join(events, "", &("data: " <> Jason.encode!(&1) <> "\n\n"))
    {"200 OK", "text/event-stream", body <> "data: [DONE]\n\n"}
  end
end

LemonScripts.ProviderFallbackSmoke.main()
