defmodule LemonControlPlane.Methods.ModelsPreconnect do
  @moduledoc "Receives content-free compose hints for catalog models only; never accepts URLs."
  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "models.preconnect"
  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(%{"model" => spec}, _ctx) when is_binary(spec) and byte_size(spec) <= 256 do
    model =
      Enum.find_value(LemonAi.Models.get_providers(), fn provider ->
        Enum.find(LemonAi.Models.get_models(provider), fn model ->
          spec == "#{provider}:#{model.id}" or spec == "#{provider}/#{model.id}"
        end)
      end)

    if model, do: LemonAi.preconnect(model)
    {:ok, %{"accepted" => not is_nil(model)}}
  end

  def handle(_, _),
    do: {:error, :invalid_request, "Expected a bounded catalog model identifier", nil}
end
