defmodule CodingAgent.Security.SecretObfuscationSessionTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager, SettingsManager}
  alias LemonAgent.Types.{AgentTool, AgentToolResult}

  alias LemonAi.Types.{
    AssistantMessage,
    Model,
    ModelCost,
    TextContent,
    ToolCall,
    ToolResultMessage,
    Usage,
    UserMessage
  }

  @env_name "LEMON_OBF_SESSION_TEST_TOKEN"

  # Summarization calls LemonAi.complete outside the agent loop's transform.
  defmodule SummaryProvider do
    def stream(_model, context, _opts) do
      send(:secret_obfuscation_session_test, {:summary_request, context})

      response = %AssistantMessage{
        content: [%TextContent{text: "summary"}],
        stop_reason: :stop
      }

      {:ok, stream} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.complete(stream, response)
      {:ok, stream}
    end
  end

  setup_all do
    LemonAi.ProviderRegistry.register(:secret_obfuscation_summary, SummaryProvider)
    on_exit(fn -> LemonAi.ProviderRegistry.unregister(:secret_obfuscation_summary) end)
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "secret-obf-session-#{System.unique_integer([:positive])}")

    agent_dir = Path.join(root, "agent")
    File.mkdir_p!(agent_dir)
    secret = "s3cret-#{System.unique_integer([:positive])}-value"
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")
    System.put_env("LEMON_AGENT_DIR", agent_dir)
    System.put_env(@env_name, secret)

    on_exit(fn ->
      System.delete_env(@env_name)

      if previous_agent_dir,
        do: System.put_env("LEMON_AGENT_DIR", previous_agent_dir),
        else: System.delete_env("LEMON_AGENT_DIR")

      File.rm_rf!(SessionManager.get_session_dir(root))
      File.rm_rf!(root)
    end)

    %{root: root, secret: secret}
  end

  test "provider sees placeholders, tools get real values, history keeps originals",
       %{root: root, secret: secret} do
    test_pid = self()
    calls = :counters.new(1, [:atomics])

    echo = %AgentTool{
      name: "echo",
      label: "Echo",
      description: "Echo a value",
      parameters: %{"type" => "object", "properties" => %{"value" => %{"type" => "string"}}},
      execute: fn _id, params, _signal, _on_update ->
        send(test_pid, {:tool_params, params})
        %AgentToolResult{content: [%TextContent{text: "echoed #{params["value"]}"}]}
      end
    }

    stream = fn _model, context, _opts ->
      :counters.add(calls, 1, 1)
      send(test_pid, {:provider_context, context})

      message =
        case :counters.get(calls, 1) do
          1 ->
            [placeholder] = Regex.run(~r/\$\$[A-Z0-9_]+(?::[ULCM])?\$\$/, user_text(context))
            call = %ToolCall{id: "c1", name: "echo", arguments: %{"value" => placeholder}}
            response([call], :tool_use)

          _ ->
            response([%TextContent{text: "done"}], :stop)
        end

      {:ok, events(message)}
    end

    settings = %{SettingsManager.load(root) | secret_obfuscation_enabled: true}

    session =
      start_supervised!(
        {Session,
         [cwd: root, model: model(), stream_fn: stream, tools: [echo], settings_manager: settings]}
      )

    Session.subscribe(session)
    assert :ok = Session.prompt(session, "deploy with #{secret}")
    assert_receive {:session_event, _, {:agent_end, _}}, 5_000

    assert_receive {:provider_context, first}
    refute inspect(first, limit: :infinity, printable_limit: :infinity) =~ secret
    assert_receive {:tool_params, %{"value" => ^secret}}
    assert_receive {:provider_context, second}
    refute inspect(second, limit: :infinity, printable_limit: :infinity) =~ secret
    assert Enum.any?(second.messages, &match?(%ToolResultMessage{}, &1))

    history = Session.get_messages(session)
    assert Enum.any?(history, &match?(%UserMessage{content: "deploy with " <> ^secret}, &1))

    assert Enum.any?(history, fn
             %ToolResultMessage{content: [%TextContent{text: text}]} -> text == "echoed #{secret}"
             _ -> false
           end)

    # Compaction summarizes the raw history; the summary request is obfuscated too.
    Process.register(self(), :secret_obfuscation_session_test)
    assert :ok = Session.compact(session, keep_recent_tokens: 1)
    assert_receive {:summary_request, summary_context}
    refute inspect(summary_context, limit: :infinity, printable_limit: :infinity) =~ secret
  end

  defp user_text(context) do
    Enum.find_value(context.messages, fn
      %UserMessage{content: text} when is_binary(text) -> text
      _ -> nil
    end)
  end

  defp model,
    do: %Model{
      id: "obf-test",
      name: "Obfuscation Test",
      api: :secret_obfuscation_summary,
      provider: :mock_provider,
      base_url: "https://invalid.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{},
      context_window: 128_000,
      max_tokens: 4096
    }

  defp response(content, reason),
    do: %AssistantMessage{
      content: content,
      api: :mock,
      provider: :mock_provider,
      model: "obf-test",
      usage: %Usage{},
      stop_reason: reason,
      timestamp: System.system_time(:millisecond)
    }

  defp events(message) do
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, message})
      LemonAi.EventStream.push(stream, {:done, message.stop_reason, message})
      LemonAi.EventStream.complete(stream, message)
    end)

    stream
  end
end
