defmodule LemonCore.Doctor.Checks.Providers do
  @moduledoc "Checks that at least one AI provider is configured."

  alias LemonCore.Config.Modular
  alias LemonCore.Doctor.Check
  alias LemonCore.Doctor.ProviderDiagnostics

  @doc """
  Returns a list of Check results covering provider configuration.
  """
  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    config = Modular.load()

    [
      check_default_provider(config),
      check_provider_credentials(config),
      check_provider_routing(opts)
    ]
  end

  defp check_default_provider(config) do
    case config.agent.default_provider do
      nil ->
        Check.warn(
          "providers.default",
          "No default provider is set.",
          "Run `mix lemon.setup provider` or set defaults.provider in config.toml."
        )

      provider ->
        Check.pass("providers.default", "Default provider: #{provider}")
    end
  end

  defp check_provider_credentials(config) do
    providers =
      if config.providers && config.providers.providers do
        config.providers.providers
      else
        %{}
      end

    if map_size(providers) == 0 do
      Check.warn(
        "providers.credentials",
        "No providers are configured.",
        "Run `mix lemon.setup provider` or `mix lemon.onboard` to onboard a provider."
      )
    else
      configured = Enum.filter(providers, fn {_, p} -> provider_has_credential?(p) end)

      if Enum.empty?(configured) do
        Check.warn(
          "providers.credentials",
          "Providers are listed in config but none have credentials (api_key or api_key_secret).",
          "Run `mix lemon.setup provider` to onboard a provider."
        )
      else
        names = configured |> Enum.map(fn {name, _} -> to_string(name) end) |> Enum.join(", ")
        Check.pass("providers.credentials", "Providers with credentials: #{names}")
      end
    end
  end

  defp provider_has_credential?(provider) when is_map(provider) do
    Enum.any?(
      [:api_key, :api_key_secret, :oauth_secret, "api_key", "api_key_secret", "oauth_secret"],
      fn key ->
        value = Map.get(provider, key)
        is_binary(value) and value != ""
      end
    )
  end

  defp provider_has_credential?(_provider), do: false

  defp check_provider_routing(opts) do
    status = ProviderDiagnostics.status(project_dir: Keyword.get(opts, :project_dir, File.cwd!()))
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
