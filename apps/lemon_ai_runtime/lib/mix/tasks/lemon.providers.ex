defmodule Mix.Tasks.Lemon.Providers do
  @moduledoc """
  Show redacted provider readiness and routing state.

  ## Usage

      mix lemon.providers
      mix lemon.providers --provider openai
      mix lemon.providers --include-catalog
      mix lemon.providers --project-dir /path/to/project

  ## Options

    * `--provider` - Filter to a provider id.
    * `--include-catalog` - Include all known catalog providers.
    * `--project-dir` - Resolve project config from the given directory.
  """

  use Mix.Task

  @shortdoc "Show redacted provider readiness"

  @impl true
  def run(args) do
    {opts, rest, invalid} =
      OptionParser.parse(args,
        switches: [
          provider: :string,
          include_catalog: :boolean,
          project_dir: :string,
          help: :boolean
        ],
        aliases: [
          p: :provider,
          h: :help
        ]
      )

    cond do
      opts[:help] ->
        Mix.shell().info(@moduledoc)

      rest != [] or invalid != [] ->
        Mix.raise("Invalid arguments. Run `mix lemon.providers --help`.")

      true ->
        Mix.Task.run("app.start")

        opts
        |> params()
        |> LemonAiRuntime.ProviderStatus.snapshot()
        |> render()
    end
  end

  defp params(opts) do
    %{}
    |> maybe_put("provider", opts[:provider])
    |> maybe_put("includeCatalog", opts[:include_catalog])
    |> maybe_put("projectDir", opts[:project_dir])
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, _key, false), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp render(status) do
    cleanup = Map.get(status, "cleanup", %{})
    routing = Map.get(status, "routing", %{})
    live_proofs = Map.get(status, "liveProofs", %{})
    fallback = Map.get(live_proofs, "fallback", %{})

    Mix.shell().info("Lemon Providers")
    Mix.shell().info("Providers: #{Map.get(status, "count", 0)}")
    Mix.shell().info("Ready: #{Map.get(status, "readyCount", 0)}")

    Mix.shell().info(
      "Default provider configured: #{present?(Map.get(status, "defaultProvider"))}"
    )

    Mix.shell().info("Default model configured: #{present?(Map.get(status, "defaultModel"))}")
    Mix.shell().info("Routing decision: #{Map.get(routing, "decision") || "(none)"}")
    Mix.shell().info("Selected provider: #{Map.get(routing, "selectedProvider") || "(none)"}")
    Mix.shell().info("Fallback proof status: #{Map.get(fallback, "status") || "missing"}")
    Mix.shell().info("Includes raw API keys: #{Map.get(cleanup, "includesRawApiKeys") == true}")
    Mix.shell().info("Includes secret names: #{Map.get(cleanup, "includesSecretNames") == true}")
    Mix.shell().info("Includes raw base URLs: #{Map.get(cleanup, "includesRawBaseUrls") == true}")
    Mix.shell().info("Includes env var names: #{Map.get(cleanup, "includesEnvVarNames") == true}")
    Mix.shell().info("")

    status
    |> Map.get("providers", [])
    |> Enum.each(&render_provider/1)
  end

  defp render_provider(provider) do
    config = Map.get(provider, "config", %{})
    ambient = Map.get(provider, "ambient", %{})

    Mix.shell().info("#{Map.get(provider, "provider")}")
    Mix.shell().info("  known: #{Map.get(provider, "known") == true}")
    Mix.shell().info("  configured: #{Map.get(provider, "configured") == true}")
    Mix.shell().info("  credential_ready: #{Map.get(provider, "credentialReady") == true}")
    Mix.shell().info("  api_key_configured: #{Map.get(config, "apiKeyConfigured") == true}")

    Mix.shell().info(
      "  api_key_secret_configured: #{Map.get(config, "apiKeySecretConfigured") == true}"
    )

    Mix.shell().info(
      "  oauth_secret_configured: #{Map.get(config, "oauthSecretConfigured") == true}"
    )

    Mix.shell().info("  base_url_configured: #{Map.get(config, "baseUrlConfigured") == true}")
    Mix.shell().info("  env_configured: #{Map.get(ambient, "envConfigured") == true}")
    Mix.shell().info("")
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
