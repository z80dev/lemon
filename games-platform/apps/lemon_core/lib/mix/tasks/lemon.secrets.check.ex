defmodule Mix.Tasks.Lemon.Secrets.Check do
  use Mix.Task

  alias LemonCore.Secrets

  @shortdoc "Check secret resolution sources"
  @moduledoc """
  Reports the resolution source for each known secret — whether it resolves
  from the encrypted store, from an env var, or is missing entirely.

  Usage:
      mix lemon.secrets.check
  """

  @known_secrets [
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

  def known_secrets, do: @known_secrets

  @impl true
  def run(_args) do
    start_lemon_core!()

    # Find the longest name for column alignment
    max_name_len =
      @known_secrets
      |> Enum.map(&String.length/1)
      |> Enum.max()

    # Header
    Mix.shell().info(
      String.pad_trailing("NAME", max_name_len) <> "  SOURCE   VALUE"
    )

    Mix.shell().info(String.duplicate("-", max_name_len + 30))

    results = Enum.map(@known_secrets, &check_secret(&1, max_name_len))

    from_store = Enum.count(results, &(&1 == :store))
    from_env = Enum.count(results, &(&1 == :env))
    missing = Enum.count(results, &(&1 == :missing))

    Mix.shell().info("")
    Mix.shell().info("#{from_store} from store, #{from_env} from env, #{missing} missing")
  end

  defp check_secret(name, max_name_len) do
    case Secrets.resolve(name) do
      {:ok, value, source} ->
        padded_name = String.pad_trailing(name, max_name_len)
        padded_source = String.pad_trailing(to_string(source), 7)
        Mix.shell().info("#{padded_name}  #{padded_source}  #{mask(value)}")
        source

      {:error, _reason} ->
        padded_name = String.pad_trailing(name, max_name_len)
        padded_source = String.pad_trailing("missing", 7)
        Mix.shell().info("#{padded_name}  #{padded_source}  ---")
        :missing
    end
  end

  defp mask(value) when byte_size(value) > 8 do
    first = String.slice(value, 0, 4)
    last = String.slice(value, -4, 4)
    "#{first}...#{last}"
  end

  defp mask(_value), do: "***"

  defp start_lemon_core! do
    Mix.Task.run("loadpaths")

    case Application.ensure_all_started(:lemon_core) do
      {:ok, _} -> :ok
      {:error, {app, reason}} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end
  end
end
