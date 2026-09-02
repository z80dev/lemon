defmodule LemonAi.Models.Qwen do
  @moduledoc """
  Model definitions for the Qwen provider.

  The catalog is data: `priv/models/qwen.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("qwen.json")
  @models Catalog.load!("qwen.json")

  @doc "Returns all Qwen model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
