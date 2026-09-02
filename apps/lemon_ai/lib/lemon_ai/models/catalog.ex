defmodule LemonAi.Models.Catalog do
  @moduledoc """
  Reads a provider's model catalog from `priv/models/<name>.json`.

  A catalog is data: one JSON object per provider, keyed by the model id the
  registry answers to (an alias key may differ from the entry's own `id`),
  each entry carrying the fields of `LemonAi.Types.Model` with `api`,
  `provider` and `input` as strings and `cost` as a `LemonAi.Types.ModelCost`
  object. The provider modules under `LemonAi.Models.*` load their file at
  compile time:

      @external_resource LemonAi.Models.Catalog.path("deep_seek.json")
      @models LemonAi.Models.Catalog.load!("deep_seek.json")
      def models, do: @models

  so a catalog edit recompiles the module and the registry keeps its
  compile-time shape. Editing a model or its price is editing the JSON file;
  `mix lemon.models` lists what is currently defined.
  """

  alias LemonAi.Types.{Model, ModelCost}

  @priv_models Path.expand("../../../priv/models", __DIR__)

  @doc """
  The source path of a catalog file, for `@external_resource`.

  Resolved against the source tree, which is where the compile-time load
  happens; the files also ship in the application's `priv/models`.
  """
  @spec path(String.t()) :: Path.t()
  def path(name) when is_binary(name), do: Path.join(@priv_models, name)

  @doc "Loads a catalog into a map of model key to `LemonAi.Types.Model`."
  @spec load!(String.t()) :: %{String.t() => Model.t()}
  def load!(name) when is_binary(name) do
    name
    |> path()
    |> File.read!()
    |> Jason.decode!()
    |> Map.new(fn {key, entry} -> {key, to_model(entry)} end)
  end

  defp to_model(%{"id" => id} = entry) when is_binary(id) do
    %Model{
      id: id,
      name: Map.fetch!(entry, "name"),
      api: String.to_atom(Map.fetch!(entry, "api")),
      provider: String.to_atom(Map.fetch!(entry, "provider")),
      base_url: Map.fetch!(entry, "base_url"),
      reasoning: Map.fetch!(entry, "reasoning"),
      input: Enum.map(Map.fetch!(entry, "input"), &String.to_atom/1),
      cost: to_cost(Map.fetch!(entry, "cost")),
      context_window: Map.fetch!(entry, "context_window"),
      max_tokens: Map.fetch!(entry, "max_tokens"),
      headers: Map.get(entry, "headers", %{}),
      compat: Map.get(entry, "compat")
    }
  end

  defp to_cost(%{} = cost) do
    %ModelCost{
      input: Map.fetch!(cost, "input"),
      output: Map.fetch!(cost, "output"),
      cache_read: Map.fetch!(cost, "cache_read"),
      cache_write: Map.fetch!(cost, "cache_write")
    }
  end
end
