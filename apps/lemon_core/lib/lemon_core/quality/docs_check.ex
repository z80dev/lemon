defmodule LemonCore.Quality.DocsCheck do
  @moduledoc """
  Checks that local markdown links in tracked `docs/**/*.md` files resolve to
  existing files.

  In a Git checkout the Git index (`git ls-files docs`) is the source of truth,
  so untracked scratch files never fail the check. Roots without a `.git`
  entry (synthetic test repositories) fall back to a filesystem scan.
  """

  # Inline link: `[text](destination "optional title")`. The destination is
  # either `<...>` or a run without whitespace; the optional title (`"..."`,
  # `'...'` or `(...)`) is matched separately so it never becomes part of the
  # destination.
  @link_regex ~r/\[[^\]]+\]\(\s*(?<destination>(?:<[^>]*>|[^\s)]+))(?:\s+(?<title>"[^"]*"|'[^']*'|\([^)]*\)))?\s*\)/

  @type issue :: %{
          code: atom(),
          message: String.t(),
          path: String.t() | nil
        }

  @type report :: %{
          root: String.t(),
          checked_files: non_neg_integer(),
          issue_count: non_neg_integer(),
          issues: [issue()]
        }

  @doc """
  Runs the docs link check.

  Returns `{:ok, report}` if no issues were found, `{:error, report}` otherwise.

  ## Options
    * `:root` - repository root to check (defaults to the current working directory)
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, report()}
  def run(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())

    {issues, checked_files} =
      case discover_tracked_docs(root) do
        {:ok, docs} ->
          {Enum.flat_map(docs, &link_issues(root, &1)), length(docs)}

        {:error, message} ->
          {[%{code: :tracked_docs_discovery_failed, message: message, path: "docs"}], 0}
      end

    report = %{
      root: root,
      checked_files: checked_files,
      issue_count: length(issues),
      issues: issues
    }

    if issues == [], do: {:ok, report}, else: {:error, report}
  end

  @spec discover_tracked_docs(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  defp discover_tracked_docs(root) do
    if File.exists?(Path.join(root, ".git")) do
      discover_git_tracked_docs(root)
    else
      {:ok, discover_filesystem_docs(root)}
    end
  end

  defp discover_git_tracked_docs(root) do
    case System.cmd("git", ["-C", root, "ls-files", "-z", "--", "docs"], stderr_to_stdout: true) do
      {output, 0} ->
        docs =
          output
          |> String.split(<<0>>, trim: true)
          |> filter_docs_paths()

        {:ok, docs}

      {output, status} ->
        {:error,
         "Failed to discover tracked docs with git ls-files (exit #{status}): #{String.trim(output)}"}
    end
  end

  defp discover_filesystem_docs(root) do
    root
    |> Path.join("docs/**/*.md")
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, root))
    |> filter_docs_paths()
  end

  defp filter_docs_paths(paths) do
    paths
    |> Enum.filter(&String.ends_with?(&1, ".md"))
    |> Enum.reject(&String.contains?(&1, "node_modules/"))
    |> Enum.sort()
  end

  # A tracked doc deleted from the working tree has nothing to check.
  @spec link_issues(String.t(), String.t()) :: [issue()]
  defp link_issues(root, path) do
    full_path = Path.join(root, path)

    case File.read(full_path) do
      {:ok, content} ->
        content
        |> broken_links(root, full_path)
        |> Enum.map(fn target ->
          %{
            code: :broken_link,
            message: "Broken local markdown link in #{path}: #{target}",
            path: path
          }
        end)

      {:error, _reason} ->
        []
    end
  end

  @spec broken_links(String.t(), String.t(), String.t()) :: [String.t()]
  defp broken_links(content, root, file_path) do
    @link_regex
    |> Regex.scan(content, capture: [:destination])
    |> List.flatten()
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&local_link?/1)
    |> Enum.reject(&link_exists?(root, file_path, &1))
    |> Enum.uniq()
  end

  @spec local_link?(String.t()) :: boolean()
  defp local_link?(link) do
    not (link == "" or
           String.starts_with?(link, "#") or
           String.starts_with?(link, "http://") or
           String.starts_with?(link, "https://") or
           String.starts_with?(link, "mailto:"))
  end

  @spec link_exists?(String.t(), String.t(), String.t()) :: boolean()
  defp link_exists?(root, source_file, link) do
    clean_link =
      link
      |> String.trim_leading("<")
      |> String.trim_trailing(">")
      |> String.split("#")
      |> List.first()

    if clean_link == "" do
      true
    else
      target_path =
        if Path.type(clean_link) == :absolute do
          Path.join(root, String.trim_leading(clean_link, "/"))
        else
          source_file
          |> Path.dirname()
          |> Path.join(clean_link)
        end

      File.exists?(Path.expand(target_path))
    end
  end
end
