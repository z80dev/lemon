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
  alias CodingAgent.{ParentQuestions, RunGraph, Session, TaskStore, TaskStoreServer}
  alias CodingAgent.Tools.AskParent
  alias LemonAgent.Types.AgentToolResult
  alias LemonCore.{ExecutionContext, NodeRegistry, ResumeToken, ToolPolicy}
  alias LemonGateway.ExecutionRequest

  defmodule QuestionDeliveryBarrier do
    def deliver_parent_question(observer, text) do
      ref = make_ref()
      send(observer, {:question_delivery, self(), ref, text})

      receive do
        {^ref, result} -> result
      after
        5_000 -> raise "parent question delivery was not acknowledged"
      end
    end
  end

  defmodule QuestionSummaryProvider do
    def stream(_model, context, _options) do
      observer = Application.fetch_env!(:coding_agent, :executor_parent_question_test_owner)
      send(observer, {:question_compaction, self(), context})

      receive do
        {:respond, response} ->
          {:ok, stream} = LemonAi.EventStream.start_link()
          LemonAi.EventStream.complete(stream, response)
          {:ok, stream}
      after
        5_000 -> raise "parent question compaction was not released"
      end
    end
  end

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
                   },
                   5_000

    first_pending = LemonCore.ExecApprovalStore.get_pending(first_approval)
    assert first_pending.invocation_context_key == "native-client-A"
    assert first_pending.agent_id == agent_id
    assert first_pending.session_key == session_key
    assert {:ok, _receipt} = LemonCore.ExecApprovals.resolve(first_approval, :approve_once)

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
                   },
                   5_000

    second_pending = LemonCore.ExecApprovalStore.get_pending(second_approval)
    assert second_pending.invocation_context_key == "native-client-A"
    assert second_pending.agent_id == agent_id
    assert second_pending.session_key == session_key
    assert second_pending.session_id == first_pending.session_id
    assert {:ok, _receipt} = LemonCore.ExecApprovals.resolve(second_approval, :deny)

    second_events = collect_until_completed(second_ref)
    assert {:engine_event, ^second_ref, %{ok: true, resume: ^resume}} = List.last(second_events)
    assert File.read!(path) == "APPROVED"
    refute inspect(first_events ++ second_events) =~ "native-client-"
  end

  describe "start_run/3 direct session runner" do
    @tag :tmp_dir
    @tag :parent_question_regression
    test "a suspended question delivery keeps the real task join active until enqueue acknowledgement",
         %{tmp_dir: tmp_dir} do
      run = parent_question_run(tmp_dir)
      assert_question_run_active(run)
      answer = "Use the second option for the child question."
      answer_question_child(run, answer)
      send(run.provider, {:respond, assistant_message(answer)})

      assert {:engine_event, run_ref, %{__event__: :completed, ok: true, answer: ^answer}} =
               List.last(collect_until_completed(run.run_ref))

      assert run_ref == run.run_ref
      session_id = run.session_id
      assert_receive {:session_event, ^session_id, {:agent_end, messages}}, 5_000
      assert List.last(messages) |> LemonAi.get_text() == answer

      assert Enum.any?(messages, fn
               %AssistantMessage{} = message -> LemonAi.get_text(message) == run.join_answer
               _ -> false
             end)

      assert_question_run_stopped(run)
      refute_receive {:session_event, ^session_id, {:agent_end, _}}, 0
      refute_receive {:engine_event, ^run_ref, %{__event__: :completed}}, 0
    end

    @tag :tmp_dir
    @tag :parent_question_regression
    test "an in-loop question error cannot complete the executor with the earlier join answer", %{
      tmp_dir: tmp_dir
    } do
      run = parent_question_run(tmp_dir)
      assert_question_run_active(run)
      answer_question_child(run, "The parent provider will fail.")
      error = "question provider failed"

      send(
        run.provider,
        {:respond, %{assistant_message([]) | stop_reason: :error, error_message: error}}
      )

      assert {:engine_event, run_ref, %{__event__: :completed, ok: false, error: failure}} =
               List.last(collect_until_completed(run.run_ref))

      assert run_ref == run.run_ref
      assert failure =~ error
      session_id = run.session_id

      assert_receive {:session_event, ^session_id, {:error, {:assistant_error, ^error}, _}},
                     5_000

      assert_question_run_stopped(run)
      refute_receive {:session_event, ^session_id, {:agent_end, _}}, 0
      refute_receive {:engine_event, ^run_ref, %{__event__: :completed}}, 0
    end

    @tag :tmp_dir
    @tag :parent_question_regression
    test "an in-loop question abort cannot leak a successful executor terminal event", %{
      tmp_dir: tmp_dir
    } do
      run = parent_question_run(tmp_dir)
      assert_question_run_active(run)
      answer_question_child(run, "The parent provider will abort.")
      send(run.provider, {:respond, %{assistant_message([]) | stop_reason: :aborted}})

      assert {:engine_event, run_ref, %{__event__: :completed, ok: false, error: failure}} =
               List.last(collect_until_completed(run.run_ref))

      assert run_ref == run.run_ref
      assert failure =~ "Cancelled"
      assert_question_run_stopped(run)
      session_id = run.session_id
      refute_receive {:session_event, ^session_id, {:agent_end, _}}, 0
      refute_receive {:engine_event, ^run_ref, %{__event__: :completed}}, 0
    end

    @tag :tmp_dir
    @tag :parent_question_regression
    test "question context overflow holds executor completion through compaction and recovery", %{
      tmp_dir: tmp_dir
    } do
      previous_owner = Application.get_env(:coding_agent, :executor_parent_question_test_owner)
      Application.put_env(:coding_agent, :executor_parent_question_test_owner, self())
      LemonAi.ProviderRegistry.register(:executor_parent_question_test, QuestionSummaryProvider)

      on_exit(fn ->
        LemonAi.ProviderRegistry.unregister(:executor_parent_question_test)

        if previous_owner == nil do
          Application.delete_env(:coding_agent, :executor_parent_question_test_owner)
        else
          Application.put_env(:coding_agent, :executor_parent_question_test_owner, previous_owner)
        end
      end)

      model = %{
        mock_model()
        | api: :executor_parent_question_test,
          provider: :executor_parent_question_test
      }

      run = parent_question_run(tmp_dir, model: model)
      answer = "The recovered parent answer is to keep the existing boundary."
      answer_question_child(run, answer)
      assert_question_run_active(run)

      send(
        run.provider,
        {:respond,
         %{
           assistant_message([])
           | stop_reason: :error,
             error_message: "context_length_exceeded",
             error_details: %{category: :context_length, output_committed: false}
         }}
      )

      session_id = run.session_id

      assert_receive {:session_event, ^session_id, {:compaction_start, %{reason: :overflow}}},
                     5_000

      assert_receive {:question_compaction, summary_provider, _context}, 5_000
      state = Session.get_state(run.session)
      assert state.overflow_recovery.in_progress
      assert state.is_streaming
      assert state.terminal_event == nil
      assert Process.alive?(run.runner)
      refute_receive {:session_event, ^session_id, {:agent_end, _}}, 0
      refute_receive {:session_event, ^session_id, {:error, _, _}}, 0
      run_ref = run.run_ref
      refute_receive {:engine_event, ^run_ref, %{__event__: :completed}}, 0
      send(summary_provider, {:respond, assistant_message("Earlier join history summarized.")})

      assert_receive {:session_event, ^session_id, {:compaction_complete, _}}, 5_000
      assert_receive {:question_provider, recovered_provider, recovered_context}, 5_000

      assert Enum.any?(recovered_context.messages, fn
               %{role: :user, content: content} when is_binary(content) ->
                 String.contains?(content, run.question)

               _ ->
                 false
             end)

      recovered_state = Session.get_state(run.session)
      refute recovered_state.overflow_recovery.in_progress
      assert recovered_state.overflow_recovery.attempted

      assert Enum.count(
               CodingAgent.SessionManager.entries(recovered_state.session_manager),
               &(&1.type == :compaction)
             ) == 1

      assert_question_run_active(run)
      send(recovered_provider, {:respond, assistant_message(answer)})

      assert {:engine_event, ^run_ref, %{__event__: :completed, ok: true, answer: ^answer}} =
               List.last(collect_until_completed(run_ref))

      assert_receive {:session_event, ^session_id, {:agent_end, messages}}, 5_000
      assert List.last(messages) |> LemonAi.get_text() == answer
      assert_question_run_stopped(run)
      refute_receive {:session_event, ^session_id, {:agent_end, _}}, 0
      refute_receive {:session_event, ^session_id, {:error, _, _}}, 0
      refute_receive {:session_event, ^session_id, {:compaction_start, _}}, 0
      refute_receive {:engine_event, ^run_ref, %{__event__: :completed}}, 0
    end

    @tag :tmp_dir
    test "validates supplied authority before starting a local session", %{tmp_dir: tmp_dir} do
      req =
        request(tmp_dir,
          prompt: "must not start",
          run_id: "authority-validation",
          stream_fn: fn _, _, _ -> flunk("invalid authority must not invoke a provider") end
        )

      for invalid <- [false, %{"runId" => req.run_id}] do
        assert {:error, :invalid_execution_context} =
                 Executor.start_run(%{req | execution_context: invalid}, %{}, self())
      end

      assert {:ok, context} = ExecutionContext.new(run_id: "other-run", cwd: tmp_dir)

      assert {:error, :execution_context_run_id_mismatch} =
               Executor.start_run(%{req | execution_context: context}, %{}, self())

      assert {:error, :invalid_execution_context} =
               Executor.start_run(req, %{execution_context: false}, self())

      refute_receive {:engine_event, _, _}, 50
    end

    @tag :tmp_dir
    test "field and option authority preserve invocation ownership and destination policy floors",
         %{
           tmp_dir: tmp_dir
         } do
      parent = self()

      for placement <- [:field, :option] do
        run_id = "bounded-authority-#{placement}"
        native = mock_stream_fn([assistant_message("bounded native run")])

        stream = fn model, context, options ->
          send(parent, {:authority_provider, self()})

          receive do
            :continue_authority -> native.(model, context, options)
          after
            5_000 -> raise "authority provider was not released"
          end
        end

        assert {:ok, authority} =
                 ExecutionContext.new(
                   run_id: run_id,
                   cwd: tmp_dir,
                   principal: %{type: "actor", id: "authority-principal"},
                   tool_policy: %{allow: ["read", "write"]},
                   capabilities: ["read", "write"],
                   limits: %{max_steps: 7}
                 )

        req =
          request(tmp_dir,
            run_id: run_id,
            prompt: "inspect authority",
            stream_fn: stream,
            meta: %{agent_id: "invocation-owner", invocation_context_key: "invocation-binding"}
          )

        req = %{req | tool_policy: %{allow: :all}}
        opts = %{stream_fn: stream, tool_policy: %{allow: ["read"]}}

        {req, opts} =
          if placement == :field,
            do: {%{req | execution_context: authority}, opts},
            else: {req, Map.put(opts, :execution_context, authority)}

        assert {:ok, run_ref, %{runner_pid: runner}} = Executor.start_run(req, opts, self())
        assert_receive {:authority_provider, provider}, 5_000
        on_exit(fn -> send(provider, :continue_authority) end)
        session = :sys.get_state(runner).session
        state = CodingAgent.Session.get_state(session)

        assert state.execution_context.run_id == run_id
        assert state.execution_context.principal == authority.principal
        assert state.execution_context.limits.max_steps == 7
        assert ExecutionContext.subset?(state.execution_context, authority)
        assert ToolPolicy.allowed?(state.execution_context.tool_policy, "read")
        refute ToolPolicy.allowed?(state.execution_context.tool_policy, "write")
        assert state.approval_context.invocation_context_key == "invocation-binding"
        assert state.approval_context.agent_id == "invocation-owner"
        assert state.approval_context.run_id == run_id
        assert state.approval_context.session_key == req.session_key

        send(provider, :continue_authority)

        assert {:engine_event, ^run_ref, %{__event__: :completed, ok: true}} =
                 List.last(collect_until_completed(run_ref))
      end
    end

    @tag :tmp_dir
    test "rejects malformed supplied policy before starting a session", %{tmp_dir: tmp_dir} do
      request =
        request(tmp_dir,
          prompt: "must not start",
          run_id: "run-invalid-policy",
          stream_fn: mock_stream_fn([assistant_message("unexpected")])
        )

      request = %{request | tool_policy: %{"allow" => 123}}

      assert {:error, {:invalid_policy_field, :allow}} =
               Executor.start_run(request, %{stream_fn: request.meta[:stream_fn]}, self())

      refute_receive {:engine_event, _, _}, 50
    end

    @tag :tmp_dir
    test "emits started, delta, tool action, and completed events", %{tmp_dir: tmp_dir} do
      tool_response =
        assistant_message_with_tool_calls([
          tool_call(
            "bash",
            %{
              "command" => "printf executor-tool",
              "env" => %{"FOO" => "opaque-env-value-never-log"}
            },
            id: "call_executor"
          )
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

      refute inspect(messages) =~ "opaque-env-value-never-log"

      started =
        Enum.find(
          messages,
          &match?(
            {:engine_event, ^run_ref, %{__event__: :action_event, phase: :started}},
            &1
          )
        )

      {:engine_event, _, action} = started
      assert action.action.detail.args["env_keys"] == ["FOO"]

      assert File.regular?(
               CodingAgent.Session.Presentation.session_file_path(session_id, tmp_dir)
             )
    end

    @tag :tmp_dir
    @tag :python3
    test "completed native turns hand off eval and debugger state; logical reset kills descendants",
         %{tmp_dir: tmp_dir} do
      parent = self()
      File.write!(Path.join(tmp_dir, "prog.fake"), "")
      adapter = Path.expand("../support/fake_dap_adapter.py", __DIR__)
      log = Path.join(tmp_dir, "dap.jsonl")

      code = """
      import subprocess
      value = 41
      child = subprocess.Popen(['sleep', '60'], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
      child.pid
      """

      native =
        mock_stream_fn([
          assistant_message_with_tool_calls([
            tool_call("eval", %{"language" => "py", "code" => code}, id: "eval-init")
          ]),
          assistant_message("first turn")
        ])

      stream = fn model, context, options ->
        if Enum.any?(context.messages, &(Map.get(&1, :tool_call_id) == "eval-init")) do
          send(parent, {:finish_ready, self()})

          receive do
            :finish_turn -> :ok
          after
            20_000 -> raise "turn was not released"
          end
        end

        native.(model, context, options)
      end

      first =
        request(tmp_dir, run_id: "handoff-first", prompt: "initialize kernel", stream_fn: stream)

      {:ok, first_ref, %{runner_pid: runner}} =
        Executor.start_run(first, %{stream_fn: stream}, self())

      assert_receive {:finish_ready, provider}, 20_000
      session = :sys.get_state(runner).session
      id = CodingAgent.Session.get_state(session).session_manager.header.id
      resume = ResumeToken.new("lemon", id)

      opts = [
        session_id: id,
        session_pid: session,
        session_key: first.session_key,
        debug_adapters: %{
          "fake" => %{
            command: System.find_executable("python3"),
            args: [adapter, log],
            launch_defaults: %{"stopOnEntry" => true}
          }
        }
      ]

      debugger =
        CodingAgent.Tools.Debug.execute(
          "launch",
          %{"action" => "launch", "program" => "prog.fake", "adapter" => "fake"},
          nil,
          nil,
          tmp_dir,
          opts
        )

      refute debugger.is_error
      debuggee = debugger.details.snapshot.process_id
      debug_server = CodingAgent.Debug.SessionServer.whereis(id)
      {:ok, kernel} = CodingAgent.Eval.KernelSupervisor.lookup({id, "py"})

      eval_result =
        Enum.find(
          CodingAgent.Session.get_messages(session),
          &(Map.get(&1, :tool_call_id) == "eval-init")
        )

      child = eval_result.content |> hd() |> Map.fetch!(:text) |> String.to_integer()
      on_exit(fn -> CodingAgent.ToolResources.stop(id) end)
      send(provider, :finish_turn)

      assert {:engine_event, ^first_ref, %{__event__: :completed, ok: true}} =
               List.last(collect_until_completed(first_ref))

      refute Process.alive?(session)
      assert Process.alive?(kernel)
      assert Process.alive?(debug_server)

      next_stream =
        mock_stream_fn([
          assistant_message_with_tool_calls([
            tool_call("eval", %{"language" => "py", "code" => "value + 1"}, id: "eval-next"),
            tool_call("debug", %{"action" => "status"}, id: "debug-next")
          ]),
          assistant_message("second turn")
        ])

      capture = fn model, context, options ->
        send(parent, {:next_context, context.messages})
        next_stream.(model, context, options)
      end

      second = %{
        request(tmp_dir,
          run_id: "handoff-second",
          prompt: "reuse resources",
          resume: resume,
          stream_fn: capture
        )
        | session_key: first.session_key
      }

      {:ok, second_ref, _} = Executor.start_run(second, %{stream_fn: capture}, self())

      assert {:engine_event, ^second_ref, %{__event__: :completed, ok: true}} =
               List.last(collect_until_completed(second_ref))

      assert_receive {:next_context, _initial}
      assert_receive {:next_context, messages}
      result = Enum.find(messages, &(Map.get(&1, :tool_call_id) == "eval-next"))
      assert Enum.any?(result.content, &Regex.match?(~r/(?:^|\n)42(?:\n|$)/, &1.text))
      status = Enum.find(messages, &(Map.get(&1, :tool_call_id) == "debug-next"))
      assert status.details.snapshot.process_id == debuggee
      assert status.details.snapshot.status == :stopped
      assert {:ok, ^kernel} = CodingAgent.Eval.KernelSupervisor.lookup({id, "py"})
      assert CodingAgent.Debug.SessionServer.whereis(id) == debug_server

      kernel_ref = Process.monitor(kernel)
      debug_ref = Process.monitor(debug_server)
      :ok = LemonCore.RunStore.delete_history(first.session_key)
      assert_receive {:DOWN, ^kernel_ref, :process, ^kernel, _}, 10_000
      assert_receive {:DOWN, ^debug_ref, :process, ^debug_server, _}, 10_000

      for pid <- [child, debuggee] do
        CodingAgent.AsyncHelpers.assert_eventually(
          fn ->
            case System.cmd("ps", ["-o", "stat=", "-p", Integer.to_string(pid)],
                   stderr_to_stdout: true
                 ) do
              {stat, 0} -> String.starts_with?(String.trim(stat), "Z")
              _ -> true
            end
          end,
          timeout: 5_000
        )
      end
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
    test "auto resume in another directory refuses to replace a mapped native history", %{
      tmp_dir: tmp_dir
    } do
      source = Path.join(tmp_dir, "source")
      destination = Path.join(tmp_dir, "destination")
      File.mkdir_p!(source)
      File.mkdir_p!(destination)

      manager =
        source
        |> CodingAgent.SessionManager.new()
        |> CodingAgent.SessionManager.append_message(%{"role" => "user", "content" => "keep"})

      path = CodingAgent.Session.Presentation.session_file_path(manager.header.id, source)
      :ok = CodingAgent.SessionManager.save_to_file(path, manager)
      original = File.read!(path)

      req =
        request(destination,
          prompt: "continue",
          run_id: "cross-directory-resume",
          resume: ResumeToken.new("lemon", manager.header.id),
          meta: %{"resume_source" => :auto},
          stream_fn: fn _, _, _ -> flunk("missing mapped history must not invoke a provider") end
        )

      chat_state = %LemonCore.ChatState{
        last_engine: "lemon",
        last_resume_token: manager.header.id,
        updated_at: System.system_time(:millisecond)
      }

      :ok = LemonCore.ChatStateStore.put(req.session_key, chat_state)

      on_exit(fn ->
        LemonCore.ChatStateStore.delete(req.session_key)
        File.rm_rf!(CodingAgent.SessionManager.get_session_dir(source))
        File.rm_rf!(CodingAgent.SessionManager.get_session_dir(destination))
      end)

      id = manager.header.id

      assert {:error, {:resume_session_missing, ^id}} =
               Executor.start_run(req, %{stream_fn: req.meta[:stream_fn]}, self())

      # The preflight and actual start both fail closed, including a file disappearing
      # between validation and startup.
      assert {:error, {:resume_session_missing, ^id}} =
               CodingAgent.Session.Presentation.start_or_resume_session(
                 req.resume,
                 [resume_source: :auto, session_key: req.session_key],
                 %{cwd: destination}
               )

      assert %{last_engine: "lemon", last_resume_token: ^id} =
               LemonCore.ChatStateStore.get(req.session_key)

      assert File.read!(path) == original
      refute File.exists?(CodingAgent.Session.Presentation.session_file_path(id, destination))
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

  defp parent_question_run(tmp_dir, opts \\ []) do
    observer = self()
    child_run_id = RunGraph.new_run(%{status: :running})
    task_id = TaskStore.new_task(%{run_id: child_run_id, status: :running})
    child_scope_id = "executor-question-#{task_id}"
    question = "Which boundary should the blocked child keep?"
    join_answer = "The join yielded for clarification; this is not the final answer."
    gate = make_ref()
    join_gate = :atomics.new(1, [])

    stream_fn = fn _model, context, _options ->
      send(observer, {:question_provider, self(), context})

      receive do
        {:respond, response} -> {:ok, response_to_event_stream(response)}
      after
        5_000 -> raise "parent question provider was not released"
      end
    end

    # Isolate this run from host memory extraction and automatic compaction.
    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))

    File.write!(
      Path.join(tmp_dir, ".lemon/config.toml"),
      "[features]\nsession_search = \"off\"\n"
    )

    req =
      request(tmp_dir,
        run_id: "parent-question-#{task_id}",
        prompt: String.duplicate("Wait for the blocked child's boundary decision. ", 100),
        stream_fn: stream_fn,
        meta: %{agent_id: "main", model: Keyword.get(opts, :model, mock_model())}
      )

    assert {:ok, run_ref, %{runner_pid: runner}} =
             Executor.start_run(req, %{stream_fn: stream_fn}, self())

    session = :sys.get_state(runner).session
    state = Session.get_state(session)
    session_id = state.session_manager.header.id
    agent = state.agent
    session_ref = Process.monitor(session)
    runner_ref = Process.monitor(runner)
    _unsubscribe = Session.subscribe(session)

    on_exit(fn ->
      if Process.alive?(session), do: :sys.resume(session)
      if Process.alive?(runner), do: GenServer.stop(runner)

      case ParentQuestions.open_request_for_child_scope(child_scope_id) do
        {:ok, request} -> ParentQuestions.cancel(request.id, :test_cleanup)
        {:error, :not_found} -> :ok
      end

      TaskStoreServer.delete_task(task_id)
      RunGraph.delete_run(child_run_id)
      File.rm_rf!(CodingAgent.SessionManager.get_session_dir(tmp_dir))
    end)

    assert_receive {:question_provider, first_provider, _context}, 5_000

    :ok =
      TaskStoreServer.update_record(task_id, fn record ->
        Map.put(record, :owner, {session_id, "main"})
      end)

    :sys.replace_state(session, fn current ->
      %{
        current
        | settings_manager: %CodingAgent.SettingsManager{
            compaction_enabled: false,
            keep_recent_tokens: 1,
            model_roles: %{},
            providers: %{executor_parent_question_test: %{api_key: "fake-key"}},
            extension_auto_load_default_paths: false
          }
      }
    end)

    # SessionRunner supplies the real builtin task tool. Gate its serialized join
    # reservation rather than replacing that tool or changing executor startup.
    join_barrier = fn
      :waiting,
      {:in, {:"$gen_call", {joiner, _tag}, {:begin_auto_followup_join, [^task_id], _token}}},
      _extra ->
        :atomics.put(join_gate, 1, 1)
        send(observer, {:question_join_started, self(), joiner})

        receive do
          {^gate, :join} ->
            :atomics.put(join_gate, 1, 2)
            :released
        after
          5_000 ->
            :atomics.put(join_gate, 1, 2)
            raise "parent question task join was not released"
        end

      status, _event, _extra ->
        status
    end

    assert :ok = :sys.install(TaskStoreServer, {join_barrier, :waiting})

    on_exit(fn ->
      if :atomics.compare_exchange(join_gate, 1, 1, 2) == :ok do
        send(Process.whereis(TaskStoreServer), {gate, :join})
      end

      :sys.remove(TaskStoreServer, join_barrier)
    end)

    join_call =
      tool_call("task", %{"action" => "join", "task_ids" => [task_id]}, id: "question-join")

    send(first_provider, {:respond, assistant_message_with_tool_calls([join_call])})
    assert_receive {:question_join_started, store, joiner}, 5_000
    assert :ok = :sys.suspend(session)

    {child, sender, delivery_ref, delivery, request_id} =
      try do
        child =
          Task.Supervisor.async_nolink(CodingAgent.TaskSupervisor, fn ->
            AskParent.execute(
              "executor-child-question",
              %{"question" => question, "why_blocked" => "The parent must choose the boundary."},
              nil,
              nil,
              tmp_dir,
              parent_session_module: QuestionDeliveryBarrier,
              parent_session_pid: observer,
              parent_session_key: req.session_key,
              parent_agent_id: "main",
              parent_run_id: req.run_id,
              child_run_id: child_run_id,
              child_scope_id: child_scope_id,
              task_id: task_id,
              task_description: "Blocked boundary child"
            )
          end)

        on_exit(fn ->
          monitor = Process.monitor(child.pid)
          Process.exit(child.pid, :kill)
          assert_receive {:DOWN, ^monitor, :process, _pid, _reason}, 5_000
        end)

        assert_receive {:question_delivery, sender, delivery_ref, text}, 5_000
        assert {:ok, pending} = ParentQuestions.open_request_for_child_scope(child_scope_id)
        assert pending.delivery_pending
        assert {:error, :not_found} = ParentQuestions.waiting_for_task_ids([task_id])
        delivery = :gen_server.send_request(session, {:deliver_parent_question, text})

        # A return trace is a barrier on the real join's source-gate check, not
        # a timing assertion that the loop happened not to finish yet.
        assert 1 =
                 :erlang.trace_pattern(
                   {ParentQuestions, :waiting_for_task_ids, 1},
                   [{:_, [], [{:return_trace}]}],
                   []
                 )

        on_exit(fn ->
          :erlang.trace_pattern({ParentQuestions, :waiting_for_task_ids, 1}, false, [])
        end)

        assert 1 = :erlang.trace(joiner, true, [:call, {:tracer, observer}])
        send(store, {gate, :join})

        assert_receive {:trace, ^joiner, :return_from,
                        {ParentQuestions, :waiting_for_task_ids, 1}, {:error, :not_found}},
                       5_000

        :erlang.trace(joiner, false, [:call])
        assert LemonAgent.Agent.get_state(agent).is_streaming
        assert Process.alive?(joiner)
        assert Process.alive?(session)
        assert Process.alive?(runner)
        assert {:ok, %{auto_followup_join_tokens: [_]}} = TaskStore.get_record(task_id)
        refute_receive {:question_provider, _, _}, 0
        refute_receive {:session_event, ^session_id, {:agent_end, _}}, 0
        refute_receive {:engine_event, ^run_ref, %{__event__: :completed}}, 0
        {child, sender, delivery_ref, delivery, pending.id}
      after
        :ok = :sys.resume(session)
      end

    assert {:reply, :ok} = :gen_server.receive_response(delivery, 5_000)
    assert [_question] = :sys.get_state(agent).follow_up_queue
    assert {:ok, %{delivery_pending: true}, _events} = ParentQuestions.get(request_id)
    assert {:error, :not_found} = ParentQuestions.waiting_for_task_ids([task_id])
    send(sender, {delivery_ref, :ok})

    assert_receive {:session_event, ^session_id,
                    {:tool_execution_end, "question-join", "task",
                     %AgentToolResult{
                       details: %{status: "needs_parent_answer", request_id: ^request_id}
                     }, false}},
                   5_000

    assert {:ok, %{delivery_pending: false}, _events} = ParentQuestions.get(request_id)
    assert_receive {:question_provider, after_join_provider, _context}, 5_000
    send(after_join_provider, {:respond, assistant_message(join_answer)})
    assert_receive {:question_provider, question_provider, context}, 5_000
    assert List.last(context.messages).role == :user
    assert List.last(context.messages).content =~ question

    %{
      run_ref: run_ref,
      runner: runner,
      runner_ref: runner_ref,
      session: session,
      session_ref: session_ref,
      session_id: session_id,
      agent: agent,
      provider: question_provider,
      child: child,
      child_run_id: child_run_id,
      task_id: task_id,
      request_id: request_id,
      session_key: req.session_key,
      question: question,
      join_answer: join_answer
    }
  end

  defp assert_question_run_active(run) do
    assert Process.alive?(run.session)
    assert Process.alive?(run.runner)
    assert LemonAgent.Agent.get_state(run.agent).is_streaming
    state = Session.get_state(run.session)
    assert state.is_streaming
    assert state.terminal_event == nil
    session_id = run.session_id
    run_ref = run.run_ref
    refute_receive {:session_event, ^session_id, {:agent_end, _}}, 0
    refute_receive {:session_event, ^session_id, {:error, _, _}}, 0
    refute_receive {:session_event, ^session_id, {:canceled, _}}, 0
    refute_receive {:engine_event, ^run_ref, %{__event__: :completed}}, 0
  end

  defp answer_question_child(run, answer) do
    assert :ok =
             ParentQuestions.answer(run.request_id, answer,
               session_key: run.session_key,
               agent_id: "main"
             )

    assert %AgentToolResult{details: %{status: "answered"}} = Task.await(run.child, 5_000)
    assert :ok = TaskStore.finish(run.task_id, answer)
    assert :ok = RunGraph.finish(run.child_run_id, answer)
  end

  defp assert_question_run_stopped(run) do
    %{session_ref: session_ref, session: session, runner_ref: runner_ref, runner: runner} = run
    assert_receive {:DOWN, ^session_ref, :process, ^session, _}, 5_000
    assert_receive {:DOWN, ^runner_ref, :process, ^runner, _}, 5_000
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
