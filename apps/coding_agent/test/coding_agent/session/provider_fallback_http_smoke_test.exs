defmodule CodingAgent.Session.ProviderFallbackHttpSmokeTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SettingsManager}
  alias LemonAi.Types.{AssistantMessage, TextContent}
  alias LemonAgent.ModelRuntime.{CredentialHealth, SessionPins}

  @moduletag :tmp_dir

  test "real coding session falls back to another model against a loopback HTTP endpoint", %{
    tmp_dir: tmp_dir
  } do
    previous_retry = Application.get_env(:lemon_ai, :provider_retry)
    Application.put_env(:lemon_ai, :provider_retry, max_attempts: 1)
    CredentialHealth.reset()
    SessionPins.reset()

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, ip: {127, 0, 0, 1}])

    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    parent = self()
    server = spawn_link(fn -> serve(listener, parent) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(server, :normal)
      CredentialHealth.reset()
      SessionPins.reset()

      if previous_retry do
        Application.put_env(:lemon_ai, :provider_retry, previous_retry)
      else
        Application.delete_env(:lemon_ai, :provider_retry)
      end
    end)

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

    session =
      start_supervised!(
        {Session,
         cwd: tmp_dir,
         workspace_dir: Path.join(tmp_dir, "workspace"),
         session_file: Path.join(tmp_dir, "session.jsonl"),
         settings_manager: settings,
         model: "openai:gpt-4",
         system_prompt: "Reply briefly without tools.",
         tools: [],
         thinking_level: :off}
      )

    unsubscribe = Session.subscribe(session)
    assert :ok = Session.prompt(session, "Prove model fallback works.")
    assert_receive {:http_attempt, "gpt-4"}, 10_000
    assert_receive {:http_attempt, "gpt-4o-mini"}, 10_000
    messages = await_completion(System.monotonic_time(:millisecond) + 10_000)

    assert [%AssistantMessage{model: "gpt-4o-mini", content: content}] =
             Enum.filter(messages, &match?(%AssistantMessage{}, &1))

    assert [%TextContent{text: "Fallback endpoint answered."}] = content
    assert File.regular?(Path.join(tmp_dir, "session.jsonl"))
    refute_receive {:http_attempt, _}, 100
    unsubscribe.()
  end

  defp await_completion(deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:session_event, _id, {:agent_end, messages}} -> messages
      {:session_event, _id, {:error, reason, _partial}} -> flunk("session failed: #{inspect(reason)}")
      {:session_event, _id, _event} -> await_completion(deadline)
    after
      remaining -> flunk("session did not complete")
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
