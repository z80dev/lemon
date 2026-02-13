defmodule LemonCore.Quality.DocsCatalog do
  @moduledoc """
  Loads and validates docs catalog metadata used by quality checks.
  """

  @catalog_path "docs/catalog.exs"

  @type entry :: %{
          required(:path) => String.t(),
          required(:owner) => String.t(),
          required(:last_reviewed) => Date.t(),
          required(:max_age_days) => pos_integer(),
          optional(atom()) => any()
        }

  @spec load(keyword()) :: {:ok, [entry()]} | {:error, String.t()}
  def load(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())
    catalog_file = Path.join(root, @catalog_path)

    with :ok <- ensure_catalog_exists(catalog_file),
         {:ok, entries} <- eval_catalog(catalog_file) do
      {:ok, entries}
    end
  end

  @spec catalog_file(String.t()) :: String.t()
  def catalog_file(root) do
    Path.join(root, @catalog_path)
  end

  defp ensure_catalog_exists(path) do
    if File.exists?(path) do
      :ok
    else
      {:error, "Missing catalog file: #{path}"}
    end
  end

  defp eval_catalog(path) do
    try do
      case Code.eval_file(path) do
        {entries, _binding} when is_list(entries) ->
          {:ok, entries}

        {other, _binding} ->
          {:error, "Expected #{path} to evaluate to a list, got: #{inspect(other)}"}
      end
    rescue
      exception ->
        {:error, "Failed to evaluate #{path}: #{Exception.message(exception)}"}
    end
  end
end
