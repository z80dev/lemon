defmodule LemonCore.Secrets.EnvCatalogTest do
  use ExUnit.Case, async: true

  alias LemonCore.Secrets.EnvCatalog

  @expected_names [
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "OPENAI_CODEX_API_KEY",
    "CHATGPT_TOKEN",
    "GOOGLE_GENERATIVE_AI_API_KEY",
    "GOOGLE_API_KEY",
    "GEMINI_API_KEY",
    "AWS_ACCESS_KEY_ID",
    "AWS_SECRET_ACCESS_KEY",
    "AWS_SESSION_TOKEN",
    "AZURE_OPENAI_API_KEY",
    "GROQ_API_KEY",
    "MISTRAL_API_KEY",
    "XAI_API_KEY",
    "CEREBRAS_API_KEY",
    "KIMI_API_KEY",
    "MOONSHOT_API_KEY",
    "OPENCODE_API_KEY",
    "PERPLEXITY_API_KEY",
    "OPENROUTER_API_KEY",
    "FIRECRAWL_API_KEY",
    "BRAVE_API_KEY",
    "GITHUB_TOKEN",
    "X_API_CLIENT_ID",
    "X_API_CLIENT_SECRET",
    "X_API_BEARER_TOKEN",
    "X_API_ACCESS_TOKEN",
    "X_API_REFRESH_TOKEN",
    "X_API_CONSUMER_KEY",
    "X_API_CONSUMER_SECRET",
    "X_API_ACCESS_TOKEN_SECRET",
    "MARKET_INTEL_BASESCAN_KEY",
    "MARKET_INTEL_DEXSCREENER_KEY",
    "MARKET_INTEL_OPENAI_KEY",
    "MARKET_INTEL_ANTHROPIC_KEY"
  ]

  test "preserves the operator-facing names and display order" do
    assert EnvCatalog.names() == @expected_names
  end

  test "contains unique environment-variable names" do
    names = EnvCatalog.names()

    assert length(names) == length(Enum.uniq(names))
    assert Enum.all?(names, &Regex.match?(~r/^[A-Z][A-Z0-9_]*$/, &1))
  end
end
