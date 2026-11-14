defmodule LemonCore.CodeReload do
  @moduledoc """
  Soft-loads changed BEAM files without terminating processes using old code.

  Added modules load on demand in interactive mode. Configuration, mix.exs,
  dependencies, new applications, supervision trees and GenServer state-shape
  changes still require a runtime restart.
  """

  @type result :: %{reloaded: [module()], in_use: [module()], failed: [{module(), term()}]}

  @doc "Reloads modified loaded modules, optionally restricted to `:only_under` directories."
  @spec reload_modified(keyword()) :: result()
  def reload_modified(opts \\ []) do
    roots =
      case Keyword.get(opts, :only_under) do
        nil -> nil
        paths -> Enum.map(paths, &Path.expand/1)
      end

    :code.modified_modules()
    |> Enum.filter(&under_roots?(&1, roots))
    |> retry_in_use()
  end

  @doc "Attempts one soft reload of each supplied module; never hard-purges code."
  @spec retry_in_use([module()]) :: result()
  def retry_in_use(modules) do
    modules
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce(%{reloaded: [], in_use: [], failed: []}, fn module, result ->
      if :code.soft_purge(module) do
        case :code.load_file(module) do
          {:module, ^module} -> Map.update!(result, :reloaded, &[module | &1])
          {:error, reason} -> Map.update!(result, :failed, &[{module, reason} | &1])
        end
      else
        Map.update!(result, :in_use, &[module | &1])
      end
    end)
    |> Map.new(fn {key, values} -> {key, Enum.reverse(values)} end)
  end

  defp under_roots?(_module, nil), do: true

  defp under_roots?(module, roots) do
    case :code.which(module) do
      path when is_list(path) ->
        path = path |> List.to_string() |> Path.expand()

        Enum.any?(roots, fn root ->
          relative = Path.relative_to(path, root)
          relative != path and relative != ".." and not String.starts_with?(relative, "../")
        end)

      _ ->
        false
    end
  end
end
