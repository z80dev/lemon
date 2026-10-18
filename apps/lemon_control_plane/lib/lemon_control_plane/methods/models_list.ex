defmodule LemonControlPlane.Methods.ModelsList do
  @moduledoc """
  Handler for the models.list method.

  Returns a list of available AI models.

  The internal `:lemon_control_plane, :model_catalog` callback accepts the same
  options as `ModelCatalog.available_models/1`, allowing boundary tests to supply
  deterministic account-available models without credentials or network access.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "models.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    {models, source} = get_available_models(params || %{})

    {:ok,
     %{
       "models" => models,
       "summary" => summarize_models(models, source),
       "includesCredentials" => false,
       "includesSecretValues" => false
     }}
  end

  defp get_available_models(params) when is_map(params) do
    discover_openai = Map.get(params, "discoverOpenAI", true)

    if Code.ensure_loaded?(LemonAgent.ModelRuntime.ModelCatalog) do
      catalog =
        Application.get_env(
          :lemon_control_plane,
          :model_catalog,
          &LemonAgent.ModelRuntime.ModelCatalog.available_models/1
        )

      models =
        catalog.(
          discover_openai: discover_openai,
          force_refresh: Map.get(params, "forceRefresh", false)
        )
        |> Enum.map(&format_model/1)

      {models, "ai_models"}
    else
      {[], "unavailable"}
    end
  end

  defp format_model(model) when is_struct(model) do
    %{
      "id" => model.id,
      "provider" => to_string(model.provider),
      "name" => model.name || model.id,
      "contextWindow" => model.context_window,
      "maxOutput" => model.max_tokens,
      "supportsThinking" => model.reasoning || false,
      "supportsVision" => :image in model.input,
      "supportsStreaming" => true,
      "pricing" => pricing(Map.get(model, :cost))
    }
  end

  defp format_model(model) when is_map(model) do
    vision_field = get_boolean_field(model, [:supports_vision, "supportsVision"], :missing)

    %{
      "id" => get_field(model, :id),
      "provider" => to_string(get_field(model, :provider)),
      "name" => get_field(model, :name) || get_field(model, :id),
      "contextWindow" => get_field(model, :context_window) || get_field(model, "contextWindow"),
      "maxOutput" =>
        get_field(model, :max_tokens) || get_field(model, "max_tokens") ||
          get_field(model, :max_output) || get_field(model, "maxOutput"),
      "supportsThinking" =>
        get_boolean_field(
          model,
          [:reasoning, "reasoning", :supports_thinking, "supportsThinking"],
          false
        ),
      "supportsVision" =>
        if(vision_field == :missing,
          do: image_input?(get_field(model, :input) || get_field(model, "input")),
          else: vision_field
        ),
      "supportsStreaming" =>
        get_boolean_field(model, [:supports_streaming, "supportsStreaming"], true),
      "pricing" => pricing(get_field(model, :cost))
    }
  end

  defp image_input?(input) when is_list(input), do: Enum.any?(input, &(&1 in [:image, "image"]))
  defp image_input?(_input), do: false

  # USD per million tokens from the catalog; nil when the catalog lists no price.
  defp pricing(%{__struct__: _} = cost), do: cost |> Map.from_struct() |> pricing()

  defp pricing(cost) when is_map(cost) do
    prices = %{
      "inputPerMillion" => price(get_field(cost, :input)),
      "outputPerMillion" => price(get_field(cost, :output)),
      "cacheReadPerMillion" => price(get_field(cost, :cache_read)),
      "cacheWritePerMillion" => price(get_field(cost, :cache_write))
    }

    if Enum.any?(Map.values(prices), &is_number/1), do: prices
  end

  defp pricing(_cost), do: nil

  defp price(value) when is_number(value) and value >= 0, do: value
  defp price(_value), do: nil

  defp summarize_models(models, source) do
    providers =
      models
      |> Enum.map(& &1["provider"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "source" => source,
      "total" => length(models),
      "providerCount" => length(providers),
      "providers" => providers,
      "visionModelCount" => Enum.count(models, &(&1["supportsVision"] == true)),
      "thinkingModelCount" => Enum.count(models, &(&1["supportsThinking"] == true)),
      "streamingModelCount" => Enum.count(models, &(&1["supportsStreaming"] == true))
    }
  end

  defp get_field(map, key) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp get_boolean_field(map, keys, default) do
    Enum.reduce_while(keys, default, fn key, _acc ->
      if Map.has_key?(map, key) do
        {:halt, Map.get(map, key) == true}
      else
        {:cont, default}
      end
    end)
  end
end
