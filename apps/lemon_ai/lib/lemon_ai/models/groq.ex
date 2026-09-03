defmodule LemonAi.Models.Groq do
  @moduledoc """
  Model definitions for the Groq provider.

  The catalog is data: `priv/models/groq.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("groq.json")
  @models Catalog.load!("groq.json")

  @doc "Returns all Groq model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
