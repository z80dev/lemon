defmodule LemonGateway.LemonEngineTest do
  use ExUnit.Case

  alias Ai.Types.{
    AssistantMessage,
    Cost,
    Model,
    ModelCost,
    TextContent,
    ThinkingContent,
    ToolCall,
    Usage
  }

  alias LemonGateway.Engines.Lemon
  alias LemonGateway.Types.Job
  alias LemonCore.ResumeToken

  describe "id/0" do
    test "returns lemon" do
      assert Lemon.id() == "lemon"
    end
  end

  describe "format_resume/1" do
    test "formats resume token" do
      token = %ResumeToken{engine: "lemon", value: "session_abc123"}
      assert Lemon.format_resume(token) == "lemon resume session_abc123"
    end
  end

  describe "extract_resume/1" do
    test "extracts token from plain text" do
      text = "lemon resume abc123"
      assert %ResumeToken{engine: "lemon", value: "abc123"} = Lemon.extract_resume(text)
    end

    test "extracts token from backticks" do
      text = "`lemon resume session_xyz`"
      assert %ResumeToken{engine: "lemon", value: "session_xyz"} = Lemon.extract_resume(text)
    end

    test "extracts token case-insensitively" do
      text = "LEMON RESUME MySession123"
      assert %ResumeToken{engine: "lemon", value: "MySession123"} = Lemon.extract_resume(text)
    end

    test "returns nil for non-matching text" do
      assert Lemon.extract_resume("no resume here") == nil
    end

    test "returns nil for other engine tokens" do
      assert Lemon.extract_resume("codex resume abc") == nil
      assert Lemon.extract_resume("claude --resume xyz") == nil
    end
  end

  describe "is_resume_line/1" do
    test "returns true for exact resume line" do
      assert Lemon.is_resume_line("lemon resume abc123")
    end

    test "returns true for backtick-wrapped line" do
      assert Lemon.is_resume_line("`lemon resume abc123`")
    end

    test "returns true for line with whitespace" do
      assert Lemon.is_resume_line("  lemon resume abc123  ")
    end

    test "returns false for line with extra text" do
      refute Lemon.is_resume_line("Please run lemon resume abc123")
    end

    test "returns false for other engines" do
      refute Lemon.is_resume_line("codex resume abc123")
    end
  end

  describe "supports_steer?/0" do
    test "returns true" do
      assert Lemon.supports_steer?() == true
    end
  end

  describe "steer/2" do
    test "returns error for nil runner" do
      ctx = %{runner_pid: nil}
      assert Lemon.steer(ctx, "test") == {:error, :no_runner}
    end

    test "returns error for missing runner_pid" do
      ctx = %{}
      assert Lemon.steer(ctx, "test") == {:error, :no_runner}
    end
  end

  describe "start_run/3 direct session runner" do
    @tag :tmp_dir
    test "emits started, delta, tool action, and completed events", %{tmp_dir: tmp_dir} do
      tool_response =
        assistant_message_with_tool_calls([
          tool_call("bash", %{"command" => "printf gateway-tool"}, id: "call_gateway")
        ])

      final_response = assistant_message("gateway done")

      job =
        job(tmp_dir,
          prompt: "run the gateway tool",
          run_id: "run-native-lemon",
          stream_fn: mock_stream_fn([tool_response, final_response])
        )

      {:ok, run_ref, ctx} = Lemon.start_run(job, %{stream_fn: job.meta[:stream_fn]}, self())

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

      assert Enum.any?(messages, &match?({:engine_delta, ^run_ref, "gateway done"}, &1))

      assert {:engine_event, ^run_ref,
              %{
                __event__: :action_event,
                phase: :started,
                action: %{
                  id: "tool_call_gateway",
                  kind: "command",
                  title: "`printf gateway-tool`",
                  detail: %{name: "bash", args: %{"command" => "printf gateway-tool"}}
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
                action: %{id: "tool_call_gateway", kind: "command"}
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
                answer: "gateway done",
                resume: %ResumeToken{engine: "lemon", value: ^session_id}
              }} = List.last(messages)
    end

    @tag :tmp_dir
    test "emits approval action events while a gated tool waits", %{tmp_dir: tmp_dir} do
      command = "printf approval-gateway-#{System.unique_integer([:positive])}"

      tool_response =
        assistant_message_with_tool_calls([
          tool_call("bash", %{"command" => command}, id: "call_gateway_approval")
        ])

      final_response = assistant_message("approval timeout handled")

      job =
        job(tmp_dir,
          prompt: "run the gated gateway tool",
          run_id: "run-native-approval",
          stream_fn: mock_stream_fn([tool_response, final_response])
        )

      job = %{job | tool_policy: %{approvals: %{"bash" => "always"}}}

      {:ok, run_ref, _ctx} =
        Lemon.start_run(
          job,
          %{stream_fn: job.meta[:stream_fn], approval_timeout_ms: 20},
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

      job =
        job(tmp_dir,
          prompt: "think then answer",
          run_id: "run-native-reasoning",
          stream_fn: mock_stream_fn([response])
        )

      {:ok, run_ref, _ctx} = Lemon.start_run(job, %{stream_fn: job.meta[:stream_fn]}, self())

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

      job =
        job(tmp_dir,
          prompt: "think then answer",
          run_id: "run-native-reasoning-update",
          stream_fn: mock_stream_fn([response])
        )

      {:ok, run_ref, _ctx} = Lemon.start_run(job, %{stream_fn: job.meta[:stream_fn]}, self())

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

      job =
        job(tmp_dir,
          prompt: "start then cancel",
          run_id: "run-native-cancel-usage",
          stream_fn: mock_stream_fn([tool_response, :slow])
        )

      {:ok, run_ref, ctx} = Lemon.start_run(job, %{stream_fn: job.meta[:stream_fn]}, self())

      assert_receive {:engine_event, ^run_ref, %{__event__: :started}}, 2_000

      assert_receive {:engine_event, ^run_ref,
                      %{
                        __event__: :action_event,
                        phase: :completed,
                        action: %{id: "tool_call_cancel_usage"}
                      }},
                     2_000

      assert Lemon.cancel(ctx) == :ok

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
    test "supports steer and cancel on direct session runner", %{tmp_dir: tmp_dir} do
      job =
        job(tmp_dir,
          prompt: "wait",
          run_id: "run-native-cancel",
          stream_fn: slow_stream_fn()
        )

      {:ok, run_ref, ctx} = Lemon.start_run(job, %{stream_fn: job.meta[:stream_fn]}, self())

      assert_receive {:engine_event, ^run_ref, %{__event__: :started}}, 2_000
      assert Lemon.steer(ctx, "change course") == :ok
      assert Lemon.cancel(ctx) == :ok

      assert_receive {:engine_event, ^run_ref,
                      %{
                        __event__: :completed,
                        ok: false,
                        error: "Cancelled by user"
                      }},
                     2_000
    end
  end

  defp job(tmp_dir, opts) do
    %Job{
      run_id: Keyword.fetch!(opts, :run_id),
      session_key: "test:lemon:#{System.unique_integer([:positive])}",
      prompt: Keyword.fetch!(opts, :prompt),
      engine_id: "lemon",
      cwd: tmp_dir,
      meta: %{model: mock_model(), stream_fn: Keyword.fetch!(opts, :stream_fn)}
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
      {:ok, stream} = Ai.EventStream.start_link()

      Task.start(fn ->
        Process.sleep(10_000)
        response = assistant_message("too late")
        Ai.EventStream.push(stream, {:done, response.stop_reason, response})
        Ai.EventStream.complete(stream, response)
      end)

      {:ok, stream}
    end
  end

  defp response_to_event_stream(response) do
    {:ok, stream} = Ai.EventStream.start_link()

    Task.start(fn ->
      case response do
        :slow ->
          Process.sleep(10_000)
          response = assistant_message("too late")
          Ai.EventStream.push(stream, {:done, response.stop_reason, response})
          Ai.EventStream.complete(stream, response)

        %AssistantMessage{} ->
          Ai.EventStream.push(stream, {:start, response})

          response.content
          |> Enum.with_index()
          |> Enum.each(fn
            {%TextContent{text: text}, idx} ->
              Ai.EventStream.push(stream, {:text_start, idx, response})
              Ai.EventStream.push(stream, {:text_delta, idx, text, response})
              Ai.EventStream.push(stream, {:text_end, idx, response})

            {%ThinkingContent{thinking: thinking}, idx} ->
              Ai.EventStream.push(stream, {:thinking_start, idx, response})
              Ai.EventStream.push(stream, {:thinking_delta, idx, thinking, response})
              Ai.EventStream.push(stream, {:thinking_end, idx, thinking, response})

            {%ToolCall{} = tool_call, idx} ->
              Ai.EventStream.push(stream, {:tool_call_start, idx, tool_call, response})
              Ai.EventStream.push(stream, {:tool_call_end, idx, tool_call, response})

            {_content, _idx} ->
              :ok
          end)

          Ai.EventStream.push(stream, {:done, response.stop_reason, response})
          Ai.EventStream.complete(stream, response)
      end
    end)

    stream
  end
end
