defmodule LemonCore.Secrets.EnvCatalog do
  @moduledoc """
  Canonical ordered catalog of environment-backed secrets shown by Lemon's
  check and bulk-import commands.

  This is intentionally narrower than `LemonCore.Env`: it preserves the
  operator-facing credential set and display order shared by the packaged CLI
  and contributor Mix tasks. Add a name here when those command surfaces
  should check and import it by default.
  """

  @names [
    # AI providers
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
    # Coding agent tools
    "PERPLEXITY_API_KEY",
    "OPENROUTER_API_KEY",
    "FIRECRAWL_API_KEY",
    "BRAVE_API_KEY",
    "EXA_API_KEY",
    "BROWSERBASE_API_KEY",
    "BROWSER_USE_API_KEY",
    "CAMOFOX_API_KEY",
    "GITHUB_TOKEN",
    # X/Twitter API
    "X_API_CLIENT_ID",
    "X_API_CLIENT_SECRET",
    "X_API_BEARER_TOKEN",
    "X_API_ACCESS_TOKEN",
    "X_API_REFRESH_TOKEN",
    "X_API_CONSUMER_KEY",
    "X_API_CONSUMER_SECRET",
    "X_API_ACCESS_TOKEN_SECRET",
    # Market intel
    "MARKET_INTEL_BASESCAN_KEY",
    "MARKET_INTEL_DEXSCREENER_KEY",
    "MARKET_INTEL_OPENAI_KEY",
    "MARKET_INTEL_ANTHROPIC_KEY"
  ]

  @doc "Returns the ordered environment-variable names checked by secrets tooling."
  @spec names() :: [String.t()]
  def names, do: @names
end
