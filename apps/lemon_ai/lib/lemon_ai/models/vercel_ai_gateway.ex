defmodule LemonAi.Models.VercelAIGateway do
  @moduledoc """
  Model catalog for the Vercel AI Gateway provider — a compile-time `@models`

  The catalog is data: `priv/models/vercel_ai_gateway.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("vercel_ai_gateway.json")
  @models Catalog.load!("vercel_ai_gateway.json")

  @doc "Returns all VercelAIGateway model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
