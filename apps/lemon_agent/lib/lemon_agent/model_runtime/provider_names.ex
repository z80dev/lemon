defmodule LemonAgent.ModelRuntime.ProviderNames do
  @moduledoc """
  Canonical provider naming helpers for the Lemon AI runtime boundary.

  This module owns Lemon-side provider alias normalization so callers do not
  duplicate provider/env/default-secret knowledge when resolving credentials or
  runtime stream options. The built-in identity data lives in
  `LemonCore.ProviderIdentity`; this module adds the OpenAI-compatible presets.
  Onboarding also uses these canonical identities and aliases, translating its
  additional input-only spellings locally before writing canonical config ids.
  Those input conveniences are not runtime aliases: a custom provider table may
  independently use the same name.
  """

  # OpenAI-compatible presets (`LemonAi.Models.Presets`): env vars and aliases
  # follow omp; local presets are keyless (credential-ready without a key).
  @preset_providers Map.new(LemonAi.Models.Presets.all(), fn preset ->
                      canonical = Atom.to_string(preset.id)

                      {canonical,
                       %{
                         config_name: canonical,
                         atom_name: preset.id,
                         env_vars: preset.env_vars,
                         default_secret_name: "llm_#{canonical}_api_key",
                         aliases: preset.aliases,
                         keyless: preset.keyless
                       }}
                    end)

  @providers Map.merge(@preset_providers, LemonCore.ProviderIdentity.table())

  @spec canonical_name(atom() | String.t() | nil) :: String.t() | nil
  def canonical_name(provider) when is_atom(provider),
    do: provider |> Atom.to_string() |> canonical_name()

  def canonical_name(provider) when is_binary(provider) do
    normalized =
      provider
      |> String.trim()
      |> String.downcase()
      |> String.replace("-", "_")

    cond do
      normalized == "" ->
        nil

      Map.has_key?(@providers, normalized) ->
        normalized

      true ->
        Enum.find_value(@providers, fn {canonical, meta} ->
          names =
            [canonical, meta.config_name, dashed_name(canonical) | Map.get(meta, :aliases, [])]
            |> Enum.map(&normalize_candidate/1)
            |> Enum.reject(&is_nil/1)

          if normalized in names, do: canonical, else: nil
        end)
    end
  end

  def canonical_name(_), do: nil

  @doc "Normalizes a built-in alias or custom provider ID."
  @spec normalize(atom() | String.t() | nil) :: String.t() | nil
  def normalize(provider) when is_atom(provider) and not is_nil(provider),
    do: provider |> Atom.to_string() |> normalize()

  def normalize(provider) when is_binary(provider) do
    canonical_name(provider) ||
      provider |> String.trim() |> String.downcase() |> String.replace("-", "_")
  end

  def normalize(_), do: nil

  @spec config_name(atom() | String.t() | nil) :: String.t() | nil
  def config_name(provider) do
    case canonical_name(provider) do
      nil -> nil
      canonical -> provider_meta(canonical).config_name
    end
  end

  @spec dashed_name(atom() | String.t() | nil) :: String.t() | nil
  def dashed_name(provider) do
    case config_name(provider) do
      nil -> nil
      config_name -> String.replace(config_name, "_", "-")
    end
  end

  @spec provider_atom(atom() | String.t() | nil) :: atom() | nil
  def provider_atom(provider) do
    case canonical_name(provider) do
      nil -> nil
      canonical -> provider_meta(canonical).atom_name
    end
  end

  @spec env_vars(atom() | String.t() | nil) :: [String.t()]
  def env_vars(provider) do
    case canonical_name(provider) do
      nil -> []
      canonical -> Map.get(provider_meta(canonical), :env_vars, [])
    end
  end

  @spec default_secret_name(atom() | String.t() | nil) :: String.t() | nil
  def default_secret_name(provider) do
    case canonical_name(provider) do
      nil -> nil
      canonical -> Map.get(provider_meta(canonical), :default_secret_name)
    end
  end

  @spec oauth_default_secret_name(atom() | String.t() | nil) :: String.t() | nil
  def oauth_default_secret_name(provider) do
    case canonical_name(provider) do
      nil -> nil
      canonical -> Map.get(provider_meta(canonical), :oauth_default_secret_name)
    end
  end

  @doc """
  Whether the provider can be used without a credential (local OpenAI-compatible
  servers such as Ollama or LM Studio).
  """
  @spec keyless?(atom() | String.t() | nil) :: boolean()
  def keyless?(provider) do
    case canonical_name(provider) do
      nil -> false
      canonical -> Map.get(provider_meta(canonical), :keyless, false)
    end
  end

  @spec all_names(atom() | String.t() | nil) :: [String.t()]
  def all_names(provider) do
    case canonical_name(provider) do
      nil ->
        []

      canonical ->
        meta = provider_meta(canonical)

        [canonical, meta.config_name, dashed_name(canonical) | Map.get(meta, :aliases, [])]
        |> Enum.map(&normalize_candidate/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
    end
  end

  @spec all_canonical_names() :: [String.t()]
  def all_canonical_names do
    @providers
    |> Map.keys()
    |> Enum.sort()
  end

  @spec provider_config(map() | nil, atom() | String.t()) :: map() | nil
  def provider_config(providers_map, provider) when is_map(providers_map) do
    provider_keys = all_names(provider)

    providers_map
    |> unwrap_providers_map()
    |> Enum.find_value(fn
      {key, value} when is_map(value) ->
        if normalize_candidate(key) in provider_keys, do: value, else: nil

      _ ->
        nil
    end)
  end

  def provider_config(_, _), do: nil

  defp provider_meta(canonical), do: Map.fetch!(@providers, canonical)

  defp unwrap_providers_map(%{providers: providers}) when is_map(providers), do: providers
  defp unwrap_providers_map(%{"providers" => providers}) when is_map(providers), do: providers
  defp unwrap_providers_map(providers), do: providers

  defp normalize_candidate(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_candidate()

  defp normalize_candidate(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> case do
      "" -> nil
      normalized -> normalized
    end
  end

  defp normalize_candidate(_), do: nil
end
