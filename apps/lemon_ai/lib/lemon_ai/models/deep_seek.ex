defmodule LemonAi.Models.DeepSeek do
  @moduledoc """
  Model definitions for the DeepSeek provider.

  The catalog is data: `priv/models/deep_seek.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("deep_seek.json")
  @models Catalog.load!("deep_seek.json")

  @doc "Returns all DeepSeek model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
