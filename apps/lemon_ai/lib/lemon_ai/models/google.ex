defmodule LemonAi.Models.Google do
  @moduledoc """
  Model definitions for the Google provider.

  The catalog is data: `priv/models/google.json`, loaded at compile time by
  `LemonAi.Models.Catalog`. `antigravity_models/0` is the `:google_antigravity`
  virtual provider: the entries of that catalog tagged with the provider plus
  the antigravity-only extras in `priv/models/google_antigravity_extras.json`.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("google.json")
  @external_resource Catalog.path("google_antigravity_extras.json")

  @models Catalog.load!("google.json")

  @antigravity_models Map.merge(
                        Map.filter(@models, fn {_id, %Model{provider: provider}} ->
                          provider == :google_antigravity
                        end),
                        Catalog.load!("google_antigravity_extras.json")
                      )

  @doc "Returns all Google model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models

  @doc "Returns the models of the `:google_antigravity` virtual provider."
  @spec antigravity_models() :: %{String.t() => Model.t()}
  def antigravity_models, do: @antigravity_models
end
