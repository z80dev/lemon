defmodule Ai.Providers.BedrockTest do
  use ExUnit.Case, async: false

  alias Ai.EventStream
  alias Ai.Providers.Bedrock
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

  test "returns error when AWS credentials are missing" do
    prev_access = System.get_env("AWS_ACCESS_KEY_ID")
    prev_secret = System.get_env("AWS_SECRET_ACCESS_KEY")

    System.delete_env("AWS_ACCESS_KEY_ID")
    System.delete_env("AWS_SECRET_ACCESS_KEY")

    on_exit(fn ->
      if prev_access,
        do: System.put_env("AWS_ACCESS_KEY_ID", prev_access),
        else: System.delete_env("AWS_ACCESS_KEY_ID")

      if prev_secret,
        do: System.put_env("AWS_SECRET_ACCESS_KEY", prev_secret),
        else: System.delete_env("AWS_SECRET_ACCESS_KEY")
    end)

    model = %Model{
      id: "anthropic.claude-3-5-haiku-20241022-v1:0",
      name: "Claude 3.5 Haiku",
      api: :bedrock_converse_stream,
      provider: :amazon,
      base_url: ""
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])

    {:ok, stream} = Bedrock.stream(model, context, %StreamOptions{})

    assert {:error,
            %Ai.Types.AssistantMessage{
              stop_reason: :error,
              error_message: "AWS_ACCESS_KEY_ID not found"
            }} =
             EventStream.result(stream, 1000)
  end

  test "request body snapshot includes system, tools, cache points, and thinking config" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    model = %Model{
      id: "anthropic.claude-3-5-haiku-20241022-v1:0",
      name: "Claude 3.5 Haiku",
      api: :bedrock_converse_stream,
      provider: :amazon,
      base_url: "",
      reasoning: true,
      input: [:text]
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
        max_tokens: 123,
        temperature: 0.1,
        reasoning: :low,
        headers: %{
          "aws_access_key_id" => "AKIA_TEST",
          "aws_secret_access_key" => "SECRET",
          "aws_region" => "us-east-1"
        }
      }

    {:ok, stream} = Bedrock.stream(model, context, opts)

    assert_receive {:request_body, body}, 1000

    expected = %{
      "modelId" => "anthropic.claude-3-5-haiku-20241022-v1:0",
      "messages" => [
        %{
          "role" => "user",
          "content" => [
            %{"text" => "Hi"},
            %{"cachePoint" => %{"type" => "default"}}
          ]
        }
      ],
      "inferenceConfig" => %{"maxTokens" => 123, "temperature" => 0.1},
      "system" => [
        %{"text" => "System"},
        %{"cachePoint" => %{"type" => "default"}}
      ],
      "toolConfig" => %{
        "tools" => [
          %{
            "toolSpec" => %{
              "name" => "lookup",
              "description" => "Lookup data",
              "inputSchema" => %{
                "json" => %{
                  "type" => "object",
                  "properties" => %{"q" => %{"type" => "string"}},
                  "required" => ["q"]
                }
              }
            }
          }
        ]
      },
      "additionalModelRequestFields" => %{
        "thinking" => %{"type" => "enabled", "budget_tokens" => 2048}
      }
    }

    assert body == expected
    assert {:error, _} = EventStream.result(stream, 1000)
  end
end
