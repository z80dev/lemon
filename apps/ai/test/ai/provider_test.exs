defmodule Ai.ProviderTest do
  @moduledoc """
  Tests for the Ai.Provider behaviour.

  This module verifies that the Provider behaviour is correctly defined
  and that implementations properly adhere to the contract.
  """
  use ExUnit.Case, async: true

  alias Ai.Types.{Context, Model, StreamOptions}

  # ============================================================================
  # Test Implementation Modules
  # ============================================================================

  defmodule ValidProvider do
    @behaviour Ai.Provider

    @impl true
    def stream(%Model{} = _model, %Context{} = _context, %StreamOptions{} = _opts) do
      # Return a mock stream pid for testing
      {:ok, self()}
    end

    @impl true
    def get_env_api_key do
      System.get_env("TEST_API_KEY")
    end

    @impl true
    def provider_id, do: :valid_provider

    @impl true
    def api_id, do: :valid_api
  end

  defmodule MinimalProvider do
    @behaviour Ai.Provider

    @impl true
    def stream(%Model{} = _model, %Context{} = _context, %StreamOptions{} = _opts) do
      {:ok, self()}
    end

    @impl true
    def provider_id, do: :minimal_provider

    @impl true
    def api_id, do: :minimal_api

    # Note: get_env_api_key is optional
  end

  # ============================================================================
  # Behaviour Contract Tests
  # ============================================================================

  describe "behaviour contract" do
    test "valid provider implements all required callbacks" do
      # Verify the module implements the behaviour
      assert function_exported?(ValidProvider, :stream, 3)
      assert function_exported?(ValidProvider, :provider_id, 0)
      assert function_exported?(ValidProvider, :api_id, 0)
      assert function_exported?(ValidProvider, :get_env_api_key, 0)
    end

    test "minimal provider implements required callbacks" do
      assert function_exported?(MinimalProvider, :stream, 3)
      assert function_exported?(MinimalProvider, :provider_id, 0)
      assert function_exported?(MinimalProvider, :api_id, 0)
      # get_env_api_key is optional
    end

    test "stream/3 returns expected type" do
      model = %Model{
        id: "test-model",
        name: "Test Model",
        api: :test_api,
        provider: :test_provider,
        reasoning: false,
        input: [:text],
        cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 1000,
        max_tokens: 100
      }

      context = %Context{
        messages: [],
        tools: [],
        system_prompt: nil
      }

      opts = %StreamOptions{}

      result = ValidProvider.stream(model, context, opts)
      assert match?({:ok, _pid}, result)
    end

    test "provider_id/0 returns an atom" do
      assert ValidProvider.provider_id() == :valid_provider
      assert is_atom(ValidProvider.provider_id())
    end

    test "api_id/0 returns an atom" do
      assert ValidProvider.api_id() == :valid_api
      assert is_atom(ValidProvider.api_id())
    end

    test "get_env_api_key/0 returns string or nil" do
      result = ValidProvider.get_env_api_key()
      assert is_binary(result) or is_nil(result)
    end
  end

  # ============================================================================
  # Real Provider Adherence Tests
  # ============================================================================

  describe "real provider implementations" do
    test "Anthropic provider adheres to behaviour" do
      assert_behaviour_implementation(Ai.Providers.Anthropic)
    end

    test "OpenAIResponses provider adheres to behaviour" do
      assert_behaviour_implementation(Ai.Providers.OpenAIResponses)
    end

    test "Google provider adheres to behaviour" do
      assert_behaviour_implementation(Ai.Providers.Google)
    end

    test "GoogleVertex provider adheres to behaviour" do
      assert_behaviour_implementation(Ai.Providers.GoogleVertex)
    end

    test "GoogleGeminiCli provider adheres to behaviour" do
      assert_behaviour_implementation(Ai.Providers.GoogleGeminiCli)
    end

    test "Bedrock provider adheres to behaviour" do
      assert_behaviour_implementation(Ai.Providers.Bedrock)
    end

    test "AzureOpenAIResponses provider adheres to behaviour" do
      assert_behaviour_implementation(Ai.Providers.AzureOpenAIResponses)
    end

    test "OpenAICompletions provider adheres to behaviour" do
      assert_behaviour_implementation(Ai.Providers.OpenAICompletions)
    end

    test "OpenAICodexResponses provider adheres to behaviour" do
      assert_behaviour_implementation(Ai.Providers.OpenAICodexResponses)
    end
  end

  # ============================================================================
  # Provider Metadata Tests
  # ============================================================================

  describe "provider metadata consistency" do
    test "all providers have unique api_ids" do
      providers = [
        Ai.Providers.Anthropic,
        Ai.Providers.OpenAIResponses,
        Ai.Providers.Google,
        Ai.Providers.GoogleVertex,
        Ai.Providers.GoogleGeminiCli,
        Ai.Providers.Bedrock,
        Ai.Providers.AzureOpenAIResponses,
        Ai.Providers.OpenAICompletions,
        Ai.Providers.OpenAICodexResponses
      ]

      api_ids = Enum.map(providers, & &1.api_id())

      assert length(api_ids) == length(Enum.uniq(api_ids)),
             "API IDs must be unique"
    end

    test "provider_id and api_id are different concepts" do
      # provider_id identifies the provider implementation
      # api_id identifies the API endpoint type
      # They can be the same or different depending on the provider
      providers = [
        Ai.Providers.Anthropic,
        Ai.Providers.OpenAIResponses,
        Ai.Providers.Google
      ]

      for provider <- providers do
        assert is_atom(provider.provider_id())
        assert is_atom(provider.api_id())
      end
    end

    test "api_ids are well-known atoms" do
      # These are the expected API identifiers used in the system
      expected_api_ids = [
        :anthropic_messages,
        :openai_responses,
        :google_generative_ai,
        :google_vertex,
        :google_gemini_cli,
        :bedrock_converse_stream,
        :azure_openai_responses,
        :openai_completions,
        :openai_codex_responses
      ]

      providers = [
        Ai.Providers.Anthropic,
        Ai.Providers.OpenAIResponses,
        Ai.Providers.Google,
        Ai.Providers.GoogleVertex,
        Ai.Providers.GoogleGeminiCli,
        Ai.Providers.Bedrock,
        Ai.Providers.AzureOpenAIResponses,
        Ai.Providers.OpenAICompletions,
        Ai.Providers.OpenAICodexResponses
      ]

      for provider <- providers do
        api_id = provider.api_id()
        assert api_id in expected_api_ids,
               "#{provider}.api_id() returned unexpected value: #{inspect(api_id)}"
      end
    end
  end

  # ============================================================================
  # StreamOptions Handling
  # ============================================================================

  describe "stream options handling" do
    test "providers accept StreamOptions struct" do
      model = %Model{
        id: "test-model",
        name: "Test",
        api: :test,
        provider: :test,
        reasoning: false,
        input: [:text],
        cost: %{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
        context_window: 1000,
        max_tokens: 100
      }

      context = %Context{messages: []}

      opts = %StreamOptions{
        temperature: 0.7,
        max_tokens: 100,
        api_key: "test-key"
      }

      # Verify the types are correct
      assert %StreamOptions{} = opts
      assert opts.temperature == 0.7
      assert opts.max_tokens == 100
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp assert_behaviour_implementation(provider_module) do
    # Ensure the module is loaded
    Code.ensure_loaded!(provider_module)

    # Check all required callbacks are exported
    # Note: We use module_info to check exports since function_exported?
    # may return false for modules not yet loaded in test context
    exports = provider_module.module_info(:exports)

    assert {:stream, 3} in exports,
           "#{provider_module} must implement stream/3"

    assert {:provider_id, 0} in exports,
           "#{provider_module} must implement provider_id/0"

    assert {:api_id, 0} in exports,
           "#{provider_module} must implement api_id/0"

    # Check return types by calling the functions
    provider_id = provider_module.provider_id()
    assert is_atom(provider_id), "provider_id/0 must return an atom"

    api_id = provider_module.api_id()
    assert is_atom(api_id), "api_id/0 must return an atom"

    # Check optional callback
    if {:get_env_api_key, 0} in exports do
      result = provider_module.get_env_api_key()
      assert is_binary(result) or is_nil(result),
             "get_env_api_key/0 must return a string or nil"
    end

    :ok
  end
end
