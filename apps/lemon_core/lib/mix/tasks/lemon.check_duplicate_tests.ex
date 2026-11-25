defmodule Mix.Tasks.Lemon.CheckDuplicateTests do
  use Mix.Task

  @shortdoc "Check for duplicate test modules and layered test families"
  @ignored_dirs MapSet.new([
                  ".elixir_ls",
                  ".expert",
                  ".git",
                  ".worktrees",
                  "_build",
                  "cover",
                  "deps",
                  "node_modules",
                  "tmp"
                ])

  @layered_suffixes "additional_edge_cases|edge_cases|comprehensive|extended|consolidation"
  @layered_module_suffixes "AdditionalEdgeCases|EdgeCases|Comprehensive|Extended|Consolidation"

  @moduledoc """
  Scans test files for duplicate literal module declarations, resolving nested
  names against their enclosing module and respecting absolute `Elixir` names.

  It also rejects layered test families: a test file with a
  `_additional_edge_cases`, `_edge_cases`, `_comprehensive`, `_extended` or
  `_consolidation` suffix fails when its canonical sibling (`foo_test.exs` in
  the same directory) or canonical module (`FooTest` for `FooEdgeCasesTest`)
  exists. Fold such cases into the canonical file instead.

  Usage:
    mix lemon.check_duplicate_tests
    mix lemon.check_duplicate_tests --root /path/to/repo
  """

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [root: :string],
        aliases: [r: :root]
      )

    root = opts[:root] || File.cwd!()
    files = test_files(root)
    occurrences = Enum.flat_map(files, &module_occurrences(root, &1))

    modules =
      Enum.group_by(occurrences, fn {module_name, _path} -> module_name end, fn {_name, path} ->
        path
      end)

    duplicates =
      modules
      |> Enum.filter(fn {_module_name, paths} -> length(paths) > 1 end)
      |> Enum.sort_by(fn {module_name, _paths} -> module_name end)

    layered = layered_files(root, files, occurrences, modules)

    errors =
      [
        duplicates != [] &&
          "Duplicate test modules found:\n" <>
            Enum.map_join(duplicates, "\n", fn {module_name, paths} ->
              "  - #{module_name}: #{Enum.join(Enum.sort(paths), ", ")}"
            end),
        layered != [] &&
          "Layered test files found beside their canonical test; fold their cases into it:\n" <>
            Enum.map_join(layered, "\n", fn {path, canonical} ->
              "  - #{path} (canonical: #{canonical})"
            end)
      ]
      |> Enum.filter(&is_binary/1)

    if errors == [] do
      Mix.shell().info("[ok] duplicate test module check passed")
    else
      Mix.raise(Enum.join(errors, "\n"))
    end
  end

  defp layered_files(root, files, occurrences, modules) do
    file_pattern = Regex.compile!("^(.+?)_(#{@layered_suffixes})_test\\.exs$")
    module_pattern = Regex.compile!("^(.+?)(#{@layered_module_suffixes})Test$")

    by_path =
      Enum.flat_map(files, fn file ->
        case Regex.run(file_pattern, Path.basename(file)) do
          [_, base, _suffix] ->
            canonical = Path.join(Path.dirname(file), base <> "_test.exs")

            if File.regular?(canonical),
              do: [{Path.relative_to(file, root), Path.relative_to(canonical, root)}],
              else: []

          nil ->
            []
        end
      end)

    by_module =
      Enum.flat_map(occurrences, fn {module_name, path} ->
        with [_, base, _suffix] <- Regex.run(module_pattern, module_name),
             [canonical | _] <- Map.get(modules, base <> "Test"),
             true <- canonical != path do
          [{path, canonical}]
        else
          _ -> []
        end
      end)

    (by_path ++ by_module)
    |> Enum.uniq_by(fn {path, _canonical} -> path end)
    |> Enum.sort()
  end

  defp module_occurrences(root, file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source) do
      collect_modules(ast, [], Path.relative_to(file, root), [])
    else
      _ -> []
    end
  end

  defp collect_modules({:defmodule, _, [name, [do: body]]}, namespace, path, modules) do
    case module_parts(name, namespace) do
      nil ->
        modules

      parts ->
        collect_modules(body, parts, path, [{Enum.join(parts, "."), path} | modules])
    end
  end

  defp collect_modules({_form, _metadata, args}, namespace, path, modules) when is_list(args),
    do: collect_modules(args, namespace, path, modules)

  defp collect_modules({_key, value}, namespace, path, modules),
    do: collect_modules(value, namespace, path, modules)

  defp collect_modules(nodes, namespace, path, modules) when is_list(nodes),
    do: Enum.reduce(nodes, modules, &collect_modules(&1, namespace, path, &2))

  defp collect_modules(_node, _namespace, _path, modules), do: modules

  defp module_parts({:__aliases__, _, [:"Elixir" | parts]}, _namespace), do: parts

  defp module_parts({:__aliases__, _, [{:__MODULE__, _, _} | parts]}, namespace),
    do: namespace ++ parts

  defp module_parts({:__aliases__, _, parts}, namespace), do: namespace ++ parts
  defp module_parts({:__MODULE__, _, _}, namespace), do: namespace

  defp module_parts(name, _namespace) when is_atom(name),
    do: name |> Atom.to_string() |> String.trim_leading("Elixir.") |> String.split(".")

  defp module_parts(_dynamic, _namespace), do: nil

  defp test_files(root) do
    root
    |> Path.join("apps")
    |> walk_test_files(root)
    |> Enum.uniq()
  end

  defp walk_test_files(dir, root) do
    if ignored_path?(root, dir) do
      []
    else
      case File.ls(dir) do
        {:ok, entries} ->
          Enum.flat_map(entries, fn entry ->
            path = Path.join(dir, entry)

            cond do
              ignored_path?(root, path) ->
                []

              symlink?(path) ->
                []

              File.dir?(path) ->
                walk_test_files(path, root)

              String.ends_with?(path, "_test.exs") ->
                [path]

              true ->
                []
            end
          end)

        {:error, _} ->
          []
      end
    end
  end

  defp ignored_path?(root, path) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.any?(&MapSet.member?(@ignored_dirs, &1))
  end

  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
end
