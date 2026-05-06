defmodule Mix.Tasks.Lemon.CheckDuplicateTests do
  use Mix.Task

  @shortdoc "Check for duplicate test module names"
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

  @moduledoc """
  Scans test files for duplicate `defmodule` names.

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

    duplicates =
      root
      |> test_files()
      |> Enum.flat_map(&module_occurrences(root, &1))
      |> Enum.group_by(fn {module_name, _path} -> module_name end, fn {_module_name, path} ->
        path
      end)
      |> Enum.filter(fn {_module_name, paths} -> length(paths) > 1 end)
      |> Enum.sort_by(fn {module_name, _paths} -> module_name end)

    if duplicates == [] do
      Mix.shell().info("[ok] duplicate test module check passed")
    else
      details =
        Enum.map_join(duplicates, "\n", fn {module_name, paths} ->
          "  - #{module_name}: #{Enum.join(Enum.sort(paths), ", ")}"
        end)

      Mix.raise("Duplicate test modules found:\n#{details}")
    end
  end

  defp module_occurrences(root, file) do
    with {:ok, source} <- File.read(file),
         {:ok, ast} <- Code.string_to_quoted(source) do
      {_ast, modules} =
        Macro.prewalk(ast, [], fn
          {:defmodule, _meta, [{:__aliases__, _alias_meta, parts}, [do: _body]]} = node, acc ->
            module_name = Enum.map_join(parts, ".", &Atom.to_string/1)
            path = Path.relative_to(file, root)
            {node, [{module_name, path} | acc]}

          node, acc ->
            {node, acc}
        end)

      modules
    else
      _ -> []
    end
  end

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
