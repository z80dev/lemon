defmodule LemonAi.Providers.AnthropicStreamingTest do
  use ExUnit.Case, async: false

  alias LemonAi.EventStream
  alias LemonAi.Providers.Anthropic
  alias LemonAi.Types.{Context, Model, ModelCost, StreamOptions, TextContent, Tool, UserMessage}

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)

    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  defp sse_event(event, data) do
    "event: #{event}\n" <> "data: #{Jason.encode!(data)}\n\n"
  end

  defp model(base_url \\ "https://example.test") do
    %Model{
      id: "claude-test",
      name: "Claude Test",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: base_url,
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 10.0, output: 20.0, cache_read: 1.0, cache_write: 2.0},
      context_window: 100_000,
      max_tokens: 2048,
      headers: %{}
    }
  end

  defp kimi_model(base_url \\ "https://example.test") do
    %Model{
      id: "kimi-for-coding",
      name: "Kimi for Coding",
      api: :anthropic_messages,
      provider: :kimi,
      base_url: base_url,
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 10.0, output: 20.0, cache_read: 1.0, cache_write: 2.0},
      context_window: 128_000,
      max_tokens: 16_384,
      headers: %{}
    }
  end

  defp opencode_model(base_url \\ "https://opencode.ai/zen") do
    %Model{
      id: "claude-sonnet-4-6",
      name: "Claude Sonnet 4.6",
      api: :anthropic_messages,
      provider: :opencode,
      base_url: base_url,
      reasoning: true,
      input: [:text, :image],
      cost: %ModelCost{input: 3.0, output: 15.0, cache_read: 0.3, cache_write: 3.75},
      context_window: 1_000_000,
      max_tokens: 64_000,
      headers: %{}
    }
  end

  test "usage cost uses model pricing" do
    body =
      sse_event("message_start", %{
        "message" => %{
          "usage" => %{
            "input_tokens" => 100,
            "output_tokens" => 50,
            "cache_read_input_tokens" => 10,
            "cache_creation_input_tokens" => 5
          }
        }
      }) <>
        sse_event("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{}}) <>
        sse_event("message_stop", %{})

    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, body)
    end)

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})

    assert {:ok, result} = EventStream.result(stream, 1000)

    assert result.usage.input == 100
    assert result.usage.output == 50
    assert result.usage.cache_read == 10
    assert result.usage.cache_write == 5

    # 100*10 + 50*20 + 10*1 + 5*2 = 2020 per million tokens => 0.00202
    assert_in_delta result.usage.cost.total, 0.00202, 0.0000001
    assert_in_delta result.usage.cost.input, 0.001, 0.0000001
    assert_in_delta result.usage.cost.output, 0.001, 0.0000001
    assert_in_delta result.usage.cost.cache_read, 0.00001, 0.0000001
    assert_in_delta result.usage.cost.cache_write, 0.00001, 0.0000001
  end

  test "request body snapshot includes system, tools, and thinking config" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    model = %Model{
      id: "claude-3-7-sonnet-20250219",
      name: "Claude Sonnet 3.7",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://example.test",
      reasoning: true,
      input: [:text],
      cost: %ModelCost{},
      context_window: 200_000,
      max_tokens: 8192,
      headers: %{}
    }

    tool = %Tool{
      name: "lookup",
      description: "Lookup data",
      parameters: %{
        "type" => "object",
        "properties" => %{"q" => %{"type" => "string"}},
        "required" => ["q"]
      }
    }

    context =
      Context.new(
        system_prompt: "System",
        messages: [%UserMessage{content: [%TextContent{text: "Hi"}]}],
        tools: [tool]
      )

    opts = %StreamOptions{api_key: "test-key", max_tokens: 123, temperature: 0.2, reasoning: :low}

    {:ok, stream} = Anthropic.stream(model, context, opts)

    assert_receive {:request_body, body}, 1000

    expected = %{
      "model" => "claude-3-7-sonnet-20250219",
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"type" => "text", "text" => "Hi", "cache_control" => %{"type" => "ephemeral"}}
          ]
        }
      ],
      "max_tokens" => 8192,
      "stream" => true,
      "system" => [
        %{"type" => "text", "text" => "System", "cache_control" => %{"type" => "ephemeral"}}
      ],
      "temperature" => 1,
      "tools" => [
        %{
          "name" => "lookup",
          "description" => "Lookup data",
          "input_schema" => %{
            "type" => "object",
            "properties" => %{"q" => %{"type" => "string"}},
            "required" => ["q"]
          }
        }
      ],
      "thinking" => %{"type" => "enabled", "budget_tokens" => 4096}
    }

    assert body == expected
    assert {:error, _} = EventStream.result(stream, 1000)
  end

  test "kimi model reports provider-specific missing key guidance" do
    with_env(
      %{
        "KIMI_API_KEY" => nil,
        "MOONSHOT_API_KEY" => nil,
        "ANTHROPIC_API_KEY" => nil
      },
      fn ->
        context = Context.new(messages: [%UserMessage{content: "Hi"}])
        {:ok, stream} = Anthropic.stream(kimi_model(), context, %StreamOptions{})

        assert {:error, %{error_message: msg}} = EventStream.result(stream, 1_000)
        assert msg =~ "No API key provided for Kimi"
        assert msg =~ "KIMI_API_KEY"
      end
    )
  end

  test "opencode missing key guidance does not advertise ambient Anthropic fallback" do
    with_env(%{"OPENCODE_API_KEY" => nil, "ANTHROPIC_API_KEY" => "ambient"}, fn ->
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(opencode_model(), context, %StreamOptions{})

      assert {:error, %{error_message: msg}} = EventStream.result(stream, 1_000)
      assert msg =~ "OPENCODE_API_KEY"
      refute msg =~ "ANTHROPIC_API_KEY"
    end)
  end

  test "Kimi never borrows ANTHROPIC_API_KEY from another principal" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, :wrong_principal_request)
      Plug.Conn.send_resp(conn, 500, "unexpected request")
    end)

    with_env(
      %{
        "KIMI_API_KEY" => nil,
        "MOONSHOT_API_KEY" => nil,
        "ANTHROPIC_API_KEY" => "anthropic-fallback-key"
      },
      fn ->
        context = Context.new(messages: [%UserMessage{content: "Hi"}])
        {:ok, stream} = Anthropic.stream(kimi_model(), context, %StreamOptions{})
        assert {:error, _result} = EventStream.result(stream, 1_000)
      end
    )

    refute_received :wrong_principal_request
  end

  test "custom (binary) providers never receive the ambient ANTHROPIC_API_KEY" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:custom_req_headers, conn.req_headers})
      Plug.Conn.send_resp(conn, 500, "unexpected request")
    end)

    with_env(%{"ANTHROPIC_API_KEY" => "anthropic-ambient-key"}, fn ->
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      model = %{kimi_model() | provider: "my-claude-proxy"}
      {:ok, stream} = Anthropic.stream(model, context, %StreamOptions{})
      assert {:error, _} = EventStream.result(stream, 1_000)
    end)

    refute_received {:custom_req_headers, _headers}
  end

  test "explicitly keyless custom Anthropic endpoints omit credential headers" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:keyless_headers, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, sse_event("message_stop", %{}))
    end)

    with_env(%{"ANTHROPIC_API_KEY" => "ambient-decoy"}, fn ->
      model = %{model() | provider: "keyless-claude", compat: %{allow_missing_api_key: true}}
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model, context, %StreamOptions{})
      assert {:ok, _} = EventStream.result(stream, 1_000)
      assert_received {:keyless_headers, headers}
      refute Enum.any?(headers, fn {name, _} -> name in ["authorization", "x-api-key"] end)
      refute inspect(headers) =~ "ambient-decoy"
    end)
  end

  test "opencode model can use OPENCODE_API_KEY" do
    body =
      sse_event("message_start", %{"message" => %{"usage" => %{}}}) <>
        sse_event("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{}}) <>
        sse_event("message_stop", %{})

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:opencode_req_headers, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, body)
    end)

    with_env(
      %{
        "OPENCODE_API_KEY" => "opencode-fallback-key",
        "ANTHROPIC_API_KEY" => nil
      },
      fn ->
        context = Context.new(messages: [%UserMessage{content: "Hi"}])
        {:ok, stream} = Anthropic.stream(opencode_model(), context, %StreamOptions{})
        assert {:ok, _result} = EventStream.result(stream, 1_000)
      end
    )

    assert_receive {:opencode_req_headers, headers}, 1_000
    assert {"x-api-key", "opencode-fallback-key"} in headers
  end

  test "kimi preserves oversized history for caller-owned compaction" do
    with_env(
      %{
        "LEMON_KIMI_MAX_REQUEST_MESSAGES" => nil
      },
      fn ->
        test_pid = self()

        Req.Test.stub(__MODULE__, fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:kimi_limited_request_body, Jason.decode!(raw)})
          Plug.Conn.send_resp(conn, 400, "bad request")
        end)

        messages =
          for idx <- 1..230 do
            %UserMessage{content: "message #{idx}"}
          end

        context = Context.new(messages: messages)

        {:ok, stream} =
          Anthropic.stream(kimi_model(), context, %StreamOptions{api_key: "test-key"})

        assert_receive {:kimi_limited_request_body, body}, 1_000

        assert length(body["messages"]) == 230
        assert hd(body["messages"])["content"] == "message 1"
        assert [%{"text" => "message 230"}] = List.last(body["messages"])["content"]
        assert {:error, _} = EventStream.result(stream, 1_000)
      end
    )
  end

  test "retries retryable HTTP responses and succeeds" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(attempts), do: Agent.stop(attempts)
    end)

    body =
      sse_event("message_start", %{"message" => %{"usage" => %{}}}) <>
        sse_event("content_block_start", %{"index" => 0, "content_block" => %{"type" => "text"}}) <>
        sse_event("content_block_delta", %{
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "ok"}
        }) <>
        sse_event("content_block_stop", %{"index" => 0}) <>
        sse_event("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{}}) <>
        sse_event("message_stop", %{})

    Req.Test.stub(__MODULE__, fn conn ->
      if conn.host == "example.test" and conn.request_path == "/v1/messages" do
        attempt = Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end)

        if attempt == 1 do
          Plug.Conn.send_resp(conn, 503, "temporary outage")
        else
          Plug.Conn.send_resp(conn, 200, body)
        end
      else
        Plug.Conn.send_resp(conn, 404, "not found")
      end
    end)

    context = Context.new(messages: [%UserMessage{content: "Hi"}])
    {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})

    assert {:ok, result} = EventStream.result(stream, 2_000)
    assert result.stop_reason == :stop
    assert [%TextContent{text: "ok"} | _] = result.content
    assert Agent.get(attempts, & &1) == 2
  end

  test "does not retry non-retryable HTTP responses" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(attempts), do: Agent.stop(attempts)
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      if conn.host == "example.test" and conn.request_path == "/v1/messages" do
        Agent.update(attempts, &(&1 + 1))
        Plug.Conn.send_resp(conn, 400, "bad request")
      else
        Plug.Conn.send_resp(conn, 404, "not found")
      end
    end)

    context = Context.new(messages: [%UserMessage{content: "Hi"}])
    {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})

    assert {:error, _} = EventStream.result(stream, 1_000)
    assert Agent.get(attempts, & &1) == 1
  end

  test "retries empty HTTP 400 responses for kimi and succeeds" do
    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    on_exit(fn ->
      if Process.alive?(attempts), do: Agent.stop(attempts)
    end)

    body =
      sse_event("message_start", %{"message" => %{"usage" => %{}}}) <>
        sse_event("content_block_start", %{"index" => 0, "content_block" => %{"type" => "text"}}) <>
        sse_event("content_block_delta", %{
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "ok"}
        }) <>
        sse_event("content_block_stop", %{"index" => 0}) <>
        sse_event("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{}}) <>
        sse_event("message_stop", %{})

    Req.Test.stub(__MODULE__, fn conn ->
      attempt = Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end)

      if attempt == 1 do
        Plug.Conn.send_resp(conn, 400, "")
      else
        Plug.Conn.send_resp(conn, 200, body)
      end
    end)

    context = Context.new(messages: [%UserMessage{content: "Hi"}])
    {:ok, stream} = Anthropic.stream(kimi_model(), context, %StreamOptions{api_key: "test-key"})

    assert {:ok, result} = EventStream.result(stream, 2_000)
    assert result.stop_reason == :stop
    assert [%TextContent{text: "ok"} | _] = result.content
    assert Agent.get(attempts, & &1) == 2
  end

  describe "retry-after handling" do
    setup do
      previous = Application.get_env(:lemon_ai, :provider_retry)
      test_pid = self()

      Application.put_env(:lemon_ai, :provider_retry,
        sleep_fun: fn ms -> send(test_pid, {:slept, ms}) end
      )

      on_exit(fn -> Application.put_env(:lemon_ai, :provider_retry, previous || []) end)
      :ok
    end

    test "429 with retry-after waits that long, then retries and succeeds" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      body =
        sse_event("message_start", %{"message" => %{"usage" => %{}}}) <>
          sse_event("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}, "usage" => %{}}) <>
          sse_event("message_stop", %{})

      Req.Test.stub(__MODULE__, fn conn ->
        case Agent.get_and_update(attempts, fn n -> {n + 1, n + 1} end) do
          1 ->
            conn
            |> Plug.Conn.put_resp_header("retry-after", "7")
            |> Plug.Conn.send_resp(429, ~s({"type":"error","error":{"type":"rate_limit_error"}}))

          _ ->
            Plug.Conn.send_resp(conn, 200, body)
        end
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})

      assert {:ok, result} = EventStream.result(stream, 2_000)
      assert result.stop_reason == :stop
      assert Agent.get(attempts, & &1) == 2
      assert_received {:slept, 7_000}
      refute_received {:slept, _}
    end

    test "529 overloaded retries up to the attempt limit and exposes retry_after_ms" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        Agent.update(attempts, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_header("retry-after", "2")
        |> Plug.Conn.send_resp(529, ~s({"type":"error","error":{"type":"overloaded_error"}}))
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})

      assert {:error, %{stop_reason: :error, retry_after_ms: 2_000}} =
               EventStream.result(stream, 2_000)

      assert Agent.get(attempts, & &1) == 4
      for _ <- 1..3, do: assert_received({:slept, 2_000})
      refute_received {:slept, _}
    end

    test "does not sleep in-provider when the server asks for longer than the cap" do
      {:ok, attempts} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(__MODULE__, fn conn ->
        Agent.update(attempts, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_header("retry-after", "3600")
        |> Plug.Conn.send_resp(429, "rate limited")
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})

      assert {:error, %{retry_after_ms: 3_600_000}} = EventStream.result(stream, 2_000)
      assert Agent.get(attempts, & &1) == 1
      refute_received {:slept, _}
    end

    test "backs off exponentially from ~1s when no retry-after is sent" do
      Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})

      assert {:error, %{retry_after_ms: nil}} = EventStream.result(stream, 2_000)

      delays =
        for _ <- 1..3 do
          assert_received {:slept, ms}
          ms
        end

      [first, second, third] = delays
      assert first in 501..1_000
      assert second in 1_001..2_000
      assert third in 2_001..4_000
    end
  end

  describe "request shape" do
    test "tool_result images are sent as Anthropic image blocks" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      tool_result = %LemonAi.Types.ToolResultMessage{
        tool_call_id: "toolu_1",
        tool_name: "read",
        content: [
          %TextContent{text: "screenshot.png"},
          %LemonAi.Types.ImageContent{data: "iVBORw0KGgo=", mime_type: "image/png"}
        ]
      }

      assistant = %LemonAi.Types.AssistantMessage{
        content: [%LemonAi.Types.ToolCall{id: "toolu_1", name: "read", arguments: %{}}]
      }

      # Context.new keeps the given (chronological) order.
      context =
        Context.new(messages: [%UserMessage{content: "Look at it"}, assistant, tool_result])

      vision_model = %{model() | input: [:text, :image]}

      {:ok, stream} =
        Anthropic.stream(vision_model, context, %StreamOptions{api_key: "test-key"})

      assert_receive {:request_body, body}, 1_000
      assert {:error, _} = EventStream.result(stream, 1_000)

      [%{"type" => "tool_result", "tool_use_id" => "toolu_1", "content" => content}] =
        List.last(body["messages"])["content"]

      assert [
               %{"type" => "text", "text" => "screenshot.png"},
               %{
                 "type" => "image",
                 "source" => %{
                   "type" => "base64",
                   "media_type" => "image/png",
                   "data" => "iVBORw0KGgo="
                 }
               }
             ] = content
    end

    test "thinking shape follows the adaptive_thinking capability flag, not the model id" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request_body, Jason.decode!(raw)})
        Plug.Conn.send_resp(conn, 400, "bad request")
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      adaptive = %{
        model()
        | reasoning: true,
          adaptive_thinking: true,
          max_tokens: 8192,
          reasoning_efforts: [:low, :medium, :high, :xhigh]
      }

      for {reasoning, effort} <- [minimal: "low", high: "high", xhigh: "max"] do
        {:ok, stream} =
          Anthropic.stream(adaptive, context, %StreamOptions{
            api_key: "test-key",
            reasoning: reasoning
          })

        assert_receive {:request_body, body}, 1_000
        assert body["thinking"] == %{"type" => "adaptive"}
        assert body["output_config"] == %{"effort" => effort}
        assert {:error, _} = EventStream.result(stream, 1_000)
      end

      manual = %{adaptive | adaptive_thinking: false, reasoning_efforts: []}

      {:ok, stream} =
        Anthropic.stream(manual, context, %StreamOptions{api_key: "test-key", reasoning: :low})

      assert_receive {:request_body, body}, 1_000
      assert body["thinking"]["type"] == "enabled"
      refute Map.has_key?(body, "output_config")
      assert {:error, _} = EventStream.result(stream, 1_000)
    end
  end

  describe "request parity regressions" do
    setup do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:request, Jason.decode!(raw), Map.new(conn.req_headers)})
        Plug.Conn.send_resp(conn, 200, sse_event("message_stop", %{}))
      end)

      :ok
    end

    test "manual budgets and max_tokens stay within the model ceiling" do
      manual = %{model() | reasoning: true, max_tokens: 8192}
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      for {budget, expected} <- [{32_000, 4096}, {2048, 2048}] do
        {:ok, stream} =
          Anthropic.stream(manual, context, %StreamOptions{
            api_key: "test-key",
            max_tokens: 100_000,
            reasoning: :high,
            thinking_budgets: %{high: budget},
            temperature: 0.2
          })

        assert {:ok, _} = EventStream.result(stream, 1_000)
        assert_receive {:request, body, _headers}
        assert body["max_tokens"] == 8192
        assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => expected}
        assert body["temperature"] == 1
      end
    end

    test "adaptive thinking omits temperature and merges required betas without a 1M beta" do
      adaptive = %{
        model()
        | reasoning: true,
          adaptive_thinking: true,
          reasoning_efforts: [:low, :medium, :high],
          context_window: 1_000_000
      }

      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      for api_key <- ["test-key", "sk-ant-oat01-test-token"] do
        {:ok, stream} =
          Anthropic.stream(adaptive, context, %StreamOptions{
            api_key: api_key,
            reasoning: :xhigh,
            temperature: 0.2,
            headers: %{"Anthropic-Beta" => "custom-beta,effort-2025-11-24"}
          })

        assert {:ok, _} = EventStream.result(stream, 1_000)
        assert_receive {:request, body, headers}
        assert body["thinking"] == %{"type" => "adaptive"}
        assert body["output_config"] == %{"effort" => "high"}
        refute Map.has_key?(body, "temperature")
        betas = String.split(headers["anthropic-beta"], ",")
        assert "custom-beta" in betas
        assert Enum.count(betas, &(&1 == "effort-2025-11-24")) == 1
        refute Enum.any?(betas, &String.starts_with?(&1, "context-1m"))
      end
    end

    test "forced tool choice does not send incompatible thinking" do
      context =
        Context.new(
          messages: [%UserMessage{content: "Lookup"}],
          tools: [%Tool{name: "lookup", parameters: %{}}]
        )

      for adaptive? <- [false, true], choice <- [:any, "lookup"] do
        thinking_model = %{model() | reasoning: true, adaptive_thinking: adaptive?}

        {:ok, stream} =
          Anthropic.stream(thinking_model, context, %StreamOptions{
            api_key: "test-key",
            reasoning: :high,
            tool_choice: choice
          })

        assert {:ok, _} = EventStream.result(stream, 1_000)
        assert_receive {:request, body, _headers}
        refute Map.has_key?(body, "thinking")

        if adaptive? do
          assert body["output_config"] == %{"effort" => "low"}
        else
          refute Map.has_key?(body, "output_config")
        end
      end
    end

    test "caches the last string user message even when assistant history follows" do
      context =
        Context.new(
          messages: [
            %UserMessage{content: "First"},
            %UserMessage{content: "Cache me"},
            %LemonAi.Types.AssistantMessage{content: [%TextContent{text: "Prefill"}]}
          ]
        )

      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})
      assert {:ok, _} = EventStream.result(stream, 1_000)
      assert_receive {:request, body, _headers}
      assert [first, cached, assistant] = body["messages"]
      assert first["content"] == "First"

      assert cached["content"] == [
               %{
                 "type" => "text",
                 "text" => "Cache me",
                 "cache_control" => %{"type" => "ephemeral"}
               }
             ]

      assert assistant["content"] == [%{"type" => "text", "text" => "Prefill"}]
    end

    test "cache retention applies consistently to system and user blocks" do
      context = Context.new(system_prompt: "System", messages: [%UserMessage{content: "Hi"}])

      for {retention, expected} <- [
            none: nil,
            short: %{"type" => "ephemeral"},
            long: %{"type" => "ephemeral", "ttl" => "1h"}
          ] do
        {:ok, stream} =
          Anthropic.stream(model(), context, %StreamOptions{
            api_key: "test-key",
            provider_options: %{anthropic: %{cache_retention: retention}}
          })

        assert {:ok, _} = EventStream.result(stream, 1_000)
        assert_receive {:request, body, headers}
        assert hd(body["system"])["cache_control"] == expected

        if expected do
          assert hd(hd(body["messages"])["content"])["cache_control"] == expected
        else
          assert hd(body["messages"])["content"] == "Hi"
        end

        assert String.contains?(headers["anthropic-beta"], "extended-cache-ttl") ==
                 (retention == :long)
      end
    end

    test "summarized adaptive display follows compat capability without model id inference" do
      context = Context.new(messages: [%UserMessage{content: "Hi"}])

      for display? <- [false, true] do
        adaptive = %{
          model()
          | reasoning: true,
            adaptive_thinking: true,
            compat: %{anthropic_thinking_display: display?}
        }

        {:ok, stream} =
          Anthropic.stream(adaptive, context, %StreamOptions{
            api_key: "test-key",
            reasoning: :medium
          })

        assert {:ok, _} = EventStream.result(stream, 1_000)
        assert_receive {:request, body, _headers}
        assert body["thinking"]["type"] == "adaptive"
        assert body["thinking"]["display"] == if(display?, do: "summarized", else: nil)
      end
    end

    test "replays signed empty thinking blocks without dropping their signatures" do
      context =
        Context.new(
          messages: [
            %UserMessage{content: "Hi"},
            %LemonAi.Types.AssistantMessage{
              content: [
                %LemonAi.Types.ThinkingContent{thinking: "", thinking_signature: "opaque"},
                %TextContent{text: "Answer"}
              ]
            },
            %UserMessage{content: "Continue"}
          ]
        )

      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})
      assert {:ok, _} = EventStream.result(stream, 1_000)
      assert_receive {:request, body, _headers}

      assert Enum.at(body["messages"], 1)["content"] == [
               %{"type" => "thinking", "thinking" => "", "signature" => "opaque"},
               %{"type" => "text", "text" => "Answer"}
             ]
    end
  end

  describe "SSE parity regressions" do
    test "parses data-only event types, multiline data and CRLF across chunks" do
      body =
        ": keepalive\r\n\r\n" <>
          "data: {\"type\":\"content_block_start\",\r\n" <>
          "data: \"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"Hello\"}}\r\n\r\n" <>
          "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\" world\"}}\r\n\r\n" <>
          "data: {\"type\":\"content_block_stop\",\"index\":0}\r\n\r\n" <>
          "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}\r\n\r\n"

      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)

        Enum.reduce(:binary.bin_to_list(body), conn, fn byte, conn ->
          {:ok, conn} = Plug.Conn.chunk(conn, <<byte>>)
          conn
        end)
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})
      assert {:ok, result} = EventStream.result(stream, 1_000)
      assert result.stop_reason == :length
      assert [%TextContent{text: "Hello world"}] = result.content
    end

    test "preserves initial thinking signatures and complete tool inputs" do
      body =
        sse_event("content_block_start", %{
          "index" => 2,
          "content_block" => %{"type" => "thinking", "thinking" => "Plan", "signature" => "sig"}
        }) <>
          sse_event("content_block_delta", %{
            "index" => 2,
            "delta" => %{"type" => "signature_delta", "signature" => "-end"}
          }) <>
          sse_event("content_block_stop", %{"index" => 2}) <>
          sse_event("content_block_start", %{
            "index" => 4,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "tool_1",
              "name" => "lookup",
              "input" => %{"q" => "answer"}
            }
          }) <>
          sse_event("content_block_stop", %{"index" => 4}) <>
          sse_event("message_delta", %{"delta" => %{"stop_reason" => "tool_use"}})

      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, body))
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})
      assert {:ok, result} = EventStream.result(stream, 1_000)
      assert result.stop_reason == :tool_use

      assert [
               %LemonAi.Types.ThinkingContent{thinking: "Plan", thinking_signature: "sig-end"},
               %LemonAi.Types.ToolCall{arguments: %{"q" => "answer"}}
             ] = result.content
    end

    test "truncated responses fail while retaining streamed content and usage" do
      for body <- [
            "",
            sse_event("message_start", %{"message" => %{"usage" => %{"input_tokens" => 12}}}) <>
              sse_event("content_block_start", %{
                "index" => 0,
                "content_block" => %{"type" => "text", "text" => "Partial"}
              })
          ] do
        Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, body))
        context = Context.new(messages: [%UserMessage{content: "Hi"}])
        {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})
        assert {:error, result} = EventStream.result(stream, 1_000)
        assert result.error_message =~ "stream ended before"

        if body != "" do
          assert result.usage.input == 12
          assert [%TextContent{text: "Partial"}] = result.content
        end
      end
    end

    test "a streamed error cannot be overwritten by a trailing success envelope" do
      body =
        sse_event("error", %{"error" => %{"message" => "Overloaded"}}) <>
          sse_event("message_delta", %{"delta" => %{"stop_reason" => "end_turn"}}) <>
          sse_event("message_stop", %{})

      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, body))
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})
      assert {:error, %{error_message: "Overloaded"}} = EventStream.result(stream, 1_000)
    end

    test "usage snapshots preserve TTL subsets, replace counters and accept explicit zeros" do
      start_usage = %{
        "input_tokens" => 100,
        "output_tokens" => 2,
        "cache_read_input_tokens" => 20,
        "cache_creation_input_tokens" => 10,
        "cache_creation" => %{
          "ephemeral_5m_input_tokens" => 6,
          "ephemeral_1h_input_tokens" => 4
        }
      }

      for clear? <- [false, true] do
        delta_usage =
          if clear? do
            %{
              "input_tokens" => 0,
              "output_tokens" => 7,
              "cache_read_input_tokens" => 0,
              "cache_creation_input_tokens" => 0,
              "cache_creation" => %{}
            }
          else
            %{"output_tokens" => 7}
          end

        body =
          sse_event("message_start", %{"message" => %{"usage" => start_usage}}) <>
            sse_event("message_delta", %{
              "delta" => %{"stop_reason" => "end_turn"},
              "usage" => delta_usage
            })

        Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, body))
        context = Context.new(messages: [%UserMessage{content: "Hi"}])
        {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})
        assert {:ok, result} = EventStream.result(stream, 1_000)
        assert result.usage.output == 7
        assert result.usage.cost == LemonAi.calculate_cost(model(), result.usage)

        if clear? do
          assert result.usage.total_tokens == 7
          assert result.usage.cache_write_long == 0
          assert result.usage.cost.cache_write == 0
        else
          assert result.usage.total_tokens == 137
          assert result.usage.cache_write == 10
          assert result.usage.cache_write_long == 4
          assert_in_delta result.usage.cost.cache_write, 0.0000248, 0.00000001
        end
      end
    end

    test "TTL-only usage reports contribute cache writes exactly once" do
      body =
        sse_event("message_start", %{
          "message" => %{
            "usage" => %{
              "cache_creation" => %{
                "ephemeral_5m_input_tokens" => 6,
                "ephemeral_1h_input_tokens" => 4
              }
            }
          }
        }) <>
          sse_event("message_delta", %{
            "delta" => %{"stop_reason" => "end_turn"},
            "usage" => %{"output_tokens" => 1}
          })

      Req.Test.stub(__MODULE__, &Plug.Conn.send_resp(&1, 200, body))
      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})
      assert {:ok, result} = EventStream.result(stream, 1_000)
      assert result.usage.cache_write == 10
      assert result.usage.cache_write_long == 4
      assert result.usage.total_tokens == 11
    end

    test "HTTP context errors retain the body and are not retried despite a 5xx status" do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        send(test_pid, :http_attempt)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          500,
          Jason.encode!(%{
            "error" => %{"type" => "invalid_request_error", "message" => "prompt is too long"}
          })
        )
      end)

      context = Context.new(messages: [%UserMessage{content: "Hi"}])
      {:ok, stream} = Anthropic.stream(model(), context, %StreamOptions{api_key: "test-key"})
      assert {:error, %{error_message: "prompt is too long"}} = EventStream.result(stream, 1_000)
      assert_received :http_attempt
      refute_received :http_attempt
    end
  end

  defp with_env(env_map, fun) when is_map(env_map) and is_function(fun, 0) do
    previous =
      Enum.into(env_map, %{}, fn {name, _value} ->
        {name, System.get_env(name)}
      end)

    Enum.each(env_map, fn
      {name, value} when is_binary(value) -> System.put_env(name, value)
      {name, _} -> System.delete_env(name)
    end)

    try do
      fun.()
    after
      Enum.each(previous, fn
        {name, value} when is_binary(value) -> System.put_env(name, value)
        {name, _} -> System.delete_env(name)
      end)
    end
  end
end
