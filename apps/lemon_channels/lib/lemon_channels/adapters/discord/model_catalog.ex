defmodule LemonChannels.Adapters.Discord.ModelCatalog do
  @moduledoc """
  Model/provider catalog for the Discord adapter's `/model` picker.

  Builds the grouped, enabled-provider catalog from `Ai.Models` (falling back to a
  small static list when that module is unavailable), and resolves which providers
  are enabled from `LemonCore.Config`. Pure with respect to transport state;
  extracted from `LemonChannels.Adapters.Discord.Transport` so the picker's data
  layer is independently readable and testable.
  """

  # Public entry points used by the transport's model picker.
  def available_model_providers do
    available_model_catalog()
    |> Enum.map(& &1.provider)
  end

  def models_for_provider(provider) when is_binary(provider) do
    available_model_catalog()
    |> Enum.find_value([], fn
      %{provider: ^provider, models: models} -> models
      _ -> nil
    end)
  end

  def model_at_index(provider, index)
      when is_binary(provider) and is_integer(index) and index >= 0 do
    models_for_provider(provider) |> Enum.at(index)
  end

  def model_at_index(_, _), do: nil

  def model_spec(%{provider: provider, id: id}) when is_binary(provider) and is_binary(id),
    do: "#{provider}:#{id}"

  def model_spec(_), do: nil

  def model_label(%{name: name, id: id}) when is_binary(name) and name != "" and is_binary(id),
    do: "#{name} (#{id})"

  def model_label(%{id: id}) when is_binary(id), do: id
  def model_label(other), do: inspect(other)

  defp available_model_catalog do
    models_module = :"Elixir.Ai.Models"

    models =
      if Code.ensure_loaded?(models_module) and function_exported?(models_module, :list_models, 0) do
        apply(models_module, :list_models, [])
      else
        fallback_model_entries()
      end

    model_maps =
      models
      |> Enum.map(&to_model_map/1)
      |> Enum.filter(&is_map/1)

    filtered =
      model_maps
      |> filter_enabled_model_maps()
      |> maybe_fallback_to_default_providers(model_maps)

    filtered
    |> Enum.group_by(& &1.provider)
    |> Enum.map(fn {provider, provider_models} ->
      %{
        provider: provider,
        models:
          Enum.sort_by(provider_models, fn m ->
            {String.downcase(m.name || m.id || ""), m.id || ""}
          end)
      }
    end)
    |> Enum.sort_by(& &1.provider)
  rescue
    _ -> fallback_catalog()
  end

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

  defp filter_enabled_model_maps(model_maps) when is_list(model_maps) do
    enabled = enabled_model_provider_names(model_maps)
    Enum.filter(model_maps, fn model -> normalize_provider_name(model.provider) in enabled end)
  end

  defp maybe_fallback_to_default_providers([], model_maps) when is_list(model_maps) do
    cfg = LemonCore.Config.cached()
    defaults = default_provider_hints(cfg)
    Enum.filter(model_maps, fn model -> normalize_provider_name(model.provider) in defaults end)
  rescue
    _ -> []
  end

  defp maybe_fallback_to_default_providers(filtered, _), do: filtered

  defp enabled_model_provider_names(model_maps) when is_list(model_maps) do
    cfg = LemonCore.Config.cached()
    configured = configured_provider_index(cfg)
    defaults = default_provider_hints(cfg)

    model_maps
    |> Enum.map(&normalize_provider_name(&1.provider))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.filter(fn provider ->
      provider_enabled?(provider, configured, defaults)
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

  defp default_provider_hints(cfg) do
    agent = map_get(cfg, :agent) || %{}
    provider = map_get(agent, :default_provider)
    model = map_get(agent, :default_model)
    {model_provider, _} = split_model_hint(model)

    [provider, model_provider]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.map(&normalize_provider_name/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  rescue
    _ -> []
  end

  defp split_model_hint(hint) when is_binary(hint) and hint != "" do
    case String.split(hint, ":", parts: 2) do
      [p, m] when p != "" and m != "" -> {p, m}
      _ -> {nil, hint}
    end
  end

  defp split_model_hint(_), do: {nil, nil}

  defp provider_enabled?(provider, configured, defaults) do
    Map.has_key?(configured, provider) or provider in defaults or
      provider_has_credentials?(provider, configured)
  end

  defp provider_has_credentials?(provider, configured) do
    AgentCore.ModelRuntime.Credentials.provider_has_credentials?(provider, configured)
  rescue
    _ -> false
  end

  defp normalize_provider_name(name) when is_binary(name), do: String.downcase(String.trim(name))

  defp normalize_provider_name(name) when is_atom(name),
    do: name |> Atom.to_string() |> normalize_provider_name()

  defp normalize_provider_name(_), do: ""

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_, _), do: nil
end
