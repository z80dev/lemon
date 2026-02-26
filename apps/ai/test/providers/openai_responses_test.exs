defmodule Ai.Providers.OpenAIResponsesTest do
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.OpenAIResponses
  alias Ai.Types.{Context, ImageContent, Model, StreamOptions, UserMessage}

  setup do
    {:ok, _} = Application.ensure_all_started(:ai)

    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    :ok
  end

  defp sse_body(events) do
    events
    |> Enum.map(fn
      :done -> "data: [DONE]"
      event -> "data: " <> Jason.encode!(event)
    end)
    |> Enum.join("\n\n")
    |> Kernel.<>("\n\n")
  end

  test "omits reasoning config when not requested" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "o1-mini",
      name: "o1-mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.test",
      reasoning: true
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_body, req_body}, 1000
    refute Map.has_key?(req_body, "reasoning")
    refute Map.has_key?(req_body, "include")

    assert {:ok, _} = EventStream.result(stream, 1000)
  end

  test "adds GPT-5 disable message when reasoning is nil" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "gpt-5",
      name: "gpt-5",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.test",
      reasoning: true
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_body, req_body}, 1000
    refute Map.has_key?(req_body, "reasoning")

    juice_messages =
      req_body
      |> Map.get("input", [])
      |> Enum.filter(fn msg ->
        msg["role"] == "developer" and
          Enum.any?(msg["content"] || [], fn part ->
            is_binary(part["text"]) and String.contains?(part["text"], "Juice: 0")
          end)
      end)

    assert length(juice_messages) == 1

    assert {:ok, _} = EventStream.result(stream, 1000)
  end

  test "adds GPT-5 disable message when name is uppercase" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "gpt-5",
      name: "GPT-5",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.test",
      reasoning: true
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_body, req_body}, 1000
    refute Map.has_key?(req_body, "reasoning")

    juice_messages =
      req_body
      |> Map.get("input", [])
      |> Enum.filter(fn msg ->
        msg["role"] == "developer" and
          Enum.any?(msg["content"] || [], fn part ->
            is_binary(part["text"]) and String.contains?(part["text"], "Juice: 0")
          end)
      end)

    assert length(juice_messages) == 1

    assert {:ok, _} = EventStream.result(stream, 1000)
  end

  test "includes reasoning config when requested" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "o1-mini",
      name: "o1-mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.test",
      reasoning: true
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} =
      OpenAIResponses.stream(
        model,
        context,
        %StreamOptions{api_key: "test-key", reasoning: :low}
      )

    assert_receive {:request_body, req_body}, 1000
    assert %{"effort" => "low"} = req_body["reasoning"]
    assert "reasoning.encrypted_content" in (req_body["include"] || [])

    assert {:ok, _} = EventStream.result(stream, 1000)
  end

  test "adds copilot headers for :github_copilot" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request_headers, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_responses,
      provider: :github_copilot,
      base_url: "https://example.test",
      reasoning: false,
      input: [:text, :image]
    }

    image = %ImageContent{data: "AA==", mime_type: "image/png"}
    context = Context.new(messages: [%UserMessage{content: [image]}])

    {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{api_key: "test-key"})

    assert_receive {:request_headers, headers}, 1000
    headers_map = Map.new(headers)

    assert headers_map["editor-version"] == "vscode/1.107.0"
    assert headers_map["editor-plugin-version"] == "copilot-chat/0.35.0"
    assert headers_map["user-agent"] == "GitHubCopilotChat/0.35.0"
    assert headers_map["copilot-integration-id"] == "vscode-chat"
    assert headers_map["x-initiator"] == "user"
    assert headers_map["openai-intent"] == "conversation-edits"
    assert headers_map["copilot-vision-request"] == "true"

    assert {:ok, _} = EventStream.result(stream, 1000)
  end

  test "request body snapshot includes tools, reasoning, and service tier" do
    test_pid = self()

    prev_retention = System.get_env("PI_CACHE_RETENTION")
    System.delete_env("PI_CACHE_RETENTION")

    on_exit(fn ->
      if prev_retention,
        do: System.put_env("PI_CACHE_RETENTION", prev_retention),
        else: System.delete_env("PI_CACHE_RETENTION")
    end)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    model = %Model{
      id: "gpt-5",
      name: "GPT-5",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://api.openai.com",
      reasoning: true
    }

    tool = %Ai.Types.Tool{
      name: "lookup",
      description: "Lookup data",
      parameters: %{
        "type" => "object",
        "properties" => %{"q" => %{"type" => "string"}},
        "required" => ["q"]
      }
    }

    context =
      Context.new(system_prompt: "System", messages: [%UserMessage{content: "Hi"}], tools: [tool])

    opts =
      %StreamOptions{
        api_key: "test-key",
        session_id: "sess-1",
        max_tokens: 123,
        temperature: 0.1,
        reasoning: :low,
        thinking_budgets: %{summary: "concise", service_tier: "flex"}
      }

    {:ok, stream} = OpenAIResponses.stream(model, context, opts)

    assert_receive {:request_body, body}, 1000

    expected = %{
      "model" => "gpt-5",
      "input" => [
        %{"role" => "developer", "content" => "System"},
        %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "Hi"}]}
      ],
      "stream" => true,
      "prompt_cache_key" => "sess-1",
      "max_output_tokens" => 123,
      "temperature" => 0.1,
      "service_tier" => "flex",
      "tools" => [
        %{
          "type" => "function",
          "name" => "lookup",
          "description" => "Lookup data",
          "parameters" => %{
            "type" => "object",
            "properties" => %{"q" => %{"type" => "string"}},
            "required" => ["q"]
          },
          "strict" => false
        }
      ],
      "reasoning" => %{"effort" => "low", "summary" => "concise"},
      "include" => ["reasoning.encrypted_content"]
    }

    assert body == expected
    assert {:error, _} = EventStream.result(stream, 1000)
  end

  test "errors when api key is missing" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request_called, true})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "gpt-4o-mini",
      name: "GPT-4o mini",
      api: :openai_responses,
      provider: :openai,
      base_url: "https://example.test",
      reasoning: false
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    prev_key = System.get_env("OPENAI_API_KEY")
    System.delete_env("OPENAI_API_KEY")

    on_exit(fn ->
      if prev_key,
        do: System.put_env("OPENAI_API_KEY", prev_key),
        else: System.delete_env("OPENAI_API_KEY")
    end)

    {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{api_key: nil})

    assert {:error, %Ai.Types.AssistantMessage{stop_reason: :error}} =
             EventStream.result(stream, 1000)

    refute_received {:request_called, _}
  end

  test "uses OPENCODE_API_KEY for opencode provider when api_key option is missing" do
    test_pid = self()
    prev_opencode = System.get_env("OPENCODE_API_KEY")
    prev_openai = System.get_env("OPENAI_API_KEY")

    on_exit(fn ->
      if is_binary(prev_opencode) do
        System.put_env("OPENCODE_API_KEY", prev_opencode)
      else
        System.delete_env("OPENCODE_API_KEY")
      end

      if is_binary(prev_openai) do
        System.put_env("OPENAI_API_KEY", prev_openai)
      else
        System.delete_env("OPENAI_API_KEY")
      end
    end)

    System.put_env("OPENCODE_API_KEY", "opencode-env-key")
    System.put_env("OPENAI_API_KEY", "openai-env-key")

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request_headers, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, sse_body([:done]))
    end)

    model = %Model{
      id: "gpt-5",
      name: "GPT-5",
      api: :openai_responses,
      provider: :opencode,
      base_url: "https://opencode.ai/zen/v1",
      reasoning: true
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = OpenAIResponses.stream(model, context, %StreamOptions{})

    assert_receive {:request_headers, headers}, 1000
    assert Map.new(headers)["authorization"] == "Bearer opencode-env-key"
    assert {:ok, _} = EventStream.result(stream, 1000)
  end
end
