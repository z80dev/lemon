defmodule CodingAgent.Session.AutoThinkingTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager, SettingsManager}
  alias CodingAgent.Session.ModelResolver
  alias LemonAgent.Types.{AgentTool, AgentToolResult}

  alias LemonAi.Types.{
    AssistantMessage,
    StreamOptions,
    TextContent,
    ThinkingContent,
    ToolCall,
    Usage,
    UserMessage
  }

  @env_keys ~w(HOME LEMON_AGENT_DIR LEMON_DEFAULT_PROVIDER LEMON_DEFAULT_MODEL LEMON_DEFAULT_THINKING_LEVEL OPENAI_API_KEY ANTHROPIC_API_KEY LEMON_FEATURE_SESSION_SEARCH)

  setup do
    root =
      Path.join(System.tmp_dir!(), "session-auto-thinking-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, ".lemon"))
    saved_env = Map.new(@env_keys, &{&1, System.get_env(&1)})
    saved_paths = Application.get_env(:lemon_core, :paths)
    previous_req_options = Req.default_options()
    {:ok, http_requests} = Agent.start(fn -> [] end)
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(http_requests, &[{conn.host, conn.request_path} | &1])

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, ~s({"error":{"message":"unexpected fixture HTTP request"}}))
    end)

    Enum.each(@env_keys, &System.delete_env/1)
    System.put_env("HOME", root)
    System.put_env("LEMON_AGENT_DIR", Path.join(root, ".lemon/agent"))
    Application.put_env(:lemon_core, :paths, home_dir: root)
    System.put_env("LEMON_FEATURE_SESSION_SEARCH", "off")

    File.write!(Path.join(root, ".lemon/config.toml"), """
    [defaults]
    provider = "anthropic"
    model = "claude-sonnet-4-6"
    thinking_level = "auto"

    [model_roles]
    tiny = "openai:gpt-4o-mini"

    [providers.openai]
    api_key = "synthetic-classifier-key"
    base_url = "https://classifier.invalid/v1"

    [providers.anthropic]
    api_key = "synthetic-primary-key"

    [runtime.provider_routing]
    enabled = false

    [features]
    session_search = "off"
    """)

    on_exit(fn ->
      Req.default_options(previous_req_options)
      Req.Test.set_req_test_to_private(%{})

      Enum.each(saved_env, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)

      if saved_paths,
        do: Application.put_env(:lemon_core, :paths, saved_paths),
        else: Application.delete_env(:lemon_core, :paths)

      File.rm_rf!(root)

      try do
        assert Agent.get(http_requests, & &1) == [],
               "scripted sessions must not call HTTP providers"
      after
        Agent.stop(http_requests)
      end
    end)

    %{cwd: root, settings: SettingsManager.load(root)}
  end

  defp response(model, label) do
    %AssistantMessage{
      model: model.id,
      api: model.api,
      provider: model.provider,
      content: [%TextContent{text: label}],
      stop_reason: :stop,
      usage: %Usage{},
      timestamp: System.system_time(:millisecond)
    }
  end

  defp to_stream(message) do
    {:ok, stream} = LemonAi.EventStream.start_link()
    LemonAi.EventStream.push(stream, {:start, message})
    LemonAi.EventStream.push(stream, {:done, message.stop_reason, message})
    LemonAi.EventStream.complete(stream, message)
    {:ok, stream}
  end

  defp stream_fn(parent) do
    fn model, _context, options ->
      send(parent, {:primary_request, model, options})
      to_stream(response(model, "primary answer"))
    end
  end

  defp start_session(ctx, complete_fn, extra \\ [], id \\ :session) do
    opts = [
      cwd: ctx.cwd,
      workspace_dir: Path.join(ctx.cwd, "workspace"),
      settings_manager: ctx.settings,
      tools: [],
      stream_fn: stream_fn(self()),
      complete_fn: complete_fn,
      register: false
    ]

    session = start_supervised!({Session, Keyword.merge(opts, extra)}, id: id)
    Session.subscribe(session)
    session
  end

  defp await_end(session) do
    id = Session.get_state(session).session_manager.header.id
    assert_receive {:session_event, ^id, {:agent_end, messages}}, 2_000
    assert :ok = LemonAgent.Agent.wait_for_idle(Session.get_state(session).agent, 2_000)
    messages
  end

  test "TOML auto selects per-prompt wire effort and survives save/restore", ctx do
    parent = self()
    calls = :counters.new(1, [:atomics])

    complete_fn = fn model, context, options ->
      :counters.add(calls, 1, 1)
      send(parent, {:classifier_request, model, context, options})
      label = if :counters.get(calls, 1) == 1, do: "low", else: "xhigh"
      message = response(model, label)

      {:ok,
       %{
         message
         | content: [%ThinkingContent{thinking: "classifier-hidden-content"} | message.content]
       }}
    end

    assert ctx.settings.default_thinking_level == :auto
    session = start_session(ctx, complete_fn)
    assert Session.get_state(session).thinking_level == :auto
    assert :ok = Session.prompt(session, "first prompt")
    messages = await_end(session)

    assert_receive {:classifier_request, classifier, context, options}
    assert classifier.provider == :openai
    assert classifier.id == "gpt-4o-mini"
    assert classifier.base_url == "https://classifier.invalid/v1"
    assert options.api_key == "synthetic-classifier-key"
    assert classifier.api == :openai_responses
    assert options.provider_options == %{}
    assert context.tools == []
    assert [%UserMessage{content: "first prompt"}] = context.messages
    assert options.reasoning == nil
    assert options.max_tokens == 4_096
    assert_receive {:primary_request, primary, primary_options}
    assert primary.provider == :anthropic
    assert primary_options.api_key == "synthetic-primary-key"
    assert primary_options.reasoning == :low
    assert Session.get_state(session).thinking_level == :auto
    assert LemonAgent.Agent.get_state(Session.get_state(session).agent).thinking_level == :auto
    refute inspect(messages) =~ "classifier-hidden-content"
    refute inspect(messages) =~ "synthetic-classifier-key"
    assert :ok = Session.save(session)
    file = Session.get_state(session).session_file
    refute File.read!(file) =~ "classifier-hidden-content"
    refute File.read!(file) =~ "synthetic-classifier-key"
    assert :ok = stop_supervised(:session)

    restored_ctx = %{ctx | settings: %{ctx.settings | default_thinking_level: :off}}
    restored = start_session(restored_ctx, complete_fn, [session_file: file], :restored)
    assert Session.get_state(restored).thinking_level == :auto
    assert :ok = Session.prompt(restored, "second prompt")
    await_end(restored)

    assert_receive {:classifier_request, _, %{messages: [%UserMessage{content: "second prompt"}]},
                    _}

    assert_receive {:primary_request, _, %{reasoning: :high}}
    refute_receive {:classifier_request, _, _, _}
    assert Session.get_state(restored).thinking_level == :auto
    assert :ok = Session.save(restored)
    assert {:ok, journal} = SessionManager.load_from_file(file)

    levels =
      for entry <- SessionManager.get_branch(journal),
          entry.type == :thinking_level_change,
          do: entry.thinking_level

    assert levels != []
    assert Enum.all?(levels, &(&1 == :auto))
    assert SessionManager.build_session_context(journal).thinking_level == :auto
    assert :ok = Session.set_thinking_level(restored, "auto")
    assert Session.get_state(restored).thinking_level == :auto
  end

  test "an unconfigured classifier uses supported medium without completing on the primary model",
       ctx do
    parent = self()
    ctx = %{ctx | settings: %{ctx.settings | model_roles: %{}}}

    session =
      start_session(ctx, fn _, _, _ ->
        send(parent, :unexpected_classifier)
        {:error, :unexpected}
      end)

    assert :ok = Session.prompt(session, "request")
    await_end(session)
    assert_receive {:primary_request, _, %{reasoning: :medium}}
    refute_receive :unexpected_classifier
    assert Session.get_state(session).thinking_level == :auto
  end

  test "classifier input excludes attached recall and prior transcript content", ctx do
    parent = self()

    complete_fn = fn model, context, _ ->
      send(parent, {:classified_content, context.messages})
      {:ok, response(model, "high")}
    end

    session = start_session(ctx, complete_fn)
    agent = Session.get_state(session).agent
    original = %UserMessage{content: "actual latest user prompt", timestamp: 1}

    :sys.replace_state(session, fn state ->
      sections = [
        %{title: "Recall", body: "ultrathink about unrelated context", placement: :user_message}
      ]

      send(parent, {:outgoing_prompt, Session.attach_recalled_context(original, sections)})
      state
    end)

    assert_receive {:outgoing_prompt, outgoing}

    assert :ok =
             LemonAgent.Agent.replace_messages(agent, [
               %UserMessage{content: "old ultrathink", timestamp: 0}
             ])

    assert :ok = LemonAgent.Agent.prompt(agent, outgoing)
    await_end(session)
    assert_receive {:classified_content, [%UserMessage{content: "actual latest user prompt"}]}
    assert_receive {:primary_request, _, %{reasoning: :high}}
    refute_receive {:classified_content, _}
  end

  test "a tool-driven provider switch rebuilds credentials and options even when routing is disabled",
       ctx do
    parent = self()
    holder = start_supervised!({Agent, fn -> nil end}, id: :agent_holder)
    calls = :counters.new(1, [:atomics])
    next_model = ModelResolver.resolve_session_model("openai:gpt-5.2", ctx.settings)

    tool = %AgentTool{
      name: "switch_model",
      description: "Switch model",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _, _, _, _ ->
        :ok = LemonAgent.Agent.set_model(Agent.get(holder, & &1), next_model)
        %AgentToolResult{content: [%TextContent{text: "switched"}]}
      end
    }

    complete_fn = fn model, _, _ ->
      send(parent, :classified_once)
      {:ok, response(model, "high")}
    end

    stream = fn model, _, options ->
      :counters.add(calls, 1, 1)
      call = :counters.get(calls, 1)
      send(parent, {:live_request, call, model, options})
      message = response(model, "primary answer")

      message =
        if call == 1 do
          %{
            message
            | content: [%ToolCall{id: "switch", name: "switch_model", arguments: %{}}],
              stop_reason: :tool_use
          }
        else
          message
        end

      to_stream(message)
    end

    original_options = %StreamOptions{
      project: "initial-project",
      location: "initial-location",
      service_account_json: "synthetic-initial-account",
      access_token: "synthetic-initial-token",
      headers: %{"X-Initial-Secret" => "synthetic-header"},
      provider_options: %{anthropic: %{token: "synthetic-provider-option"}},
      thinking_budgets: %{low: 2_048, azure_base_url: "https://initial.invalid"},
      temperature: 0.4,
      max_tokens: 2_048
    }

    session =
      start_session(ctx, complete_fn,
        tools: [tool],
        stream_fn: stream,
        stream_options: original_options
      )

    Agent.update(holder, fn _ -> Session.get_state(session).agent end)
    assert :ok = Session.prompt(session, "switch during the tool turn")
    await_end(session)

    assert_receive :classified_once
    refute_receive :classified_once, 0
    assert_receive {:live_request, 1, %{provider: :anthropic}, initial}
    assert initial.headers == original_options.headers
    assert_receive {:live_request, 2, %{provider: :openai}, destination}
    assert destination.api_key == "synthetic-classifier-key"
    assert destination.reasoning == :high
    assert destination.project == nil
    assert destination.location == nil
    assert destination.service_account_json == nil
    assert destination.access_token == nil
    assert destination.headers == %{}
    assert destination.provider_options == %{}
    assert destination.thinking_budgets == %{low: 2_048}
    assert destination.temperature == 0.4
    assert destination.max_tokens == 2_048
  end

  test "Session remains responsive and abort stops classification without a primary request",
       ctx do
    parent = self()
    calls = :counters.new(1, [:atomics])

    complete_fn = fn model, _, _ ->
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) == 1 do
        send(parent, {:classifier_blocked, self()})

        receive do
          :release -> {:ok, response(model, "high")}
        end
      else
        {:ok, response(model, "low")}
      end
    end

    session = start_session(ctx, complete_fn)
    id = Session.get_state(session).session_manager.header.id
    assert :ok = Session.prompt(session, "abort this turn")
    assert_receive {:classifier_blocked, worker}, 1_000
    monitor = Process.monitor(worker)
    assert GenServer.call(session, :get_state, 500).thinking_level == :auto
    assert :ok = Session.abort(session)
    assert_receive {:session_event, ^id, {:canceled, :assistant_aborted}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^worker, _reason}, 1_000
    assert :ok = LemonAgent.Agent.wait_for_idle(Session.get_state(session).agent, 1_000)
    refute_receive {:primary_request, _, _}

    assert :ok = Session.prompt(session, "new turn after abort")
    await_end(session)
    assert_receive {:primary_request, _, %{reasoning: :low}}
    assert Session.get_state(session).thinking_level == :auto
  end
end
