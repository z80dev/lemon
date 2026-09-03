defmodule LemonAi.Models.GoogleGeminiCLI do
  @moduledoc """
  Model definitions for the GoogleGeminiCLI provider.

  The catalog is data: `priv/models/google_gemini_cli.json`, loaded at compile time by
  `LemonAi.Models.Catalog`, one entry per model with its capabilities and
  per-million-token pricing. Edit the JSON to add a model or change a price;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Models.Catalog
  alias LemonAi.Types.Model

  @external_resource Catalog.path("google_gemini_cli.json")
  @models Catalog.load!("google_gemini_cli.json")

  @doc "Returns all GoogleGeminiCLI model definitions as a map."
  @spec models() :: %{String.t() => Model.t()}
  def models, do: @models
end
