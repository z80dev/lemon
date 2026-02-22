defmodule Mix.Tasks.Lemon.CheckDuplicateTests do
  use Mix.Task

  @shortdoc "Check for duplicate test module definitions across files"
  @moduledoc """
  Scans all test files in apps/*/test/**/*_test.exs and reports any
  defmodule names that appear in more than one distinct file.

  Module definitions that appear multiple times within a single file
  (intentional same-file helpers) are not flagged.

  Exits with status 1 if cross-file duplicates are found.

  Usage:
    mix lemon.check_duplicate_tests
  """

  @impl true
  def run(_args) do
    root = File.cwd!()
    test_files = Path.wildcard(Path.join(root, "apps/*/test/**/*_test.exs"))

    # Build map of module_name -> [file1, file2, ...]
    # Module names are extracted via AST parsing so that defmodule inside
    # string literals, heredocs, and comments are never matched.
    module_to_files =
      Enum.reduce(test_files, %{}, fn file, acc ->
        modules = extract_module_names(file)

        Enum.reduce(modules, acc, fn mod, inner_acc ->
          existing = Map.get(inner_acc, mod, [])

          if file in existing do
            inner_acc
          else
            Map.put(inner_acc, mod, [file | existing])
          end
        end)
      end)

    duplicates =
      module_to_files
      |> Enum.filter(fn {_mod, files} -> length(files) > 1 end)
      |> Enum.sort_by(fn {mod, _} -> mod end)

    if duplicates == [] do
      Mix.shell().info("0 cross-file duplicate test module definitions found.")
    else
      Mix.shell().error(
        "#{length(duplicates)} cross-file duplicate test module definition(s) found:\n"
      )

      Enum.each(duplicates, fn {mod, files} ->
        Mix.shell().error("  #{mod}")

        Enum.each(Enum.sort(files), fn f ->
          rel = Path.relative_to(f, root)
          Mix.shell().error("    - #{rel}")
        end)
      end)

      Mix.raise("Duplicate test modules found. See above for details.")
    end
  end

  # Extract module names by parsing the file into an Elixir AST and walking
  # all defmodule nodes. This avoids false positives from defmodule appearing
  # inside string literals, heredocs, and comments.
  defp extract_module_names(file) do
    source = File.read!(file)

    case Code.string_to_quoted(source, file: file, columns: true) do
      {:ok, ast} ->
        ast
        |> collect_defmodule_names([])
        |> Enum.uniq()

      {:error, _} ->
        # If the file can't be parsed (syntax error), fall back to empty
        # rather than crashing the whole scan.
        []
    end
  end

  # Match a defmodule node, record its name, and continue walking its body
  # so that nested defmodules are also collected.
  defp collect_defmodule_names(
         {:defmodule, _meta, [{:__aliases__, _, parts} | rest]},
         acc
       )
       when is_list(parts) do
    module_name = parts |> Enum.map(&to_string/1) |> Enum.join(".")
    Enum.reduce(rest, [module_name | acc], &collect_defmodule_names/2)
  end

  # Walk any other AST node that has a children list.
  defp collect_defmodule_names({_form, _meta, children}, acc) when is_list(children) do
    Enum.reduce(children, acc, &collect_defmodule_names/2)
  end

  # Walk two-element tuples (keyword pairs inside AST).
  defp collect_defmodule_names({left, right}, acc) do
    acc
    |> collect_defmodule_names_in(left)
    |> collect_defmodule_names_in(right)
  end

  # Walk plain lists.
  defp collect_defmodule_names(list, acc) when is_list(list) do
    Enum.reduce(list, acc, &collect_defmodule_names/2)
  end

  # Leaf nodes (atoms, numbers, strings, etc.) — nothing to collect.
  defp collect_defmodule_names(_other, acc), do: acc

  # Helper to keep argument order consistent when called from tuple walking.
  defp collect_defmodule_names_in(acc, node), do: collect_defmodule_names(node, acc)
end
