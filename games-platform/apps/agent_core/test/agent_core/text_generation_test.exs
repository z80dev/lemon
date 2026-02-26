defmodule AgentCore.TextGenerationTest do
  use ExUnit.Case, async: true

  alias AgentCore.TextGeneration

  defmodule ModelRegistryStub do
    def get_model(:test_provider, "tweet-model"), do: %{id: "tweet-model"}
    def get_model(_, _), do: nil
  end

  defmodule ContextStub do
    defstruct system_prompt: nil, messages: []

    def new(opts) do
      %__MODULE__{system_prompt: Keyword.get(opts, :system_prompt)}
    end

    def add_user_message(%__MODULE__{} = ctx, prompt) do
      %{ctx | messages: [prompt | ctx.messages]}
    end
  end

  defmodule AiStub do
    def complete(model, context, opts) do
      send(self(), {:complete_called, model, context, opts})
      {:ok, %{text: "generated text"}}
    end

    def get_text(%{text: text}), do: text
  end

  defmodule AiErrorStub do
    def complete(_model, _context, _opts), do: {:error, :rate_limited}
    def get_text(_message), do: ""
  end

  defmodule RaisingModelRegistryStub do
    def get_model(_provider, _model_id), do: raise("registry exploded")
  end

  describe "complete_text/4" do
    test "returns model_not_found when model is missing" do
      assert {:error, {:model_not_found, :test_provider, "missing-model"}} =
               TextGeneration.complete_text(:test_provider, "missing-model", "hello",
                 model_registry: ModelRegistryStub,
                 context_module: ContextStub,
                 ai_module: AiStub
               )
    end

    test "builds context and forwards completion options" do
      assert {:ok, "generated text"} =
               TextGeneration.complete_text(:test_provider, "tweet-model", "write tweet",
                 system_prompt: "System prompt",
                 complete_opts: [max_tokens: 55, temperature: 0.25],
                 model_registry: ModelRegistryStub,
                 context_module: ContextStub,
                 ai_module: AiStub
               )

      assert_receive {:complete_called, %{id: "tweet-model"},
                      %ContextStub{
                        system_prompt: "System prompt",
                        messages: ["write tweet"]
                      }, %{max_tokens: 55, temperature: 0.25}}
    end

    test "normalizes invalid completion options to empty map" do
      assert {:ok, "generated text"} =
               TextGeneration.complete_text(:test_provider, "tweet-model", "write tweet",
                 complete_opts: :invalid,
                 model_registry: ModelRegistryStub,
                 context_module: ContextStub,
                 ai_module: AiStub
               )

      assert_receive {:complete_called, _model, _context, %{}}
    end

    test "passes through AI completion errors" do
      assert {:error, :rate_limited} =
               TextGeneration.complete_text(:test_provider, "tweet-model", "write tweet",
                 model_registry: ModelRegistryStub,
                 context_module: ContextStub,
                 ai_module: AiErrorStub
               )
    end

    test "wraps unexpected exceptions as ai_exception" do
      assert {:error, {:ai_exception, message}} =
               TextGeneration.complete_text(:test_provider, "tweet-model", "write tweet",
                 model_registry: RaisingModelRegistryStub,
                 context_module: ContextStub,
                 ai_module: AiStub
               )

      assert message =~ "registry exploded"
    end
  end
end
