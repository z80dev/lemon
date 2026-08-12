defmodule CodingAgent.GatewayEngineRedirectTest do
  use ExUnit.Case

  alias CodingAgent.GatewayEngine, as: Lemon
  alias LemonGateway.Types.Job

  alias LemonAi.Types.{
    AssistantMessage,
    Cost,
    Model,
    ModelCost,
    TextContent,
    Usage
  }

  describe "supports_redirect?/0" do
    test "returns true" do
      assert Lemon.supports_redirect?() == true
    end
  end

  describe "redirect/2 without a runner" do
    test "returns error for nil runner_pid" do
      ctx = %{runner_pid: nil}
      assert Lemon.redirect(ctx, "test") == {:error, :no_runner}
    end

    test "returns error for missing runner_pid" do
      ctx = %{}
      assert Lemon.redirect(ctx, "test") == {:error, :no_runner}
    end
  end

  describe "redirect/2 on a direct session runner" do
    @tag :tmp_dir
    test "redirect cancels the in-flight call and the run completes with the retry answer",
         %{tmp_dir: tmp_dir} do
      parent = self()

      job =
        job(tmp_dir,
          prompt: "start working",
          run_id: "run-native-redirect",
          stream_fn: slow_then_quick_stream_fn(parent, assistant_message("after redirect"))
        )

      {:ok, run_ref, ctx} = Lemon.start_run(job, %{stream_fn: job.meta[:stream_fn]}, self())

      assert is_pid(ctx.runner_pid)
      assert_receive {:engine_event, ^run_ref, %{__event__: :started}}, 5_000
      assert_receive {:streaming_chunk, 2}, 5_000

      assert Lemon.redirect(ctx, "change course") == :ok

      assert_receive {:engine_event, ^run_ref, %{__event__: :completed, ok: true} = completed},
                     10_000

      assert completed.answer =~ "after redirect"
    end
  end

  # ============================================================================
  # Helpers
  # ============================================================================

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

  defp mock_usage do
    %Usage{
      input: 1,
      output: 1,
      cache_read: 0,
      cache_write: 0,
      total_tokens: 2,
      cost: %Cost{input: 0.0, output: 0.0, total: 0.0}
    }
  end

  defp assistant_message(text) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: :mock,
      provider: :mock_provider,
      model: "mock-model-1",
      usage: mock_usage(),
      stop_reason: :stop,
      error_message: nil,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp response_to_event_stream(response) do
    {:ok, stream} = LemonAi.EventStream.start_link()

    Task.start(fn ->
      LemonAi.EventStream.push(stream, {:start, response})

      response.content
      |> Enum.with_index()
      |> Enum.each(fn {content, idx} ->
        case content do
          %TextContent{text: text} ->
            LemonAi.EventStream.push(stream, {:text_start, idx, response})
            LemonAi.EventStream.push(stream, {:text_delta, idx, text, response})
            LemonAi.EventStream.push(stream, {:text_end, idx, response})

          _ ->
            :ok
        end
      end)

      LemonAi.EventStream.push(stream, {:done, response.stop_reason, response})
      LemonAi.EventStream.complete(stream, response)
    end)

    stream
  end

  # First call streams slowly (notifying the test per chunk); later calls
  # return `retry_response` immediately.
  defp slow_then_quick_stream_fn(parent, retry_response) do
    counter = :counters.new(1, [:atomics])

    fn _model, _context, _options ->
      :counters.add(counter, 1, 1)
      n = :counters.get(counter, 1)

      if n == 1 do
        {:ok, stream} = LemonAi.EventStream.start_link()

        Task.start(fn ->
          response = assistant_message("partial before redirect")
          LemonAi.EventStream.push(stream, {:start, response})

          for i <- 1..30 do
            send(parent, {:streaming_chunk, i})
            Process.sleep(30)
            LemonAi.EventStream.push(stream, {:text_delta, 0, "chunk #{i}", response})
          end

          LemonAi.EventStream.push(stream, {:done, :stop, response})
          LemonAi.EventStream.complete(stream, response)
        end)

        {:ok, stream}
      else
        {:ok, response_to_event_stream(retry_response)}
      end
    end
  end
end
