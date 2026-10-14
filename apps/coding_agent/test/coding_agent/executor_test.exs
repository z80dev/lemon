defmodule CodingAgent.ExecutorTest do
  use ExUnit.Case

  alias LemonAi.Types.{
    AssistantMessage,
    Cost,
    Model,
    ModelCost,
    TextContent,
    ThinkingContent,
    ToolCall,
    Usage
  }

  alias CodingAgent.Executor
  alias CodingAgent.Executor.SessionRunner, as: ExecutorSessionRunner
  alias LemonCore.{NodeRegistry, ResumeToken}
  alias LemonGateway.ExecutionRequest

  @tag :tmp_dir
  test "transient instrumentation preserves native execution and existing stream options", %{
    tmp_dir: tmp_dir
  } do
    previous = Application.get_env(:coding_agent, :executor_stream_options_hook)
    on_exit(fn -> Executor.configure_stream_options(previous) end)
    parent = self()

    Executor.configure_stream_options(fn run_id, options ->
      send(parent, {:instrumented, run_id, options.temperature})
      %{options | temperature: 0.25}
    end)

    native_stream =
      mock_stream_fn(List.duplicate(assistant_message("instrumented native run"), 2))

    stream = fn model, context, options ->
      send(parent, {:observed_temperature, options.temperature})
      native_stream.(model, context, options)
    end

    for {shape, index} <- Enum.with_index([:map, :keyword]) do
      run_id = "run-instrumented-#{index}"

      run_options = [
        stream_fn: stream,
        stream_options: %LemonAi.Types.StreamOptions{temperature: 0.125}
      ]

      opts = if shape == :map, do: Map.new(run_options), else: run_options

      req =
        request(tmp_dir,
          run_id: run_id,
          prompt: "exercise native instrumentation",
          stream_fn: stream
        )

      {:ok, run_ref, _ctx} = Executor.start_run(req, opts, self())

      assert {:engine_event, ^run_ref, %{__event__: :completed, ok: true}} =
               List.last(collect_until_completed(run_ref))

      assert_receive {:instrumented, ^run_id, 0.125}
      assert_receive {:observed_temperature, 0.25}
    end

    Executor.configure_stream_options(nil)
    assert Application.get_env(:coding_agent, :executor_stream_options_hook) == nil
  end


  @tag :tmp_dir
  test "same-context transcript resume rebuilds approval gating for each native invocation", %{
    tmp_dir: tmp_dir
  } do
    :ok = LemonCore.Bus.subscribe("exec_approvals")
    path = Path.join(tmp_dir, "invocation-gated.txt")
    parent = self()
    session_key = "agent:approval-writer-#{System.unique_integer([:positive])}:main"
    agent_id = LemonCore.SessionKey.agent_id(session_key)

    first_stream =
      mock_stream_fn([
        assistant_message_with_tool_calls([
          tool_call("write", %{"path" => path, "content" => "APPROVED"}, id: "first-write")
        ]),
        assistant_message("first invocation complete")
      ])

    first =
      request(tmp_dir,
        run_id: "approval-first-#{System.unique_integer([:positive])}",
        prompt: "first invocation transcript marker",
        stream_fn: first_stream,
        meta: %{invocation_context_key: "native-client-A", agent_id: agent_id}
      )

    first = %{
      first
      | session_key: session_key,
        tool_policy: CodingAgent.ToolPolicy.custom(require_approval: ["write"])
    }

    assert {:ok, first_ref, _ctx} =
             Executor.start_run(first, %{stream_fn: first_stream}, self())

    assert_receive %LemonCore.Event{
                     type: :approval_requested,
                     payload: %{pending: %{id: first_approval}}
                   }, 5_000

    first_pending = LemonCore.ExecApprovalStore.get_pending(first_approval)
    assert first_pending.invocation_context_key == "native-client-A"
    assert first_pending.agent_id == agent_id
    assert first_pending.session_key == session_key
    assert :ok = LemonCore.ExecApprovals.resolve(first_approval, :approve_once)

    first_events = collect_until_completed(first_ref)
    assert {:engine_event, ^first_ref, %{ok: true, resume: resume}} = List.last(first_events)
    assert File.read!(path) == "APPROVED"

    second_stream =
      mock_stream_fn([
        assistant_message_with_tool_calls([
          tool_call(
            "write",
            %{
              "path" => path,
              "content" => "DENIED",
              "invocation_context_key" => "tool-forged-client"
            },
            id: "second-write"
          )
        ]),
        assistant_message("second invocation complete")
      ])

    observed_stream = fn model, context, opts ->
      send(parent, {:resumed_context, context})
      second_stream.(model, context, opts)
    end

    second =
      request(tmp_dir,
        run_id: "approval-second-#{System.unique_integer([:positive])}",
        prompt: "second invocation",
        stream_fn: observed_stream,
        resume: resume,
        meta: %{"invocation_context_key" => "native-client-A", "agent_id" => agent_id}
      )

    second = %{second | session_key: session_key, tool_policy: first.tool_policy}

    assert {:ok, second_ref, _ctx} =
             Executor.start_run(second, %{stream_fn: observed_stream}, self())

    assert_receive {:resumed_context, context}, 5_000
    assert inspect(context.messages) =~ "first invocation transcript marker"
    assert_receive %LemonCore.Event{
                     type: :approval_requested,
                     payload: %{pending: %{id: second_approval}}
                   }, 5_000

    second_pending = LemonCore.ExecApprovalStore.get_pending(second_approval)
    assert second_pending.invocation_context_key == "native-client-A"
    assert second_pending.agent_id == agent_id
    assert second_pending.session_key == session_key
    assert second_pending.session_id == first_pending.session_id
    assert :ok = LemonCore.ExecApprovals.resolve(second_approval, :deny)

    second_events = collect_until_completed(second_ref)
    assert {:engine_event, ^second_ref, %{ok: true, resume: ^resume}} = List.last(second_events)
    assert File.read!(path) == "APPROVED"
    refute inspect(first_events ++ second_events) =~ "native-client-"
  end
  describe "start_run/3 direct session runner" do
    @tag :tmp_dir
    test "emits started, delta, tool action, and completed events", %{tmp_dir: tmp_dir} do
      tool_response =
        assistant_message_with_tool_calls([
          tool_call("bash", %{"command" => "printf executor-tool"}, id: "call_executor")
        ])

      final_response = assistant_message("executor done")

      request =
        request(tmp_dir,
          prompt: "run the native executor tool",
          run_id: "run-native-lemon",
          stream_fn: mock_stream_fn([tool_response, final_response])
        )

      {:ok, run_ref, ctx} =
        Executor.start_run(request, %{stream_fn: request.meta[:stream_fn]}, self())

      assert is_pid(ctx.runner_pid)

      messages = collect_until_completed(run_ref)

      assert {:engine_event, ^run_ref,
              %{
                __event__: :started,
                engine: "lemon",
                resume: %ResumeToken{engine: "lemon", value: session_id},
                meta: %{cwd: ^tmp_dir}
              }} =
               Enum.find(messages, &match?({:engine_event, ^run_ref, %{__event__: :started}}, &1))

      assert is_binary(session_id) and session_id != ""

      assert Enum.any?(messages, &match?({:engine_delta, ^run_ref, "executor done"}, &1))

      assert {:engine_event, ^run_ref,
              %{
                __event__: :action_event,
                phase: :started,
                action: %{
                  id: "tool_call_executor",
                  kind: "command",
                  title: "`printf executor-tool`",
                  detail: %{name: "bash", args: %{"command" => "printf executor-tool"}}
                }
              }} =
               Enum.find(
                 messages,
                 &match?(
                   {:engine_event, ^run_ref, %{__event__: :action_event, phase: :started}},
                   &1
                 )
               )

      assert {:engine_event, ^run_ref,
              %{
                __event__: :action_event,
                phase: :completed,
                ok: true,
                action: %{id: "tool_call_executor", kind: "command"}
              }} =
               Enum.find(
                 messages,
                 &match?(
                   {:engine_event, ^run_ref, %{__event__: :action_event, phase: :completed}},
                   &1
                 )
               )

      assert {:engine_event, ^run_ref,
              %{
                __event__: :completed,
                engine: "lemon",
                ok: true,
                answer: "executor done",
                resume: %ResumeToken{engine: "lemon", value: ^session_id}
              }} = List.last(messages)

      assert File.regular?(
               CodingAgent.Session.Presentation.session_file_path(session_id, tmp_dir)
             )
    end

    @tag :tmp_dir
    test "losing the sink stops the owned session while a tool is running", %{tmp_dir: tmp_dir} do
      parent = self()

      sink =
        spawn(fn ->
          forward = fn forward ->
            receive do
              message ->
                send(parent, {:sink_event, message})
                forward.(forward)
            end
          end

          forward.(forward)
        end)

      response =
        assistant_message_with_tool_calls([
          tool_call("bash", %{"command" => "sleep 30"}, id: "call_sink_cleanup")
        ])

      request =
        request(tmp_dir,
          run_id: "sink-cleanup-#{System.unique_integer([:positive])}",
          prompt: "hold a tool",
          stream_fn: mock_stream_fn([response])
        )

      {:ok, run_ref, %{runner_pid: runner}} =
        Executor.start_run(request, %{stream_fn: request.meta[:stream_fn]}, sink)

      assert_receive {:sink_event,
                      {:engine_event, ^run_ref,
                       %{__event__: :action_event, phase: :started, action: %{kind: "command"}}}},
                     5_000

      session = :sys.get_state(runner).session
      runner_ref = Process.monitor(runner)
      session_ref = Process.monitor(session)
      Process.exit(sink, :kill)
      assert_receive {:DOWN, ^session_ref, :process, ^session, _}, 5_000
      assert_receive {:DOWN, ^runner_ref, :process, ^runner, :normal}, 5_000
    end

    @tag :tmp_dir
    test "explicit local execution keeps the local runner with a named node online", %{
      tmp_dir: tmp_dir
    } do
      assert :ok = NodeRegistry.register("node-local-proof", "newphy", self())

      on_exit(fn -> NodeRegistry.unregister("node-local-proof", self()) end)

      request =
        request(tmp_dir,
          prompt: "stay local",
          run_id: "run-explicit-local",
          stream_fn: mock_stream_fn([assistant_message("local answer")]),
          meta: %{node: "local"}
        )

      assert {:ok, run_ref, %{runner_pid: runner_pid} = ctx} =
               Executor.start_run(request, %{stream_fn: request.meta[:stream_fn]}, self())

      assert is_pid(runner_pid)
      refute Map.has_key?(ctx, :runner_module)
      refute_receive {:node_event, "node.invoke.request", _}, 50

      messages = collect_until_completed(run_ref)

      assert {:engine_event, ^run_ref, %{__event__: :completed, answer: "local answer"}} =
               List.last(messages)
    end

    @tag :tmp_dir
    test "emits approval action events while a gated tool waits", %{tmp_dir: tmp_dir} do
      command = "printf approval-executor-#{System.unique_integer([:positive])}"

      tool_response =
        assistant_message_with_tool_calls([
          tool_call("bash", %{"command" => command}, id: "call_executor_approval")
        ])

      final_response = assistant_message("approval timeout handled")

      request =
        request(tmp_dir,
          prompt: "run the gated native executor tool",
          run_id: "run-native-approval",
          stream_fn: mock_stream_fn([tool_response, final_response])
        )

      request = %{request | tool_policy: %{approvals: %{"bash" => "always"}}}

      {:ok, run_ref, _ctx} =
        Executor.start_run(
          request,
          %{stream_fn: request.meta[:stream_fn], approval_timeout_ms: 20},
          self()
        )

      messages = collect_until_completed(run_ref)
      expected_title = "`#{command}`"

      assert {:engine_event, ^run_ref,
              %{
                __event__: :action_event,
                phase: :started,
                action: %{
                  id: approval_action_id,
                  kind: "approval",
                  title: ^expected_title,
                  detail: %{tool: "bash"}
                },
                message: "awaiting approval"
              }} =
               Enum.find(messages, fn
                 {:engine_event, ^run_ref,
                  %{__event__: :action_event, phase: :started, action: %{kind: "approval"}}} ->
                   true

                 _ ->
                   false
               end)

      assert {:engine_event, ^run_ref,
              %{
                __event__: :action_event,
                phase: :completed,
                ok: false,
                action: %{id: ^approval_action_id, kind: "approval"},
                message: "timed out"
              }} =
               Enum.find(messages, fn
                 {:engine_event, ^run_ref,
                  %{__event__: :action_event, phase: :completed, action: %{kind: "approval"}}} ->
                   true

                 _ ->
                   false
               end)
    end

    @tag :tmp_dir
    test "emits reasoning action events without leaking thinking into answer deltas", %{
      tmp_dir: tmp_dir
    } do
      response =
        assistant_message([
          %ThinkingContent{type: :thinking, thinking: "checking the native path"},
          %TextContent{type: :text, text: "answer only"}
        ])

      request =
        request(tmp_dir,
          prompt: "think then answer",
          run_id: "run-native-reasoning",
          stream_fn: mock_stream_fn([response])
        )

      {:ok, run_ref, _ctx} =
        Executor.start_run(request, %{stream_fn: request.meta[:stream_fn]}, self())

      messages = collect_until_completed(run_ref)

      deltas =
        for {:engine_delta, ^run_ref, text} <- messages do
          text
        end

      assert deltas != []
      assert Enum.all?(deltas, &(&1 == "answer only"))
      refute Enum.any?(deltas, &String.contains?(&1, "checking the native path"))

      assert {:engine_event, ^run_ref,
              %{
                __event__: :action_event,
                phase: :started,
                action: %{
                  id: action_id,
                  kind: "reasoning",
                  detail: %{reasoning: %{text: "checking the native path"}}
                }
              }} =
               Enum.find(messages, fn
                 {:engine_event, ^run_ref,
                  %{__event__: :action_event, phase: :started, action: %{kind: "reasoning"}}} ->
                   true

                 _ ->
                   false
               end)

      assert {:engine_event, ^run_ref,
              %{
                __event__: :action_event,
                phase: :completed,
                ok: true,
                action: %{
                  id: ^action_id,
                  kind: "reasoning",
                  detail: %{reasoning: %{text: "checking the native path"}}
                }
              }} =
               Enum.find(messages, fn
                 {:engine_event, ^run_ref,
                  %{__event__: :action_event, phase: :completed, action: %{kind: "reasoning"}}} ->
                   true

                 _ ->
                   false
               end)

      assert {:engine_event, ^run_ref,
              %{
                __event__: :completed,
                engine: "lemon",
                ok: true,
                answer: "answer only"
              }} = List.last(messages)
    end

    @tag :tmp_dir
    test "emits reasoning updates with the accumulated tail window", %{tmp_dir: tmp_dir} do
      thinking = "start-" <> String.duplicate("middle-", 120) <> "live-tail"
      accumulated = thinking <> thinking
      expected_tail = "..." <> String.slice(accumulated, -500, 500)

      response =
        assistant_message([
          %ThinkingContent{type: :thinking, thinking: thinking},
          %TextContent{type: :text, text: "done"}
        ])

      request =
        request(tmp_dir,
          prompt: "think then answer",
          run_id: "run-native-reasoning-update",
          stream_fn: mock_stream_fn([response])
        )

      {:ok, run_ref, _ctx} =
        Executor.start_run(request, %{stream_fn: request.meta[:stream_fn]}, self())

      messages = collect_until_completed(run_ref)

      assert {:engine_event, ^run_ref,
              %{
                __event__: :action_event,
                phase: :updated,
                action: %{
                  kind: "reasoning",
                  detail: %{reasoning: %{text: ^expected_tail}}
                }
              }} =
               Enum.find(messages, fn
                 {:engine_event, ^run_ref,
                  %{__event__: :action_event, phase: :updated, action: %{kind: "reasoning"}}} ->
                   true

                 _ ->
                   false
               end)
    end

    @tag :tmp_dir
    test "cancel completion carries usage from messages already seen", %{tmp_dir: tmp_dir} do
      tool_response =
        assistant_message_with_tool_calls([
          tool_call("missing_tool_for_cancel_usage", %{}, id: "call_cancel_usage")
        ])

      request =
        request(tmp_dir,
          prompt: "start then cancel",
          run_id: "run-native-cancel-usage",
          stream_fn: mock_stream_fn([tool_response, :slow])
        )

      {:ok, run_ref, ctx} =
        Executor.start_run(request, %{stream_fn: request.meta[:stream_fn]}, self())

      assert_receive {:engine_event, ^run_ref, %{__event__: :started}}, 2_000

      assert_receive {:engine_event, ^run_ref,
                      %{
                        __event__: :action_event,
                        phase: :completed,
                        action: %{id: "tool_call_cancel_usage"}
                      }},
                     2_000

      assert Executor.cancel(ctx) == :ok

      assert_receive {:engine_event, ^run_ref,
                      %{
                        __event__: :completed,
                        ok: false,
                        error: "Cancelled by user",
                        usage: usage
                      }},
                     2_000

      assert usage.input == 1
      assert usage.output == 1
      assert usage.total_tokens == 2
    end

    @tag :tmp_dir
    test "supports steer and still cancels on direct session runner", %{tmp_dir: tmp_dir} do
      request =
        request(tmp_dir,
          prompt: "wait",
          run_id: "run-native-cancel",
          stream_fn: slow_stream_fn()
        )

      {:ok, run_ref, ctx} =
        Executor.start_run(request, %{stream_fn: request.meta[:stream_fn]}, self())

      assert_receive {:engine_event, ^run_ref, %{__event__: :started}}, 2_000
      assert Executor.steer(ctx, "change course") == :ok
      assert Executor.cancel(ctx) == :ok

      assert_receive {:engine_event, ^run_ref,
                      %{
                        __event__: :completed,
                        ok: false,
                        error: "Cancelled by user"
                      }},
                     2_000
    end

    test "cancel is total and idempotent for stale control contexts" do
      assert Executor.cancel(nil) == :ok
      assert Executor.cancel(%{}) == :ok
      assert Executor.cancel(%{runner_pid: nil}) == :ok
    end
  end

  describe "executor session runner resume source" do
    @tag :tmp_dir
    test "falls back to a fresh session for a stale string-key auto resume source", %{
      tmp_dir: tmp_dir
    } do
      stale_session_id = "missing-auto-#{System.unique_integer([:positive])}"

      request =
        request(tmp_dir,
          prompt: "start fresh",
          run_id: "run-native-auto-resume",
          resume: ResumeToken.new("lemon", stale_session_id),
          meta: %{"resume_source" => :auto},
          stream_fn: mock_stream_fn([assistant_message("fresh after stale auto resume")])
        )

      run_ref = make_ref()

      {:ok, _runner} =
        ExecutorSessionRunner.start_link(
          request: request,
          opts: %{stream_fn: request.meta[:stream_fn]},
          sink_pid: self(),
          run_ref: run_ref
        )

      messages = collect_until_completed(run_ref)

      assert {:engine_event, ^run_ref,
              %{
                __event__: :started,
                resume: %ResumeToken{engine: "lemon", value: resumed_session_id}
              }} =
               Enum.find(messages, &match?({:engine_event, ^run_ref, %{__event__: :started}}, &1))

      refute resumed_session_id == stale_session_id

      assert {:engine_event, ^run_ref,
              %{__event__: :completed, ok: true, answer: "fresh after stale auto resume"}} =
               List.last(messages)
    end

    @tag :tmp_dir
    test "returns an error to non-trapping callers when explicit resume is missing", %{
      tmp_dir: tmp_dir
    } do
      stale_session_id = "missing-explicit-#{System.unique_integer([:positive])}"

      request =
        request(tmp_dir,
          prompt: "resume explicitly",
          run_id: "run-native-explicit-resume-executor",
          resume: ResumeToken.new("lemon", stale_session_id),
          meta: %{resume_source: :explicit},
          stream_fn: mock_stream_fn([assistant_message("should not run")])
        )

      assert {:error, {:resume_session_missing, ^stale_session_id}} =
               Executor.start_run(request, %{stream_fn: request.meta[:stream_fn]}, self())

      refute_receive {:EXIT, _, _}, 50
    end

    @tag :tmp_dir
    test "rejects a stale atom-key explicit resume source", %{tmp_dir: tmp_dir} do
      stale_session_id = "missing-explicit-#{System.unique_integer([:positive])}"

      request =
        request(tmp_dir,
          prompt: "resume explicitly",
          run_id: "run-native-explicit-resume",
          resume: ResumeToken.new("lemon", stale_session_id),
          meta: %{resume_source: :explicit},
          stream_fn: mock_stream_fn([assistant_message("should not run")])
        )

      previous_trap_exit = Process.flag(:trap_exit, true)

      try do
        assert {:error, {:resume_session_missing, ^stale_session_id}} =
                 ExecutorSessionRunner.start_link(
                   request: request,
                   opts: %{stream_fn: request.meta[:stream_fn]},
                   sink_pid: self(),
                   run_ref: make_ref()
                 )

        receive do
          {:EXIT, _pid, {:resume_session_missing, ^stale_session_id}} -> :ok
        after
          50 -> :ok
        end
      after
        Process.flag(:trap_exit, previous_trap_exit)
      end
    end
  end

  defp request(tmp_dir, opts) do
    %ExecutionRequest{
      run_id: Keyword.fetch!(opts, :run_id),
      session_key: "test:lemon:#{System.unique_integer([:positive])}",
      prompt: Keyword.fetch!(opts, :prompt),
      images: [],
      cwd: tmp_dir,
      resume: Keyword.get(opts, :resume),
      meta:
        %{model: mock_model(), stream_fn: Keyword.fetch!(opts, :stream_fn)}
        |> Map.merge(Keyword.get(opts, :meta, %{}))
    }
  end

  defp collect_until_completed(run_ref, acc \\ []) do
    receive do
      {:engine_event, ^run_ref, %{__event__: :completed}} = msg ->
        Enum.reverse([msg | acc])

      {:engine_event, ^run_ref, _event} = msg ->
        collect_until_completed(run_ref, [msg | acc])

      {:engine_delta, ^run_ref, _text} = msg ->
        collect_until_completed(run_ref, [msg | acc])
    after
      5_000 ->
        flunk(
          "timed out waiting for lemon engine completion; received #{inspect(Enum.reverse(acc))}"
        )
    end
  end

  defp mock_model do
    %Model{
      id: "mock-model-1",
      name: "Mock Model",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://api.mock.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.01, output: 0.03},
      context_window: 128_000,
      max_tokens: 4096,
      headers: %{},
      compat: nil
    }
  end

  defp assistant_message(text) when is_binary(text) do
    assistant_message([%TextContent{type: :text, text: text}])
  end

  defp assistant_message(content) when is_list(content) do
    %AssistantMessage{
      role: :assistant,
      content: content,
      api: :mock,
      provider: :mock_provider,
      model: "mock-model-1",
      usage: %Usage{
        input: 1,
        output: 1,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 2,
        cost: %Cost{input: 0.0, output: 0.0, total: 0.0}
      },
      stop_reason: :stop,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp assistant_message_with_tool_calls(tool_calls) do
    %AssistantMessage{
      role: :assistant,
      content: tool_calls,
      api: :mock,
      provider: :mock_provider,
      model: "mock-model-1",
      usage: %Usage{
        input: 1,
        output: 1,
        cache_read: 0,
        cache_write: 0,
        total_tokens: 2,
        cost: %Cost{input: 0.0, output: 0.0, total: 0.0}
      },
      stop_reason: :tool_use,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp tool_call(name, arguments, opts) do
    %ToolCall{
      type: :tool_call,
      id: Keyword.fetch!(opts, :id),
      name: name,
      arguments: arguments
    }
  end

  defp mock_stream_fn(responses) do
    {:ok, agent} = Agent.start_link(fn -> responses end)

    fn _model, _context, _options ->
      response =
        Agent.get_and_update(agent, fn
          [] -> {assistant_message(""), []}
          [head | tail] -> {head, tail}
        end)

      {:ok, response_to_event_stream(response)}
    end
  end

  defp slow_stream_fn do
    fn _model, _context, _options ->
      {:ok, stream} = LemonAi.EventStream.start_link()

      Task.start(fn ->
        Process.sleep(10_000)
        response = assistant_message("too late")
        LemonAi.EventStream.push(stream, {:done, response.stop_reason, response})
        LemonAi.EventStream.complete(stream, response)
      end)

      {:ok, stream}
    end
  end

  defp response_to_event_stream(response) do
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      case response do
        :slow ->
          Process.sleep(10_000)
          response = assistant_message("too late")
          LemonAi.EventStream.push(stream, {:done, response.stop_reason, response})
          LemonAi.EventStream.complete(stream, response)

        %AssistantMessage{} ->
          LemonAi.EventStream.push(stream, {:start, response})

          response.content
          |> Enum.with_index()
          |> Enum.each(fn
            {%TextContent{text: text}, idx} ->
              LemonAi.EventStream.push(stream, {:text_start, idx, response})
              LemonAi.EventStream.push(stream, {:text_delta, idx, text, response})
              LemonAi.EventStream.push(stream, {:text_end, idx, text, response})

            {%ThinkingContent{thinking: thinking}, idx} ->
              LemonAi.EventStream.push(stream, {:thinking_start, idx, response})
              LemonAi.EventStream.push(stream, {:thinking_delta, idx, thinking, response})
              LemonAi.EventStream.push(stream, {:thinking_end, idx, thinking, response})

            {%ToolCall{} = tool_call, idx} ->
              LemonAi.EventStream.push(stream, {:tool_call_start, idx, response})
              LemonAi.EventStream.push(stream, {:tool_call_end, idx, tool_call, response})

            {_content, _idx} ->
              :ok
          end)

          LemonAi.EventStream.push(stream, {:done, response.stop_reason, response})
          LemonAi.EventStream.complete(stream, response)
      end
    end)

    stream
  end
end
