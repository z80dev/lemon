defmodule LemonCore.Quality.VacuousAssertionCheck do
  @moduledoc """
  Fails on ExUnit assertions that can never fail in tracked umbrella tests
  (`apps/*/test/**/*.exs` and `*.ex`).

  A vacuous assertion is `assert` of a truthy literal (`assert true`,
  `assert :ok`, including `else assert true` fallbacks) or `refute` of a falsy
  literal (`refute false`, `refute nil`). Such a test passes whatever the code
  under test does: an unavailable prerequisite belongs behind a named tag that
  the app's `test_helper.exs` excludes, and an unconfigured live test must fail.

  Files are parsed, so assertions inside strings, heredoc fixtures and comments
  are ignored. In a Git checkout the index is the source of truth; roots without
  `.git` (synthetic test repositories) fall back to a filesystem scan.
  """

  @type issue :: %{code: atom(), message: String.t(), path: String.t()}

  @type report :: %{
          root: String.t(),
          checked_files: non_neg_integer(),
          issue_count: non_neg_integer(),
          issues: [issue()]
        }

  @doc """
  Runs the check. Returns `{:ok, report}` when no vacuous assertion is found,
  `{:error, report}` otherwise.

  ## Options
    * `:root` - repository root to check (defaults to the current working directory)
  """
  @spec run(keyword()) :: {:ok, report()} | {:error, report()}
  def run(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())

    {issues, checked_files} =
      case discover_test_files(root) do
        {:ok, files} ->
          {Enum.flat_map(files, &file_issues(root, &1)), length(files)}

        {:error, message} ->
          {[%{code: :test_discovery_failed, message: message, path: "apps"}], 0}
      end

    report = %{
      root: root,
      checked_files: checked_files,
      issue_count: length(issues),
      issues: issues
    }

    if issues == [], do: {:ok, report}, else: {:error, report}
  end

  defp discover_test_files(root) do
    if File.exists?(Path.join(root, ".git")) do
      case System.cmd("git", ["-C", root, "ls-files", "-z", "--", "apps"], stderr_to_stdout: true) do
        {output, 0} ->
          {:ok, output |> String.split(<<0>>, trim: true) |> filter_test_paths()}

        {output, status} ->
          {:error,
           "Failed to discover tracked tests with git ls-files (exit #{status}): #{String.trim(output)}"}
      end
    else
      files =
        root
        |> Path.join("apps/*/test/**/*.{ex,exs}")
        |> Path.wildcard()
        |> Enum.map(&Path.relative_to(&1, root))

      {:ok, filter_test_paths(files)}
    end
  end

  defp filter_test_paths(paths) do
    paths
    |> Enum.filter(&test_source?/1)
    |> Enum.sort()
  end

  defp test_source?(path) do
    case Path.split(path) do
      ["apps", _app, "test" | [_ | _]] -> Path.extname(path) in [".ex", ".exs"]
      _ -> false
    end
  end

  # A tracked file deleted from the working tree has nothing to check.
  defp file_issues(root, path) do
    case File.read(Path.join(root, path)) do
      {:ok, source} -> source_issues(path, source)
      {:error, _reason} -> []
    end
  end

  defp source_issues(path, source) do
    case Code.string_to_quoted(source, file: path) do
      {:ok, ast} ->
        ast |> vacuous_lines() |> Enum.map(&vacuous_issue(path, &1))

      {:error, {location, _message, _token}} ->
        line = Keyword.get(location, :line)

        [
          %{
            code: :unparseable_test,
            message: "#{path}:#{line}: cannot parse test source",
            path: path
          }
        ]
    end
  end

  defp vacuous_issue(path, {line, source}) do
    %{
      code: :vacuous_assertion,
      message:
        "#{path}:#{line}: `#{source}` cannot fail; assert an observable result, " <>
          "or exclude the test with a named tag when a prerequisite is missing",
      path: path
    }
  end

  defp vacuous_lines(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:assert, meta, [value | _]} = node, acc when is_list(meta) ->
          {node, if(truthy_literal?(value), do: [finding(node, meta) | acc], else: acc)}

        {:refute, meta, [value | _]} = node, acc when is_list(meta) ->
          {node, if(value in [false, nil], do: [finding(node, meta) | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp finding(node, meta), do: {meta[:line], Macro.to_string(node)}

  defp truthy_literal?(value) when value in [false, nil], do: false

  defp truthy_literal?(value),
    do: is_atom(value) or is_number(value) or is_binary(value)
end
