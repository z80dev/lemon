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
    # Only count module names that appear as real source-level defmodule
    # (not inside string literals). We use a simple heuristic: the line
    # must not be inside a heredoc block.
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

  # Extract module names from a file, skipping lines inside heredoc strings.
  defp extract_module_names(file) do
    file
    |> File.read!()
    |> String.split("\n")
    |> reject_heredoc_lines()
    |> Enum.flat_map(fn line ->
      case Regex.run(~r/^\s*defmodule\s+([A-Z][A-Za-z0-9._]*)\s+do/, line) do
        [_, mod_name] -> [mod_name]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # Remove lines that are inside heredoc blocks (between """ ... """)
  defp reject_heredoc_lines(lines) do
    {result, _} =
      Enum.reduce(lines, {[], false}, fn line, {acc, in_heredoc} ->
        cond do
          in_heredoc ->
            # Check if this line ends the heredoc
            if String.contains?(line, ~s["""]) do
              {acc, false}
            else
              {acc, true}
            end

          String.contains?(line, ~s["""]) ->
            # Opening a heredoc - skip this line and enter heredoc mode
            # (unless it opens and closes on same line, which is unusual)
            count = line |> String.split(~s["""]) |> length() |> Kernel.-(1)

            if rem(count, 2) == 0 do
              # Even number of triple-quotes: balanced on one line, not in heredoc
              {[line | acc], false}
            else
              # Odd number: we've entered a heredoc
              {acc, true}
            end

          true ->
            {[line | acc], false}
        end
      end)

    Enum.reverse(result)
  end
end
