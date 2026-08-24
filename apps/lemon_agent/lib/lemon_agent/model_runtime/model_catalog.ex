defmodule LemonAgent.ModelRuntime.ModelCatalog do
  @moduledoc """
  Consumer-facing "what can I pick from right now" model catalog.

  Centralizes the provider-alias credential-fallback rules, health blocklist,
  and picker sort order that model-picker-style consumers need, so callers
  don't have to reach into `LemonAi.Models` and the provider config table
  themselves. This mirrors (and replaces) logic that used to be duplicated
  across Telegram transport modules in `lemon_channels`.
  """

  alias LemonAgent.ModelRuntime.Credentials
  alias LemonCore.Config
  alias LemonCore.Secrets

  @typedoc "A single selectable model entry."
  @type model_map :: %{provider: String.t(), id: String.t(), name: String.t()}

  @typedoc "Models grouped by provider, in picker display order."
  @type provider_group :: %{provider: String.t(), models: [model_map()]}

  @doc """
  Returns the catalog of models available for selection, grouped by provider
  and filtered down to providers with usable credentials, in picker display
  order (each provider's models sorted newest/most-relevant first).

  Falls back to a small built-in catalog if the model registry is
  unavailable or errors.
  """
  @spec available_catalog() :: [provider_group()]
  def available_catalog do
    models = LemonAi.Models.list_models()

    model_maps =
      models
      |> Enum.map(&to_model_map/1)
      |> Enum.filter(&is_map/1)

    filtered =
      model_maps
      |> filter_enabled_model_maps()
      |> reject_unhealthy_picker_model_maps()
      |> maybe_fallback_to_default_providers(model_maps)

    filtered
    |> Enum.group_by(& &1.provider)
    |> Enum.map(fn {provider, provider_models} ->
      %{
        provider: provider,
        models: sort_models_for_picker(provider_models)
      }
    end)
    |> Enum.sort_by(& &1.provider)
  rescue
    _ -> fallback_catalog()
  end

  @doc "Provider ids present in a catalog, in display order."
  @spec providers([provider_group()]) :: [String.t()]
  def providers(catalog) when is_list(catalog), do: Enum.map(catalog, & &1.provider)

  @doc "Models for a given provider within a catalog, or `[]` if unknown."
  @spec models_for_provider([provider_group()], String.t()) :: [model_map()]
  def models_for_provider(catalog, provider) when is_list(catalog) and is_binary(provider) do
    Enum.find_value(catalog, [], fn
      %{provider: ^provider, models: models} -> models
      _ -> nil
    end)
  end

  def models_for_provider(_catalog, _provider), do: []

  @doc "Model at a given index for a provider within a catalog, or `nil`."
  @spec model_at_index([provider_group()], String.t(), integer()) :: model_map() | nil
  def model_at_index(catalog, provider, index)
      when is_list(catalog) and is_binary(provider) and is_integer(index) and index >= 0 do
    catalog
    |> models_for_provider(provider)
    |> Enum.at(index)
  end

  def model_at_index(_catalog, _provider, _index), do: nil

  @doc "Formats a model map as a `provider:id` spec string."
  @spec model_spec(model_map()) :: String.t() | nil
  def model_spec(%{provider: provider, id: id}) when is_binary(provider) and is_binary(id) do
    "#{provider}:#{id}"
  end

  def model_spec(_), do: nil

  @doc "Human-readable label for a model map."
  @spec model_label(model_map()) :: String.t()
  def model_label(%{name: name, id: id}) when is_binary(name) and name != "" and is_binary(id) do
    "#{name} (#{id})"
  end

  def model_label(%{id: id}) when is_binary(id), do: id
  def model_label(other), do: inspect(other)

  @doc false
  # Test seam: the same enabled-provider decision `available_catalog/0` makes,
  # evaluated against an explicit config instead of `Config.cached()`. Counts
  # pool-only credentials via `provider_routing`.
  @spec provider_enabled_for_config?(String.t() | atom(), map()) :: boolean()
  def provider_enabled_for_config?(provider, cfg) do
    provider_enabled?(
      normalize_provider_name(provider),
      configured_provider_index(cfg),
      provider_routing_config(cfg)
    )
  end

  # ============================================================================
  # Private helpers
  # ============================================================================

  defp to_model_map(%{provider: provider, id: id} = model) when is_binary(id) do
    provider_str = provider |> to_string() |> String.downcase()
    name = Map.get(model, :name) || Map.get(model, "name") || id
    %{provider: provider_str, id: id, name: name}
  rescue
    _ -> nil
  end

  defp to_model_map(_), do: nil

  defp fallback_model_entries do
    [
      %{provider: "anthropic", id: "claude-sonnet-4-20250514", name: "Claude Sonnet 4"},
      %{provider: "openai", id: "gpt-4o", name: "GPT-4o"},
      %{provider: "google", id: "gemini-2.5-pro", name: "Gemini 2.5 Pro"}
    ]
  end

  defp fallback_catalog do
    fallback_model_entries()
    |> Enum.group_by(& &1.provider)
    |> Enum.map(fn {provider, models} -> %{provider: provider, models: models} end)
    |> Enum.sort_by(& &1.provider)
  end

  defp sort_models_for_picker(models) when is_list(models) do
    Enum.sort_by(models, &model_picker_sort_key/1, :desc)
  end

  defp model_picker_sort_key(model) when is_map(model) do
    provider = String.downcase(model[:provider] || model["provider"] || "")
    name = String.downcase(model[:name] || model["name"] || "")
    id = String.downcase(model[:id] || model["id"] || "")

    {
      provider_specific_rank(provider, name, id),
      version_tuple(name, id),
      latest_rank(name, id),
      String.contains?(name, "thinking"),
      name,
      id
    }
  end

  defp model_picker_sort_key(_), do: {{0, 0, 0}, 0, false, "", ""}

  defp latest_rank(name, id) do
    if String.contains?(name, "latest") or String.contains?(id, "latest"), do: 1, else: 0
  end

  defp version_tuple(name, id) do
    source =
      cond do
        is_binary(name) and name != "" -> name
        is_binary(id) and id != "" -> id
        true -> ""
      end

    case Regex.run(~r/\b(\d+)(?:[.\-](\d+))?(?:[.\-](\d+))?\b/, source) do
      [_, major, minor, patch] ->
        {parse_version_part(major), parse_version_part(minor), parse_version_part(patch)}

      [_, major, minor] ->
        {parse_version_part(major), parse_version_part(minor), 0}

      [_, major] ->
        {parse_version_part(major), 0, 0}

      _ ->
        {0, 0, 0}
    end
  end

  defp parse_version_part(nil), do: 0

  defp parse_version_part(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _} -> parsed
      :error -> 0
    end
  end

  defp provider_specific_rank("google", name, id) do
    cond do
      String.contains?(id, "customtools") or String.contains?(name, "custom tools") -> 2
      String.contains?(id, "preview") or String.contains?(name, "preview") -> 1
      true -> 0
    end
  end

  defp provider_specific_rank(_, _, _), do: 0

  defp filter_enabled_model_maps(model_maps) when is_list(model_maps) do
    enabled = enabled_model_provider_names(model_maps)

    Enum.filter(model_maps, fn model ->
      normalize_provider_name(model.provider) in enabled
    end)
  end

  defp reject_unhealthy_picker_model_maps(model_maps) when is_list(model_maps) do
    Enum.reject(model_maps, fn model ->
      provider = normalize_provider_name(model.provider)
      id = model[:id] || model["id"] || ""
      picker_model_blocked?(provider, id)
    end)
  end

  defp picker_model_blocked?("minimax", "MiniMax-M2.7-highspeed"), do: true
  defp picker_model_blocked?(_, _), do: false

  defp maybe_fallback_to_default_providers([], model_maps) when is_list(model_maps) do
    []
  end

  defp maybe_fallback_to_default_providers(filtered, _model_maps), do: filtered

  defp enabled_model_provider_names(model_maps) when is_list(model_maps) do
    cfg = Config.cached()
    configured = configured_provider_index(cfg)
    routing = provider_routing_config(cfg)

    model_maps
    |> Enum.map(&normalize_provider_name(&1.provider))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.filter(fn provider ->
      provider_enabled?(provider, configured, routing)
    end)
  rescue
    _ -> []
  end

  defp configured_provider_index(cfg) do
    providers = cfg.providers || %{}

    Enum.reduce(providers, %{}, fn {name, provider_cfg}, acc ->
      Map.put(acc, normalize_provider_name(name), provider_cfg || %{})
    end)
  rescue
    _ -> %{}
  end

  # Normalized routing config so pool-only credentials
  # (`provider_routing.credential_pools.<pool>.credentials`) count toward
  # provider availability in the picker catalog.
  defp provider_routing_config(cfg) do
    agent = Map.get(cfg, :agent) || Map.get(cfg, "agent") || %{}
    Map.get(agent, :provider_routing) || Map.get(agent, "provider_routing") || %{}
  rescue
    _ -> %{}
  end

  defp provider_enabled?(provider, configured, routing)
       when is_binary(provider) and is_map(configured) do
    aliases = provider_aliases(provider)

    provider_has_credentials?(provider, aliases, configured, routing) or
      provider_special_enabled?(provider)
  end

  defp provider_enabled?(_provider, _configured, _routing), do: false

  defp provider_has_credentials?(provider, aliases, configured, routing) do
    opts = [provider_routing: routing]

    Credentials.provider_has_credentials?(provider, configured, opts) or
      Enum.any?(aliases, &Credentials.provider_has_credentials?(&1, configured, opts))
  end

  defp provider_special_enabled?("openai-codex"), do: openai_codex_auth_available?()

  defp provider_special_enabled?("amazon-bedrock"),
    do:
      (secret_present?("AWS_ACCESS_KEY_ID") and secret_present?("AWS_SECRET_ACCESS_KEY")) or
        secret_present?("AWS_PROFILE")

  defp provider_special_enabled?(_provider), do: false

  defp provider_aliases(provider) when is_binary(provider) do
    aliases =
      case normalize_provider_name(provider) do
        "google-antigravity" -> [provider, "google"]
        "google-gemini-cli" -> [provider, "google"]
        "google-vertex" -> [provider]
        "kimi-coding" -> [provider, "kimi"]
        "amazon-bedrock" -> [provider, "bedrock", "aws"]
        "azure-openai-responses" -> [provider, "azure-openai", "azure-openai-responses"]
        other -> [other]
      end

    aliases
    |> Enum.map(&normalize_provider_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp provider_aliases(_provider), do: []

  defp openai_codex_auth_available? do
    Credentials.provider_has_credentials?("openai_codex", %{
      "openai-codex" => %{"auth_source" => "oauth"}
    })
  end

  defp secret_present?(name) when is_binary(name) and name != "" do
    present_value?(System.get_env(name)) or
      present_value?(System.get_env(String.downcase(name))) or
      Secrets.exists?(name) or
      Secrets.exists?(String.downcase(name))
  rescue
    _ ->
      present_value?(System.get_env(name)) or
        present_value?(System.get_env(String.downcase(name)))
  end

  defp secret_present?(_), do: false

  defp present_value?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_value?(_), do: false

  defp normalize_provider_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace("_", "-")
    |> String.trim()
  rescue
    _ -> ""
  end
end
