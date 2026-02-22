defmodule Mix.Tasks.Lemon.CheckDuplicateTests do
  @moduledoc "Detect duplicate test module definitions across the umbrella"
  @shortdoc "Check for duplicate test modules"

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    test_files = Path.wildcard("apps/*/test/**/*_test.exs")

    Mix.shell().info("Scanning #{length(test_files)} test file(s)...")

    # Build a map of module_name => [file_path, ...]
    module_to_files =
      Enum.reduce(test_files, %{}, fn file, acc ->
        modules = extract_modules(file)

        Enum.reduce(modules, acc, fn mod, inner_acc ->
          Map.update(inner_acc, mod, [file], fn existing -> [file | existing] end)
        end)
      end)

    # Keep only modules defined in more than one file
    duplicates =
      module_to_files
      |> Enum.filter(fn {_mod, files} -> length(files) > 1 end)
      |> Enum.sort_by(fn {mod, _} -> mod end)

    if duplicates == [] do
      Mix.shell().info("No duplicate test module definitions found.")
    else
      Mix.shell().error("Duplicate test module definitions detected:")

      Enum.each(duplicates, fn {mod, files} ->
        Mix.shell().error("  #{mod}")

        Enum.each(Enum.sort(files), fn f ->
          Mix.shell().error("    - #{f}")
        end)
      end)

      Mix.raise(
        "Found #{length(duplicates)} duplicate test module(s). Fix the above conflicts before merging."
      )
    end
  end

  defp extract_modules(file) do
    case File.read(file) do
      {:ok, content} ->
        ~r/defmodule\s+([\w.]+)\s+do/
        |> Regex.scan(content, capture: :all_but_first)
        |> List.flatten()

      {:error, reason} ->
        Mix.shell().error("Could not read #{file}: #{reason}")
        []
    end
  end
end
