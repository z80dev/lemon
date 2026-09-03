defmodule LemonAi.Models.GitHubCopilot do
  @moduledoc """
  Model definitions for the GitHubCopilot provider.

  The catalog is data: `priv/models/git_hub_copilot.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("git_hub_copilot.json")
  @models Catalog.load!("git_hub_copilot.json")

  @doc "Returns all GitHubCopilot model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
