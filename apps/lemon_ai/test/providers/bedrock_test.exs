defmodule LemonAi.Providers.BedrockLegacyTest do
  use ExUnit.Case, async: false

  alias LemonAi.EventStream
  alias LemonAi.Providers.Bedrock
  alias LemonAi.Types.{Context, Model, StreamOptions, Tool, UserMessage}

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
            %LemonAi.Types.AssistantMessage{
              stop_reason: :error,
              error_message: "AWS_ACCESS_KEY_ID not found"
            }} =
             EventStream.result(stream, 1000)

    {:ok, stream} =
      Bedrock.stream(model, context, %StreamOptions{
        headers: %{"aws_access_key_id" => "AKIAIOSFODNN7EXAMPLE"}
      })

    assert {:error,
            %LemonAi.Types.AssistantMessage{
              stop_reason: :error,
              error_message: "AWS_SECRET_ACCESS_KEY not found"
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

  test "adaptive thinking uses capabilities and keeps xhigh distinct from max" do
    model = %Model{
      id: "custom-adaptive-model",
      name: "Adaptive",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "",
      reasoning: true,
      adaptive_thinking: true,
      reasoning_efforts: [:low, :medium, :high, :xhigh, :max],
      compat: %{anthropic_thinking_display: true}
    }

    for effort <- [:xhigh, :max] do
      body = capture_request(model, effort)

      assert body["additionalModelRequestFields"] == %{
               "thinking" => %{"type" => "adaptive", "display" => "summarized"},
               "output_config" => %{"effort" => Atom.to_string(effort)}
             }

      refute Map.has_key?(body["inferenceConfig"], "temperature")
    end

    clamped = %{model | reasoning_efforts: [:low, :medium, :high]}
    body = capture_request(clamped, :max)
    assert body["additionalModelRequestFields"]["output_config"]["effort"] == "high"

    body = capture_request(model, :none)
    refute Map.has_key?(body, "additionalModelRequestFields")
  end

  test "Nova reasoning config is explicit and high effort omits incompatible inference fields" do
    model = %Model{
      id: "custom-nova-protocol",
      name: "Nova protocol",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "",
      reasoning: true,
      reasoning_efforts: [:low, :medium, :high],
      compat: %{bedrock_reasoning_config: true}
    }

    body = capture_request(model, :low)

    assert body["additionalModelRequestFields"] == %{
             "reasoningConfig" => %{"type" => "enabled", "maxReasoningEffort" => "low"}
           }

    assert body["inferenceConfig"] == %{"maxTokens" => 8192, "temperature" => 0.2}

    body = capture_request(model, :max)
    assert body["additionalModelRequestFields"]["reasoningConfig"]["maxReasoningEffort"] == "high"
    assert body["inferenceConfig"] == %{}

    body = capture_request(%{model | compat: %{}}, :high)
    refute Map.has_key?(body, "additionalModelRequestFields")
  end

  test "regional catalog endpoints supply the signing region unless explicitly overridden" do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      send(test_pid, {:request_host, conn.host, Plug.Conn.get_req_header(conn, "authorization")})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    model = %Model{
      id: "eu.anthropic.claude-opus-5-5",
      name: "Regional Claude",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "https://bedrock-runtime.eu-west-1.amazonaws.com"
    }

    context = Context.new(messages: [%UserMessage{content: "Hi"}])
    credentials = %{"aws_access_key_id" => "AKIA_TEST", "aws_secret_access_key" => "SECRET"}

    for {headers, region} <- [
          {credentials, "eu-west-1"},
          {Map.put(credentials, "aws_region", "eu-central-1"), "eu-central-1"}
        ] do
      {:ok, stream} = Bedrock.stream(model, context, %StreamOptions{headers: headers})
      assert_receive {:request_host, host, [authorization]}, 1000
      assert host == "bedrock-runtime.#{region}.amazonaws.com"
      assert authorization =~ "/#{region}/bedrock/aws4_request"
      assert {:error, _} = EventStream.result(stream, 1000)
    end
  end

  test "signed omitted thinking survives assistant replay" do
    model = %Model{
      id: "global.anthropic.claude-opus-5-5",
      name: "Claude",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: ""
    }

    context =
      Context.new(
        messages: [
          %UserMessage{content: "Hi"},
          %LemonAi.Types.AssistantMessage{
            content: [
              %LemonAi.Types.ThinkingContent{thinking: "", thinking_signature: "signed-thinking"},
              %LemonAi.Types.TextContent{text: "Hello"}
            ]
          },
          %UserMessage{content: "Continue"}
        ]
      )

    body = capture_request(model, nil, context)
    assistant = Enum.at(body["messages"], 1)

    assert hd(assistant["content"]) == %{
             "reasoningContent" => %{
               "reasoningText" => %{"text" => "", "signature" => "signed-thinking"}
             }
           }
  end

  defp capture_request(model, reasoning, context \\ nil) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, "bad request")
    end)

    opts = %StreamOptions{
      max_tokens: 8192,
      temperature: 0.2,
      reasoning: reasoning,
      headers: %{
        "aws_access_key_id" => "AKIA_TEST",
        "aws_secret_access_key" => "SECRET",
        "aws_region" => "us-east-1"
      }
    }

    context = context || Context.new(messages: [%UserMessage{content: "Hi"}])
    {:ok, stream} = Bedrock.stream(model, context, opts)
    assert_receive {:request_body, body}, 1000
    assert {:error, _} = EventStream.result(stream, 1000)
    body
  end
end
