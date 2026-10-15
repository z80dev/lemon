defmodule LemonCore.Doctor.Checks.Providers do
  @moduledoc "Checks the effective default model and usable provider credentials."

  alias LemonCore.Config.Modular
  alias LemonCore.Doctor.Check
  alias LemonCore.Doctor.ProviderDiagnostics
  alias LemonCore.Secrets

  @doc """
  Returns a list of Check results covering provider configuration.
  """
  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    config = Modular.load(Keyword.take(opts, [:project_dir]))
    status = ProviderDiagnostics.status(project_dir: Keyword.get(opts, :project_dir, File.cwd!()))

    [
      check_default_provider(config),
      check_default_model(config),
      check_provider_credentials(config, status),
      check_provider_routing(status)
    ]
  rescue
    _error in LemonCore.Config.ValidationError ->
      [
        Check.fail(
          "providers.config",
          "Provider checks cannot run because the configuration is invalid.",
          "Run `lemon config validate --verbose`; use `lemon config migrate` for removed settings."
        )
      ]
  end

  defp check_default_provider(config) do
    case config.agent.default_provider do
      nil ->
        Check.fail(
          "providers.default",
          "No default provider is set.",
          "Run `lemon setup` to sign in and choose a default model."
        )

      provider ->
        Check.pass("providers.default", "Default provider: #{provider}")
    end
  end

  defp check_default_model(config) do
    provider = config.agent.default_provider
    model = config.agent.default_model

    cond do
      not is_binary(model) or model == "" ->
        Check.fail(
          "providers.model",
          "No default model is set.",
          "Run `lemon setup provider --set-default` to select a model."
        )

      is_binary(provider) and String.contains?(model, ":") and
          normalize_provider(hd(String.split(model, ":", parts: 2))) !=
            normalize_provider(provider) ->
        Check.fail(
          "providers.model",
          "Default model belongs to a different provider.",
          "Run `lemon setup provider --set-default` to align provider and model."
        )

      true ->
        Check.pass("providers.model", "Default model is configured.")
    end
  end

  defp check_provider_credentials(config, status) do
    provider = config.agent.default_provider
    providers = (config.providers && config.providers.providers) || %{}

    provider_config =
      Enum.find_value(providers, %{}, fn {name, settings} ->
        if normalize_provider(name) == normalize_provider(provider), do: settings
      end)

    ambient? =
      Enum.any?(status.providers, fn entry ->
        normalize_provider(entry.provider) == normalize_provider(provider) and
          entry.ambient.provider_env_configured
      end)

    if provider_has_credential?(provider_config) or ambient? do
      Check.pass(
        "providers.credentials",
        "Default provider credential is usable (offline check)."
      )
    else
      Check.fail(
        "providers.credentials",
        "Default provider credential is missing or cannot be decrypted.",
        "Run `lemon setup provider --set-default`; for ChatGPT sign-in use " <>
          "`lemon setup --provider openai-codex`. Restore the original secrets master key " <>
          "if existing encrypted credentials cannot be read."
      )
    end
  end

  defp provider_has_credential?(provider) when is_map(provider) do
    inline = Map.get(provider, :api_key) || Map.get(provider, "api_key")

    (is_binary(inline) and String.trim(inline) != "") or
      Enum.any?([:api_key_secret, :oauth_secret, "api_key_secret", "oauth_secret"], fn field ->
        case Map.get(provider, field) do
          name when is_binary(name) and name != "" ->
            match?({:ok, value, _} when is_binary(value) and value != "", Secrets.resolve(name))

          _ ->
            false
        end
      end)
  end

  defp provider_has_credential?(_provider), do: false

  defp check_provider_routing(status) do
    routing = Map.get(status, :routing, %{})
    fallback_providers = route_candidate_providers(routing)
    ready_fallbacks = ready_providers(status, fallback_providers)
    default_provider = Map.get(status, :default_provider)
    default_ready? = provider_ready?(status, default_provider)

    cond do
      Map.get(routing, :enabled) == false ->
        Check.skip("providers.routing", "Provider routing is disabled.")

      fallback_providers == [] ->
        Check.pass("providers.routing", "No provider fallback routing is configured.")

      ready_fallbacks == [] ->
        Check.warn(
          "providers.routing",
          "Provider fallback routing is configured, but no fallback provider is credential-ready.",
          "Configure credentials for at least one fallback provider or remove the fallback route."
        )

      default_ready? ->
        Check.pass(
          "providers.routing",
          "Provider routing has #{length(ready_fallbacks)} credential-ready fallback provider(s)."
        )

      true ->
        Check.pass(
          "providers.routing",
          "Default provider is not credential-ready; fallback route has ready provider(s): #{Enum.join(ready_fallbacks, ", ")}"
        )
    end
  rescue
    error ->
      Check.warn(
        "providers.routing",
        "Provider routing diagnostics are unavailable.",
        Exception.message(error)
      )
  end

  defp route_candidate_providers(routing) do
    fallback_providers = Map.get(routing, :fallback_providers, [])

    pool_providers =
      routing
      |> Map.get(:credential_pools, [])
      |> Enum.flat_map(&Map.get(&1, :providers, []))

    profile_fallbacks =
      routing
      |> Map.get(:profiles, [])
      |> Enum.flat_map(&Map.get(&1, :fallback_providers, []))

    (fallback_providers ++ pool_providers ++ profile_fallbacks)
    |> Enum.map(&normalize_provider/1)
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
  end

  defp ready_providers(status, providers) do
    providers
    |> Enum.filter(&provider_ready?(status, &1))
  end

  defp provider_ready?(_status, provider) when provider in [nil, ""], do: false

  defp provider_ready?(status, provider) do
    normalized = normalize_provider(provider)

    status
    |> Map.get(:providers, [])
    |> Enum.any?(fn provider_status ->
      normalize_provider(Map.get(provider_status, :provider)) == normalized and
        Map.get(provider_status, :credential_ready) == true
    end)
  end

  defp normalize_provider(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> normalize_provider()

  defp normalize_provider(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp normalize_provider(_), do: nil
end
