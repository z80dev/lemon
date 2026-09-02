defmodule LemonAi.Models.MiniMax do
  @moduledoc """
  Model definitions for the MiniMax provider.

  The catalog is data: `priv/models/mini_max.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("mini_max.json")
  @models Catalog.load!("mini_max.json")

  @doc "Returns all MiniMax model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
