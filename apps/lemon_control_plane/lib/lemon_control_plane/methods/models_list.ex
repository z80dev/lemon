defmodule LemonControlPlane.Methods.ModelsList do
  @moduledoc """
  Handler for the models.list method.

  Returns a list of available AI models.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "models.list"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(_params, _ctx) do
    models = get_available_models()
    {:ok, %{"models" => models}}
  end

  defp get_available_models do
    # Try to get models from Ai.Models if available
    if Code.ensure_loaded?(Ai.Models) do
      Ai.Models.all()
      |> Enum.map(&format_model/1)
    else
      # Fallback: return common models
      default_models()
    end
  rescue
    _ -> default_models()
  end

  defp format_model(model) when is_struct(model) do
    %{
      "id" => model.id,
      "provider" => to_string(model.provider),
      "name" => model.name || model.id,
      "contextWindow" => model.context_window,
      "maxOutput" => model.max_output,
      "supportsThinking" => model.supports_thinking || false,
      "supportsStreaming" => model.supports_streaming || true
    }
  end

  defp format_model(model) when is_map(model) do
    %{
      "id" => model[:id] || model["id"],
      "provider" => to_string(model[:provider] || model["provider"]),
      "name" => model[:name] || model["name"] || model[:id] || model["id"],
      "contextWindow" => model[:context_window] || model["contextWindow"],
      "maxOutput" => model[:max_output] || model["maxOutput"],
      "supportsThinking" => model[:supports_thinking] || model["supportsThinking"] || false,
      "supportsStreaming" => model[:supports_streaming] || model["supportsStreaming"] || true
    }
  end

  defp default_models do
    [
      %{
        "id" => "claude-sonnet-4-20250514",
        "provider" => "anthropic",
        "name" => "Claude Sonnet 4",
        "contextWindow" => 200_000,
        "maxOutput" => 16_384,
        "supportsThinking" => true,
        "supportsStreaming" => true
      },
      %{
        "id" => "claude-opus-4-20250514",
        "provider" => "anthropic",
        "name" => "Claude Opus 4",
        "contextWindow" => 200_000,
        "maxOutput" => 32_768,
        "supportsThinking" => true,
        "supportsStreaming" => true
      },
      %{
        "id" => "gpt-4o",
        "provider" => "openai",
        "name" => "GPT-4o",
        "contextWindow" => 128_000,
        "maxOutput" => 16_384,
        "supportsThinking" => false,
        "supportsStreaming" => true
      }
    ]
  end
end
