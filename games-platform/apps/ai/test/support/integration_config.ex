defmodule Ai.Test.IntegrationConfig do
  @moduledoc """
  Configuration for AI integration tests.

  This module provides a unified way to configure integration tests
  for any AI provider. Configuration is read from environment variables:

  ## Environment Variables

  Required:
    - `INTEGRATION_API_KEY` - API key for the provider (falls back to ANTHROPIC_API_KEY)

  Optional:
    - `INTEGRATION_PROVIDER` - Provider name (default: "kimi")
    - `INTEGRATION_MODEL` - Model ID (default: "kimi-for-coding")
    - `INTEGRATION_BASE_URL` - API base URL (default: "https://api.kimi.com/coding")
    - `INTEGRATION_API_TYPE` - API type atom (default: "anthropic_messages")

  ## Usage

      # In tests
      if IntegrationConfig.configured?() do
        model = IntegrationConfig.model()
        # run tests...
      end

  ## Running Tests

      # With Kimi (default)
      source .env.kimi && mix test --include integration

      # With custom provider
      INTEGRATION_PROVIDER=anthropic \\
      INTEGRATION_MODEL=claude-3-5-haiku-20241022 \\
      INTEGRATION_BASE_URL=https://api.anthropic.com \\
      INTEGRATION_API_KEY=sk-... \\
      mix test --include integration
  """

  alias Ai.Types.{Model, ModelCost}

  @doc """
  Returns true if integration tests are configured (API key is set).
  """
  def configured? do
    api_key() not in [nil, ""]
  end

  @doc """
  Get the API key for integration tests.
  """
  def api_key do
    System.get_env("INTEGRATION_API_KEY") ||
      System.get_env("ANTHROPIC_API_KEY")
  end

  @doc """
  Get the provider name as an atom.
  """
  def provider do
    (System.get_env("INTEGRATION_PROVIDER") || "kimi")
    |> String.to_atom()
  end

  @doc """
  Get the model ID.
  """
  def model_id do
    System.get_env("INTEGRATION_MODEL") || "kimi-for-coding"
  end

  @doc """
  Get the API base URL.
  """
  def base_url do
    System.get_env("INTEGRATION_BASE_URL") || "https://api.kimi.com/coding"
  end

  @doc """
  Get the API type as an atom.
  """
  def api_type do
    (System.get_env("INTEGRATION_API_TYPE") || "anthropic_messages")
    |> String.to_atom()
  end

  @doc """
  Get the configured model struct for integration tests.
  """
  def model do
    %Model{
      id: model_id(),
      name: "Integration Test Model",
      api: api_type(),
      provider: provider(),
      base_url: base_url(),
      reasoning: false,
      input: [:text, :image],
      cost: %ModelCost{input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0},
      context_window: 200_000,
      max_tokens: 64_000,
      headers: %{}
    }
  end

  @doc """
  Returns a description of the current configuration for test output.
  """
  def describe do
    if configured?() do
      "provider=#{provider()}, model=#{model_id()}, base_url=#{base_url()}"
    else
      "NOT CONFIGURED (set INTEGRATION_API_KEY or ANTHROPIC_API_KEY)"
    end
  end

  @doc """
  Skip message to display when tests are skipped.
  """
  def skip_message do
    "Skipping integration test: #{describe()}"
  end
end
