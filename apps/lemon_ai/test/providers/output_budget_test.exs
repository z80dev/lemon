defmodule LemonAi.Providers.OutputBudgetTest do
  use ExUnit.Case, async: false

  alias LemonAi.{EventStream, Models}
  alias LemonAi.Providers
  alias LemonAi.Types.{Context, Model, StreamOptions, UserMessage}

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_ai)
    previous_defaults = Req.default_options()
    Req.default_options(plug: {Req.Test, __MODULE__})
    Req.Test.set_req_test_to_shared(%{})

    on_exit(fn ->
      Req.default_options(previous_defaults)
      Req.Test.set_req_test_to_private(%{})
    end)

    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, conn.request_path, Jason.decode!(raw)})
      Plug.Conn.send_resp(conn, 400, ~s({"error":{"message":"request captured"}}))
    end)

    :ok
  end

  @families [
    {Providers.Anthropic, :anthropic_messages, :anthropic, ["max_tokens"]},
    {Providers.OpenAICompletions, :openai_completions, :openai, ["max_completion_tokens"]},
    {Providers.OpenAIResponses, :openai_responses, :openai, ["max_output_tokens"]},
    {Providers.AzureOpenAIResponses, :azure_openai_responses, :azure_openai_responses,
     ["max_output_tokens"]},
    {Providers.Google, :google_generative_ai, :google, ["generationConfig", "maxOutputTokens"]},
    {Providers.GoogleVertex, :google_vertex, :google_vertex,
     ["generationConfig", "maxOutputTokens"]},
    {Providers.GoogleGeminiCli, :google_gemini_cli, :google_gemini_cli,
     ["request", "generationConfig", "maxOutputTokens"]},
    {Providers.Bedrock, :bedrock_converse_stream, :amazon_bedrock,
     ["inferenceConfig", "maxTokens"]},
    {Providers.MistralConversations, :mistral_conversations, :mistral, ["max_tokens"]}
  ]

  for {provider_module, api, provider, field_path} <- @families do
    test "#{api} preserves endpoint defaults and respects explicit overrides" do
      model = %Model{
        id: "budget-test-model",
        api: unquote(api),
        provider: unquote(provider),
        base_url: "https://example.test",
        max_tokens: 131_072
      }

      default = if unquote(api) == :anthropic_messages, do: 131_072

      for {requested, expected} <- [{nil, default}, {4_096, 4_096}] do
        opts = options(unquote(api), max_tokens: requested)
        body = capture(unquote(provider_module), model, opts)
        assert get_in(body, unquote(field_path)) == expected
      end
    end
  end

  test "Anthropic adaptive and manual thinking retain the full default budget" do
    for adaptive? <- [true, false] do
      model = %Model{
        id: "reasoning-model",
        api: :anthropic_messages,
        provider: :anthropic,
        base_url: "https://example.test",
        max_tokens: 131_072,
        reasoning: true,
        adaptive_thinking: adaptive?,
        reasoning_efforts: [:low, :medium, :high, :max]
      }

      body = capture(Providers.Anthropic, model, options(:anthropic_messages, reasoning: :high))
      assert body["max_tokens"] == 131_072

      if adaptive? do
        assert body["thinking"] == %{"type" => "adaptive"}
        assert body["output_config"] == %{"effort" => "high"}
      else
        assert body["thinking"] == %{"type" => "enabled", "budget_tokens" => 32_000}
      end
    end
  end

  test "ZAI coding GLM-5.3 sends documented effort values and the full budget" do
    for id <- ["glm-5.3", "glm-5.3-flash", "glm-5.3-flashx", "glm-5.3-highspeed"],
        {requested, expected} <- [
          {:low, "low"},
          {:medium, "high"},
          {:high, "high"},
          {:xhigh, "max"},
          {:max, "max"},
          {:minimal, "low"},
          {:none, "low"},
          {false, "low"}
        ] do
      model = Models.get_model(:zai, id)

      body =
        capture(
          Providers.OpenAICompletions,
          model,
          options(:openai_completions, reasoning: requested)
        )

      assert body["max_tokens"] == 131_072
      refute Map.has_key?(body, "max_completion_tokens")
      assert body["thinking"] == %{"type" => "enabled"}
      assert body["reasoning_effort"] == expected
    end
  end

  test "ZAI GLM-5.2 supports effort and disabled thinking without overriding token limits" do
    model = Models.get_model(:zai, "glm-5.2")

    for {requested, expected} <- [{:high, "high"}, {:xhigh, "max"}, {:medium, "high"}] do
      body =
        capture(
          Providers.OpenAICompletions,
          model,
          options(:openai_completions, reasoning: requested, max_tokens: 2_048)
        )

      assert body["max_tokens"] == 2_048
      assert body["thinking"] == %{"type" => "enabled"}
      assert body["reasoning_effort"] == expected
    end

    for requested <- [:none, false] do
      body =
        capture(
          Providers.OpenAICompletions,
          model,
          options(:openai_completions, reasoning: requested)
        )

      assert body["thinking"] == %{"type" => "disabled"}
      refute Map.has_key?(body, "reasoning_effort")
    end
  end

  test "older ZAI models send a full budget but not an unsupported effort field" do
    for id <- ["glm-4.6", "glm-4.7", "glm-5", "glm-5.1"] do
      model = Models.get_model(:zai, id)

      body =
        capture(
          Providers.OpenAICompletions,
          model,
          options(:openai_completions, reasoning: :high)
        )

      assert body["max_tokens"] == model.max_tokens
      assert body["thinking"] == %{"type" => "enabled"}
      refute Map.has_key?(body, "reasoning_effort")
    end
  end

  test "OpenAI-compatible presets retain their conservative capability declarations" do
    model = Models.get_model(:ollama, "local-model")

    body =
      capture(Providers.OpenAICompletions, model, options(:openai_completions, reasoning: :high))

    refute Map.has_key?(body, "max_tokens")
    refute Map.has_key?(body, "reasoning_effort")
  end

  test "non-ZAI chat providers leave output budgets to their servers" do
    for provider <- [:openrouter, :deepseek, :groq, :xai, :ollama, :vllm, :lm_studio, :custom] do
      model = %Model{
        id: "budget-test-model",
        api: :openai_completions,
        provider: provider,
        base_url: "https://example.test/v1",
        max_tokens: 131_072
      }

      body = capture(Providers.OpenAICompletions, model, options(:openai_completions, []))
      refute Map.has_key?(body, "max_tokens")
      refute Map.has_key?(body, "max_completion_tokens")
    end
  end

  test "Bedrock Nova high effort keeps the provider-required omission of maxTokens" do
    model = %Model{
      id: "nova-reasoning-model",
      api: :bedrock_converse_stream,
      provider: :amazon_bedrock,
      base_url: "",
      max_tokens: 131_072,
      reasoning: true,
      reasoning_efforts: [:low, :medium, :high],
      compat: %{bedrock_reasoning_config: true}
    }

    body = capture(Providers.Bedrock, model, options(:bedrock_converse_stream, reasoning: :high))
    refute Map.has_key?(body["inferenceConfig"], "maxTokens")
    assert body["additionalModelRequestFields"]["reasoningConfig"]["maxReasoningEffort"] == "high"
  end

  test "Codex subscription transport leaves output limits to its endpoint" do
    payload =
      Jason.encode!(%{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "test-account"}})

    token = "header." <> Base.encode64(payload) <> ".signature"

    model = %Model{
      id: "test-codex",
      provider: :openai_codex,
      api: :openai_codex_responses,
      max_tokens: 131_072
    }

    body =
      capture(Providers.OpenAICodexResponses, model, %StreamOptions{
        api_key: token,
        reasoning: :high
      })

    refute Map.has_key?(body, "max_output_tokens")
    assert body["reasoning"]["effort"] == "high"
  end

  defp capture(provider, model, opts) do
    context = Context.new(messages: [%UserMessage{content: "Hi"}])
    assert {:ok, stream} = provider.stream(model, context, opts)
    assert_receive {:request_body, path, body}, 1_000
    if model.provider == :zai, do: assert(path == "/api/coding/paas/v4/chat/completions")
    assert {:error, _} = EventStream.result(stream, 1_000)
    body
  end

  defp options(api, overrides) do
    auth =
      case api do
        :google_gemini_cli ->
          [api_key: Jason.encode!(%{"token" => "test-token", "projectId" => "test-project"})]

        :google_vertex ->
          [project: "test-project", location: "us-central1", access_token: "test-token"]

        :bedrock_converse_stream ->
          [
            headers: %{
              "aws_access_key_id" => "AKIA_TEST",
              "aws_secret_access_key" => "test-secret",
              "aws_region" => "us-east-1"
            }
          ]

        _ ->
          [api_key: "test-key"]
      end

    struct(StreamOptions, Keyword.merge(auth, overrides))
  end
end
