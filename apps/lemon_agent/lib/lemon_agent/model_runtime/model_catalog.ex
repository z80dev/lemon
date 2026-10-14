defmodule LemonAgent.ModelRuntime.ModelCatalog do
  @moduledoc """
  Consumer-facing "what can I pick from right now" model catalog.

  Centralizes the provider-alias credential-fallback rules, health blocklist,
  and picker sort order that model-picker-style consumers need, so callers
  don't have to reach into `LemonAi.Models` and the provider config table
  themselves. This mirrors (and replaces) logic that used to be duplicated
  across Telegram transport modules in `lemon_channels`.
  """

  alias LemonAgent.ModelRuntime.{Credentials, CustomProviders, ProviderNames}
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

  Codex choices are authoritative for the selected ChatGPT credential and cached
  per account. A failed discovery never advertises an unverified Codex fallback.
  """
  @spec available_catalog() :: [provider_group()]
  def available_catalog do
    available_models()
    |> Enum.map(&to_model_map/1)
    |> Enum.filter(&is_map/1)
    |> Enum.group_by(& &1.provider)
    |> Enum.map(fn {provider, provider_models} ->
      %{provider: provider, models: sort_for_picker(provider_models)}
    end)
    |> Enum.sort_by(& &1.provider)
  end

  @doc """
  Returns concrete, credential-enabled models for pickers and protocol clients.

  `:config` may provide a resolved config/settings map. Codex discovery uses the
  same first healthy credential as native requests; the registry remains static
  for other providers unless `:discover_openai` is explicitly enabled.

  Models defined under `[providers.<id>]` are included (see
  `LemonAgent.ModelRuntime.CustomProviders`); `discover_custom: false` skips
  custom-provider endpoint discovery, and `:custom_discovery_opts` passes extra
  options to `LemonAi.Models.Discovery.discover/3`.

  OpenAI-compatible presets (`LemonAi.Models.Presets`) contribute the models
  their endpoint serves: cloud presets once a credential resolves, local
  servers (Ollama, LM Studio, llama.cpp, vLLM, LiteLLM) only when configured
  under `[providers.<id>]` or through their base-URL environment variable.
  Listings run concurrently, are cached for five minutes, and are bounded by
  `:preset_discovery_timeout_ms` (default 2000); an unreachable endpoint
  contributes no models. `:preset_req_options` passes `Req` options (tests).
  """
  @spec available_models(keyword()) :: [LemonAi.Types.Model.t()]
  def available_models(opts \\ []) do
    cfg = Keyword.get(opts, :config) || Config.cached()
    configured = configured_provider_index(cfg)
    routing = provider_routing_config(cfg)

    enabled =
      LemonAi.Models.get_providers()
      |> Enum.map(&normalize_provider_name/1)
      |> Enum.filter(&provider_enabled?(&1, configured, routing))
      |> MapSet.new()

    codex_cfg = Map.get(configured, "openai-codex", %{})

    token =
      if MapSet.member?(enabled, "openai-codex") do
        Credentials.build_get_api_key(cfg).(:"openai-codex")
      end

    LemonAi.Models.list_models(
      discover_openai: Keyword.get(opts, :discover_openai, false),
      discover_codex: true,
      codex_access_token: token,
      codex_base_url: Map.get(codex_cfg, :base_url) || Map.get(codex_cfg, "base_url"),
      codex_force_refresh: Keyword.get(opts, :force_refresh, false),
      codex_req_options: Keyword.get(opts, :codex_req_options, [])
    )
    |> Enum.reject(&LemonAi.Models.Presets.preset?(&1.provider))
    |> Kernel.++(preset_models(cfg, enabled, opts))
    |> Enum.filter(&MapSet.member?(enabled, normalize_provider_name(&1.provider)))
    |> merge_configured_models(configured_models(cfg, enabled, routing, opts))
    |> Enum.reject(&picker_model_blocked?(normalize_provider_name(&1.provider), &1.id))
  end

  # `[providers.<id>]` models: custom providers with usable credentials (or
  # `auth = "none"`) and additions to enabled built-in providers. Discovery
  # providers list their endpoint through the shared model cache.
  defp configured_models(cfg, enabled, routing, opts) do
    providers = Map.get(cfg, :providers) || %{}

    cfg
    |> CustomProviders.models(
      discover: Keyword.get(opts, :discover_custom, true),
      discovery_opts: Keyword.get(opts, :custom_discovery_opts, [])
    )
    |> Enum.filter(fn
      %{provider: provider} when is_binary(provider) ->
        Credentials.provider_has_credentials?(provider, providers, provider_routing: routing)

      %{provider: provider} ->
        MapSet.member?(enabled, normalize_provider_name(provider))
    end)
  end

  # Configured entries replace catalog models with the same provider and id.
  defp merge_configured_models(models, []), do: models

  defp merge_configured_models(models, configured) do
    key = &{normalize_provider_name(&1.provider), &1.id}
    configured_keys = MapSet.new(configured, key)
    Enum.reject(models, &MapSet.member?(configured_keys, key.(&1))) ++ configured
  end

  @preset_discovery_timeout_ms 2_000

  defp preset_models(cfg, enabled, opts) do
    providers = Map.get(cfg, :providers) || %{}
    timeout = Keyword.get(opts, :preset_discovery_timeout_ms, @preset_discovery_timeout_ms)

    targets =
      LemonAi.Models.Presets.all()
      |> Enum.filter(&MapSet.member?(enabled, normalize_provider_name(&1.id)))
      |> Enum.flat_map(fn preset ->
        case ProviderNames.provider_config(providers, preset.id) do
          nil when preset.local ->
            if Enum.any?(preset.base_url_env, &(System.get_env(&1) not in [nil, ""])),
              do: [{preset.id, %{}}],
              else: []

          provider_cfg ->
            [{preset.id, provider_cfg || %{}}]
        end
      end)

    get_api_key = if targets != [], do: Credentials.build_get_api_key(cfg)

    targets
    |> Task.async_stream(
      fn {preset, provider_cfg} ->
        LemonAi.Models.discover_preset(preset,
          base_url: config_value(provider_cfg, :base_url),
          api_key: get_api_key.(preset),
          headers: CustomProviders.headers(provider_cfg),
          timeout_ms: timeout,
          force_refresh: Keyword.get(opts, :force_refresh, false),
          req_options: Keyword.get(opts, :preset_req_options, [])
        )
      end,
      max_concurrency: max(length(targets), 1),
      timeout: timeout + 500,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, models}} -> models
      _ -> []
    end)
  end

  defp config_value(cfg, key), do: Map.get(cfg, key) || Map.get(cfg, Atom.to_string(key))

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

  @doc """
  Sorts model maps into picker display order: newest/most-relevant first by
  version, `latest` aliases above pinned releases, then name and id.
  """
  @spec sort_for_picker([model_map()]) :: [model_map()]
  def sort_for_picker(models) when is_list(models) do
    Enum.sort_by(models, &model_picker_sort_key/1, :desc)
  end

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

  defp model_picker_sort_key(model) when is_map(model) do
    provider = String.downcase(model[:provider] || model["provider"] || "")
    name = String.downcase(model[:name] || model["name"] || "")
    id = String.downcase(model[:id] || model["id"] || "")

    {
      provider_specific_rank(provider, name, id),
      version_tuple(name, id),
      release_date(id),
      latest_rank(name, id),
      String.contains?(name, "thinking"),
      name,
      id
    }
  end

  defp model_picker_sort_key(_), do: {0, {0, 0, 0}, 0, 0, false, "", ""}

  defp latest_rank(name, id) do
    if String.contains?(name, "latest") or String.contains?(id, "latest"), do: 1, else: 0
  end

  # Leading release version, preferring the display name without an aggregator
  # vendor prefix ("AI21: Jamba Large 1.7"): "GPT-6.1 Sol" -> {6, 1, 0},
  # "claude-opus-4-5-20251101" -> {4, 5, 0}, "MiniMax-M3" -> {3, 0, 0}.
  # Dates ("2505"), parameter counts ("120b") and context sizes ("256k") are
  # not versions.
  @version_pattern ~r/(?<![\d.])(\d{1,2})(?:[.\-](\d{1,2}))?(?:[.\-](\d{1,2}))?(?![\dbkm])/

  defp version_tuple(name, id) do
    source = if name != "", do: name |> String.split(": ", parts: 2) |> List.last(), else: id

    case Regex.run(@version_pattern, source) do
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

  # Snapshot date as YYYYMMDD, so equal versions list newer snapshots first:
  # "...-20251101", "...-2024-11-20", or a YYMM suffix such as "...-2505".
  @date_pattern ~r/(?<!\d)(20\d{2})-?(\d{2})-?(\d{2})(?!\d)|(?<!\d)(2\d)(0[1-9]|1[0-2])(?!\d)/

  defp release_date(id) do
    case Regex.run(@date_pattern, id) do
      [_, year, month, day] -> String.to_integer(year <> month <> day)
      [_, "", "", "", year, month] -> String.to_integer("20" <> year <> month <> "00")
      _ -> 0
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

  defp picker_model_blocked?("minimax", "MiniMax-M2.7-highspeed"), do: true
  defp picker_model_blocked?(_, _), do: false

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

    Map.get(cfg, :provider_routing) || Map.get(cfg, "provider_routing") ||
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
