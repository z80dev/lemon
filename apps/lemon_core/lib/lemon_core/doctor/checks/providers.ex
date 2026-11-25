defmodule LemonCore.Doctor.Checks.Providers do
  @moduledoc """
  Checks the effective default model and usable provider credentials.

  Credential readiness comes from the runtime's single presence-mode predicate
  (`LemonCore.CredentialReadiness`), the same answer setup readiness, provider
  status and the CLI report. The check never decrypts a value, refreshes a
  login or makes a request.
  """

  alias LemonCore.Config.Providers.AuthExtension
  alias LemonCore.Config.Modular
  alias LemonCore.CredentialReadiness
  alias LemonCore.Doctor.Check
  alias LemonCore.ProviderIdentity

  @doc """
  Returns a list of Check results covering provider configuration.
  """
  @spec run(keyword()) :: [Check.t()]
  def run(opts \\ []) do
    config = Modular.load(Keyword.take(opts, [:project_dir]))
    providers = (config.providers && config.providers.providers) || %{}
    routing = Map.get(config.agent || %{}, :provider_routing) || %{}

    ready? = fn provider ->
      present?(provider) and
        CredentialReadiness.ready?(provider, providers,
          provider_routing: routing,
          cwd: Keyword.get(opts, :project_dir)
        )
    end

    [
      check_default_provider(config),
      check_default_model(config),
      check_provider_credentials(config, providers, ready?),
      check_provider_routing(config, routing, ready?)
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
        Check.pass(
          "providers.default",
          "Default provider: #{ProviderIdentity.public_name(provider)}"
        )
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

      String.contains?(model, ":") and
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

  defp check_provider_credentials(config, providers, ready?) do
    provider = config.agent.default_provider

    provider_config =
      Enum.find_value(providers, %{}, fn {name, settings} ->
        if normalize_provider(name) == normalize_provider(provider), do: settings
      end)

    ready = ready?.(provider)

    extension_check =
      AuthExtension.call(:credential_check, [provider, provider_config, ready], nil)

    cond do
      extension_check ->
        extension_check

      ready ->
        Check.pass(
          "providers.credentials",
          "Default provider credential is usable (offline check)."
        )

      true ->
        Check.fail(
          "providers.credentials",
          "Default provider credential is missing or cannot be decrypted.",
          "Run `lemon setup provider --set-default`; for ChatGPT sign-in use " <>
            "`lemon setup --provider openai-codex`. Restore the original secrets master key " <>
            "if existing encrypted credentials cannot be read."
        )
    end
  end

  defp check_provider_routing(config, routing, ready?) do
    fallback_providers = route_candidate_providers(routing)
    ready_fallbacks = Enum.filter(fallback_providers, ready?)

    cond do
      map_value(routing, :enabled) == false ->
        Check.skip("providers.routing", "Provider routing is disabled.")

      fallback_providers == [] ->
        Check.pass("providers.routing", "No provider fallback routing is configured.")

      ready_fallbacks == [] ->
        Check.warn(
          "providers.routing",
          "Provider fallback routing is configured, but no fallback provider is credential-ready.",
          "Configure credentials for at least one fallback provider or remove the fallback route."
        )

      ready?.(config.agent.default_provider) ->
        Check.pass(
          "providers.routing",
          "Provider routing has #{length(ready_fallbacks)} credential-ready fallback provider(s)."
        )

      true ->
        Check.pass(
          "providers.routing",
          "Default provider is not credential-ready; fallback route has ready provider(s): " <>
            Enum.map_join(ready_fallbacks, ", ", &ProviderIdentity.public_name/1)
        )
    end
  rescue
    error ->
      Check.warn(
        "providers.routing",
        "Provider routing diagnostics are unavailable.",
        "Error class: #{inspect(error.__struct__)}. Run `lemon config validate --verbose`."
      )
  end

  # Fallback providers, credential-pool providers and profile fallbacks, by
  # their configured (raw) names.
  defp route_candidate_providers(routing) do
    pools = routing |> map_value(:credential_pools) |> map_values()
    profiles = routing |> map_value(:profiles) |> map_values()

    (list(map_value(routing, :fallback_providers)) ++
       Enum.flat_map(pools, &list(map_value(&1, :providers))) ++
       Enum.flat_map(profiles, &list(map_value(&1, :fallback_providers))))
    |> Enum.filter(&present?/1)
    |> Enum.uniq_by(&normalize_provider/1)
  end

  defp map_values(map) when is_map(map), do: Map.values(map)
  defp map_values(_), do: []

  defp list(values) when is_list(values), do: Enum.map(values, &to_string/1)
  defp list(value) when is_binary(value), do: String.split(value, ",", trim: true)
  defp list(_), do: []

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp map_value(_, _), do: nil

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_atom(value), do: not is_nil(value)
  defp present?(_), do: false

  defp normalize_provider(provider) when is_atom(provider) and not is_nil(provider),
    do: provider |> Atom.to_string() |> normalize_provider()

  defp normalize_provider(provider) when is_binary(provider) do
    provider
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
  end

  defp normalize_provider(_), do: nil
end
