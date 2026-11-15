defmodule LemonAgent.GenAISpansTest do
  use ExUnit.Case, async: false

  alias LemonAgent.GenAISpans
  alias LemonAgent.Loop.ToolCalls
  alias LemonAgent.Types.{AgentContext, AgentLoopConfig, AgentTool, AgentToolResult}
  alias LemonAi.ModelCallTelemetry
  alias LemonAi.Types.ToolCall

  defmodule TestExporter do
    @behaviour LemonAgent.GenAISpans.Exporter

    @impl true
    def export_span(span, owner) do
      send(owner, {:exported_span, span})
      :ok
    end
  end

  defmodule FaultExporter do
    @behaviour LemonAgent.GenAISpans.Exporter

    @impl true
    def export_span(span, {owner, fault}) do
      send(owner, {:attempted_span, span})

      case fault do
        :raise -> raise "private exporter error"
        :throw -> throw("private exporter error")
        :exit -> exit("private exporter error")
        :error -> {:error, "private exporter error"}
      end
    end
  end

  test "export is disabled by default and needs no OpenTelemetry SDK" do
    assert GenAISpans.children([]) == []
    assert GenAISpans.children(exporter: TestExporter) == []
    assert [{GenAISpans, opts}] = GenAISpans.children(enabled: true, exporter: TestExporter)
    assert opts[:exporter] == TestExporter
    assert :opentelemetry_api in Application.spec(:lemon_agent, :optional_applications)
    refute :opentelemetry in Application.spec(:lemon_agent, :applications)
  end

  test "real model telemetry reaches a test exporter with only GenAI labels and usage" do
    start_exporter()

    span =
      ModelCallTelemetry.start(:anthropic,
        model_call: %{model: "test-model", call_kind: :complete, prompt: "private prompt"}
      )

    ModelCallTelemetry.stop_result(
      span,
      {:ok,
       %{
         usage: %{input: 12, output: 3, cache_read: 4, cache_write: 5},
         content: "private response",
         stop_reason: :stop
       }}
    )

    assert_receive {:exported_span, exported}
    assert exported.name == "chat test-model"
    assert exported.kind == :client
    assert exported.status == :unset

    assert exported.attributes == %{
             "gen_ai.operation.name" => "chat",
             "gen_ai.system" => "anthropic",
             "gen_ai.provider.name" => "anthropic",
             "gen_ai.request.model" => "test-model",
             "gen_ai.usage.input_tokens" => 21,
             "gen_ai.usage.output_tokens" => 3,
             "gen_ai.usage.cache_read.input_tokens" => 4,
             "gen_ai.usage.cache_write.input_tokens" => 5
           }

    assert exported.start_time == span.start_monotonic
    assert exported.end_time >= exported.start_time
    assert exported.duration == exported.end_time - exported.start_time
    refute inspect(exported) =~ "private"
    refute_received {:exported_span, _}
  end

  test "a stream terminal from another process preserves native timestamps and duration" do
    start_exporter()

    span =
      ModelCallTelemetry.start(:openai,
        model_call: %{model: "stream-model", call_kind: :stream}
      )

    duration = System.convert_time_unit(17, :millisecond, :native)
    ended_at = span.start_monotonic + duration

    task =
      Task.async(fn ->
        ModelCallTelemetry.stop_stream(span, {:ok, %{usage: %{input: 1}}}, nil, ended_at)
      end)

    Task.await(task)
    assert_receive {:exported_span, exported}
    assert exported.start_time == span.start_monotonic
    assert exported.end_time == ended_at
    assert exported.duration == duration
    assert System.convert_time_unit(exported.duration, :native, :millisecond) == 17
    assert exported.attributes["gen_ai.request.stream"] == true
    refute Map.has_key?(exported.attributes, "gen_ai.usage.input_tokens")
    refute Map.has_key?(exported.attributes, "gen_ai.usage.output_tokens")
  end

  test "known zero caches permit input totals while unknown categories remain unknown" do
    start_exporter()

    for {usage, expected} <- [
          {%{input: 8, cache_read: 0, cache_write: 0}, 8},
          {%{input: 0, cache_read: 0, cache_write: 0}, 0},
          {%{input: 8, cache_read: nil, cache_write: 0}, nil},
          {%{input: nil, cache_read: 2, cache_write: 0}, nil}
        ] do
      span = ModelCallTelemetry.start(:anthropic, [])
      ModelCallTelemetry.stop_result(span, {:ok, %{usage: usage}})
      assert_receive {:exported_span, exported}
      assert exported.attributes["gen_ai.usage.input_tokens"] == expected
    end
  end

  test "model errors and exceptions are marked without exporting raw error terms" do
    start_exporter()

    for finish <- [
          fn span -> ModelCallTelemetry.stop_failure(span, :canceled, :timeout) end,
          fn span ->
            ModelCallTelemetry.exception(span, :error, RuntimeError.exception("private"))
          end
        ] do
      span = ModelCallTelemetry.start(:openai, model_call: %{model: "failed-model"})
      finish.(span)
      assert_receive {:exported_span, exported}
      assert exported.status == :error
      assert exported.attributes["error.type"] == "model_call_error"
      assert exported.start_time == span.start_monotonic
      refute inspect(exported) =~ "private"
    end
  end

  test "real tool calls export success, returned errors and crashes without content" do
    start_exporter()

    for {name, execute, status, timeout?} <- [
          {"success", fn -> %AgentToolResult{content: [], details: %{secret: "private"}} end,
           :unset, false},
          {"error", fn -> {:error, "private error"} end, :error, false},
          {"timeout",
           fn ->
             %AgentToolResult{content: [], is_error: true, details: %{timed_out: true}}
           end, :error, true},
          {"crash", fn -> Process.exit(self(), :kill) end, :error, false}
        ] do
      run_tool(name, execute)
      assert_receive {:exported_span, exported}
      assert exported.name == "execute_tool #{name}"
      assert exported.kind == :internal
      assert exported.status == status
      assert exported.attributes["gen_ai.operation.name"] == "execute_tool"
      assert exported.attributes["gen_ai.tool.name"] == name
      assert exported.attributes["lemon.tool.timeout"] == timeout?
      assert exported.duration == exported.end_time - exported.start_time
      assert is_integer(exported.duration) and exported.duration >= 0
      refute inspect(exported) =~ "private"
      refute_received {:exported_span, _}
    end
  end

  test "tool and model durations have the same native unit and metadata is allowlisted" do
    start_exporter()
    duration = System.convert_time_unit(23, :millisecond, :native)
    ended_at = System.monotonic_time()

    for {prefix, metadata} <- [
          {[:lemon_ai, :model_call], %{provider: :openai, model: "unit-model", outcome: :ok}},
          {[:lemon_agent, :tool_call], %{tool_name: "unit-tool", is_error: false}}
        ] do
      :telemetry.execute(
        prefix ++ [:stop],
        %{duration: duration, monotonic_time: ended_at},
        Map.merge(metadata, %{
          prompt: "private",
          arguments: "private",
          result: "private",
          reason: "private",
          stacktrace: "private"
        })
      )

      assert_receive {:exported_span, exported}
      assert exported.start_time == ended_at - duration
      assert exported.end_time == ended_at
      assert exported.duration == duration
      refute inspect(exported) =~ "private"
    end
  end

  @tag capture_log: true
  test "exporter faults cannot fail model calls or detach the handler" do
    for fault <- [:raise, :throw, :exit, :error] do
      pid =
        start_supervised!({GenAISpans, exporter: FaultExporter, exporter_config: {self(), fault}})

      for _ <- 1..2 do
        span = ModelCallTelemetry.start(:openai, [])
        assert :ok = ModelCallTelemetry.stop_result(span, {:ok, %{}})
        assert_receive {:attempted_span, _}
      end

      assert Process.alive?(pid)
      stop_supervised!(GenAISpans)
    end
  end

  test "stopping the supervised attachment detaches all handlers" do
    start_exporter()
    handler_id = GenAISpans

    assert Enum.any?(
             :telemetry.list_handlers([:lemon_ai, :model_call, :stop]),
             &(&1.id == handler_id)
           )

    stop_supervised!(GenAISpans)

    refute Enum.any?(
             :telemetry.list_handlers([:lemon_ai, :model_call, :stop]),
             &(&1.id == handler_id)
           )
  end

  defp start_exporter do
    start_supervised!({GenAISpans, exporter: TestExporter, exporter_config: self()})
  end

  defp run_tool(name, execute) do
    tool = %AgentTool{
      name: name,
      label: name,
      description: "export fixture",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _, _, _, _ -> execute.() end
    }

    {:ok, stream} = LemonAgent.EventStream.start_link(timeout: :infinity)

    ToolCalls.execute_and_collect_tools(
      AgentContext.new(tools: [tool]),
      [],
      [%ToolCall{id: name, name: name, arguments: %{"private" => "private arguments"}}],
      %AgentLoopConfig{},
      nil,
      stream
    )

    LemonAgent.EventStream.complete(stream, [])
  end
end
