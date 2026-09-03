defmodule LemonAi.Models.XAI do
  @moduledoc """
  Model definitions for the XAI provider.

  The catalog is data: `priv/models/xai.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("xai.json")
  @models Catalog.load!("xai.json")

  @doc "Returns all XAI model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
