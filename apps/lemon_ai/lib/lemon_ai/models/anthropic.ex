defmodule LemonAi.Models.Anthropic do
  @moduledoc """
  Model definitions for the Anthropic provider.

  The catalog is data: `priv/models/anthropic.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("anthropic.json")
  @models Catalog.load!("anthropic.json")

  @doc "Returns all Anthropic model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
