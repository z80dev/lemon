defmodule Ai.Providers.AzureOpenAIResponsesTest do
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.AzureOpenAIResponses
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

  test "request body snapshot includes tools and reasoning config" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    model = %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :azure_openai_responses,
      provider: :azure_openai,
      base_url: "https://azure.test/openai/v1",
      reasoning: true
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
      Context.new(system_prompt: "System", messages: [%UserMessage{content: "Hi"}], tools: [tool])

    opts =
      %StreamOptions{
        api_key: "azure-key",
        session_id: "sess-1",
        max_tokens: 55,
        temperature: 0.4,
        reasoning: :medium,
        thinking_budgets: %{summary: "auto"}
      }

    {:ok, stream} = AzureOpenAIResponses.stream(model, context, opts)

    assert_receive {:request_body, body}, 1000

    expected = %{
      "model" => "gpt-4o",
      "input" => [
        %{"role" => "developer", "content" => "System"},
        %{"role" => "user", "content" => [%{"type" => "input_text", "text" => "Hi"}]}
      ],
      "stream" => true,
      "prompt_cache_key" => "sess-1",
      "max_output_tokens" => 55,
      "temperature" => 0.4,
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
      "reasoning" => %{"effort" => "medium", "summary" => "auto"},
      "include" => ["reasoning.encrypted_content"]
    }

    assert body == expected
    assert {:error, _} = EventStream.result(stream, 1000)
  end
end
