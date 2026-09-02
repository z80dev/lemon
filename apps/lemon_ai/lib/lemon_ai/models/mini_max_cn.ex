defmodule LemonAi.Models.MiniMaxCN do
  @moduledoc """
  Model definitions for the MiniMaxCN provider.

  The catalog is data: `priv/models/mini_max_cn.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("mini_max_cn.json")
  @models Catalog.load!("mini_max_cn.json")

  @doc "Returns all MiniMaxCN model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
