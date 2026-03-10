defmodule Mix.Tasks.Lemon.Architecture.Docs do
  use Mix.Task

  alias LemonCore.Quality.ArchitectureDocs

  @shortdoc "Generate architecture boundary docs from policy"
  @moduledoc """
  Regenerate the dependency policy section of docs/architecture_boundaries.md.

  Usage:
    mix lemon.architecture.docs
    mix lemon.architecture.docs --check
    mix lemon.architecture.docs --root /path/to/repo
  """

  @impl true
  def run(args) do
    {opts, _rest, _invalid} =
      OptionParser.parse(args,
        switches: [check: :boolean, root: :string],
        aliases: [r: :root]
      )

    root = opts[:root] || File.cwd!()

    if opts[:check] do
      case ArchitectureDocs.check(root) do
        {:ok, _report} ->
          Mix.shell().info("[ok] architecture docs are up to date")

        {:error, report} ->
          issue = List.first(report.issues)

          Mix.raise("#{issue.message} (#{issue.path})")
      end
    else
      case ArchitectureDocs.write(root) do
        :ok ->
          Mix.shell().info("Updated #{ArchitectureDocs.doc_relative_path()}")

        {:error, issue} ->
          Mix.raise("#{issue.message} (#{issue.path})")
      end
    end
  end
end
