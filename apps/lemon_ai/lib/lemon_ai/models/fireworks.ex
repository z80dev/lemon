defmodule LemonAi.Models.Fireworks do
  @moduledoc """
  Model definitions for the Fireworks AI provider.

  The catalog is data: `priv/models/fireworks.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("fireworks.json")
  @models Catalog.load!("fireworks.json")

  @doc "Returns all Fireworks model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
