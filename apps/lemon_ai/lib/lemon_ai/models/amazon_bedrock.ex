defmodule LemonAi.Models.AmazonBedrock do
  @moduledoc """
  Model definitions for the AmazonBedrock provider.

  The catalog is data: `priv/models/amazon_bedrock.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("amazon_bedrock.json")
  @models Catalog.load!("amazon_bedrock.json")

  @doc "Returns all AmazonBedrock model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
