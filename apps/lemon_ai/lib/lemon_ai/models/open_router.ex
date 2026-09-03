defmodule LemonAi.Models.OpenRouter do
  @moduledoc """
  Model catalog for the OpenRouter provider — a compile-time `@models` data map,

  The catalog is data: `priv/models/open_router.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("open_router.json")
  @models Catalog.load!("open_router.json")

  @doc "Returns all OpenRouter model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
