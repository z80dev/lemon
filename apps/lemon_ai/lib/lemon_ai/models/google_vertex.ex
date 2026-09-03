defmodule LemonAi.Models.GoogleVertex do
  @moduledoc """
  Model definitions for the GoogleVertex provider.

  The catalog is data: `priv/models/google_vertex.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("google_vertex.json")
  @models Catalog.load!("google_vertex.json")

  @doc "Returns all GoogleVertex model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
