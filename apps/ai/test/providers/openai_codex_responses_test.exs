defmodule Ai.Providers.OpenAICodexResponsesTest do
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.OpenAICodexResponses
  alias Ai.Types.{Context, Model, StreamOptions, Tool, UserMessage}

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

  test "request body snapshot includes instructions, tools, and reasoning" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    model = %Model{
      id: "gpt-5.2",
      name: "GPT-5.2",
      api: :openai_codex_responses,
      provider: :"openai-codex",
      base_url: "https://example.test",
      reasoning: true
    }

    tool = %Tool{
      name: "lookup",
      description: "Lookup data",
      parameters: %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}, "required" => ["q"]}
    }

    context = Context.new(system_prompt: "System", messages: [%UserMessage{content: "Hi"}], tools: [tool])

    payload = Jason.encode!(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acc_test"}})
    token = "x." <> Base.encode64(payload) <> ".y"

    opts =
      %StreamOptions{
        api_key: token,
        session_id: "sess-1",
        temperature: 0.7,
        reasoning: :low,
        thinking_budgets: %{summary: "concise", text_verbosity: "high"}
      }

    {:ok, stream} = OpenAICodexResponses.stream(model, context, opts)

    assert_receive {:request_body, body}, 1000

    expected = %{
      "model" => "gpt-5.2",
      "store" => false,
      "stream" => true,
      "instructions" => "System",
      "input" => [
        %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "Hi"}]}
      ],
      "text" => %{"verbosity" => "high"},
      "include" => ["reasoning.encrypted_content"],
      "prompt_cache_key" => "sess-1",
      "tool_choice" => "auto",
      "parallel_tool_calls" => true,
      "temperature" => 0.7,
      "tools" => [
        %{
          "type" => "function",
          "name" => "lookup",
          "description" => "Lookup data",
          "parameters" => %{"type" => "object", "properties" => %{"q" => %{"type" => "string"}}, "required" => ["q"]}
        }
      ],
      "reasoning" => %{"effort" => "low", "summary" => "concise"}
    }

    assert body == expected
    assert {:error, _} = EventStream.result(stream, 1000)
  end
end
