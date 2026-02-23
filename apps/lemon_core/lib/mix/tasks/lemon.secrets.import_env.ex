defmodule Mix.Tasks.Lemon.Secrets.ImportEnv do
  use Mix.Task

  alias LemonCore.Secrets

  @shortdoc "Import env-based secrets into encrypted store"
  @moduledoc """
  Scans known secret env var names and imports any that are set in the
  environment but not already present in the encrypted store.

  Usage:
      mix lemon.secrets.import_env
      mix lemon.secrets.import_env --dry-run
      mix lemon.secrets.import_env --force
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
  def run(args) do
    start_lemon_core!()

    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        switches: [dry_run: :boolean, force: :boolean],
        aliases: [d: :dry_run, f: :force]
      )

    dry_run = Keyword.get(opts, :dry_run, false)
    force = Keyword.get(opts, :force, false)

    if dry_run do
      Mix.shell().info("Dry run mode — no changes will be made")
    end

    results = Enum.map(@known_secrets, &process_secret(&1, dry_run, force))

    imported = Enum.count(results, &(&1 == :imported))
    already = Enum.count(results, &(&1 == :already_in_store))
    not_set = Enum.count(results, &(&1 == :not_in_env))
    errors = Enum.count(results, &match?({:error, _}, &1))

    Mix.shell().info("")

    summary = "#{imported} imported, #{already} already in store, #{not_set} not in env"

    summary =
      if errors > 0,
        do: summary <> ", #{errors} errors",
        else: summary

    Mix.shell().info(summary)
  end

  defp process_secret(name, dry_run, force) do
    env_value = System.get_env(name)

    cond do
      is_nil(env_value) or env_value == "" ->
        Mix.shell().info("#{name}: not set in env")
        :not_in_env

      not force and in_store?(name) ->
        Mix.shell().info("#{name}: already in store")
        :already_in_store

      dry_run ->
        Mix.shell().info("#{name}: would import")
        :imported

      true ->
        import_secret(name, env_value)
    end
  end

  defp in_store?(name) do
    match?({:ok, _}, Secrets.get(name))
  end

  defp import_secret(name, value) do
    case Secrets.set(name, value, provider: "import_env") do
      {:ok, _metadata} ->
        Mix.shell().info("#{name}: imported")
        :imported

      {:error, reason} ->
        Mix.shell().info("#{name}: error — #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp start_lemon_core! do
    Mix.Task.run("loadpaths")

    case Application.ensure_all_started(:lemon_core) do
      {:ok, _} -> :ok
      {:error, {app, reason}} -> Mix.raise("Failed to start #{app}: #{inspect(reason)}")
    end
  end
end
