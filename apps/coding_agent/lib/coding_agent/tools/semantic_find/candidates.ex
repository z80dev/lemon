defmodule CodingAgent.Tools.SemanticFind.Candidates do
  @moduledoc """
  Bounded, model-free candidate generation for `semantic_find`.

  There is no persistent index or second store: each call walks the requested
  roots once, skips hidden entries, heavy dependency/build directories, symlinks,
  `.gitignore`d files, oversized files and binary/invalid UTF-8 files, and scores
  lines by overlap with keywords from the behavior description (path components
  count and definition lines get a bonus). Only the best few lines per file
  survive. The scan is capped by file count and total bytes; `collect/5` reports
  when a cap was hit.
  """

  alias CodingAgent.Tools.IgnoreFilter
  import LemonAgent.Tools.AbortHelpers, only: [aborted?: 1]

  @skip_dirs ~w(node_modules _build deps target dist build vendor __pycache__)
  @max_files 20_000
  @max_file_bytes 256 * 1024
  @max_total_bytes 64 * 1024 * 1024
  @max_lines_per_file 3
  @max_line_chars 160
  @stopwords ~w(the and for with that this when where what which how does are was were not
    but can will into from have has had its out all any code function functions method methods
    file files find show locate implementation implemented handle handles handled logic
    something somewhere using used uses use via per then than they them their there)

  @type candidate :: %{
          path: String.t(),
          line: pos_integer(),
          text: String.t(),
          score: pos_integer()
        }

  @doc "Extracts lowercase keyword stems from a behavior description."
  @spec keywords(String.t()) :: [String.t()]
  def keywords(query) when is_binary(query) do
    query
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.downcase()
    |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)
    |> Enum.filter(&(String.length(&1) >= 3 and &1 not in @stopwords))
    |> Enum.map(&stem/1)
    |> Enum.uniq()
  end

  @doc """
  Returns the best `limit` candidates (best first) and whether a scan cap was hit.

  `roots` are absolute directories or files; `cwd` makes reported paths relative.
  """
  @spec collect([String.t()], [String.t()], String.t(), pos_integer(), reference() | nil) ::
          {:ok, [candidate()], boolean()} | {:error, :aborted}
  def collect(roots, keywords, cwd, limit, signal) do
    {files, files_truncated?} = list_files(roots)

    case scan(files, keywords, cwd, signal) do
      {:ok, candidates, bytes_truncated?} ->
        sorted =
          candidates
          |> Enum.sort_by(&{-&1.score, &1.path, &1.line})
          |> Enum.take(limit)

        {:ok, sorted, files_truncated? or bytes_truncated?}

      {:error, :aborted} = aborted ->
        aborted
    end
  end

  # -- File discovery ----------------------------------------------------------

  defp list_files(roots) do
    {files, truncated?} =
      Enum.reduce(roots, {[], false}, fn root, {acc, truncated?} ->
        {found, more?} = walk([root], [], 0)
        kept = IgnoreFilter.reject_ignored(found, base_dir(root))
        {kept ++ acc, truncated? or more?}
      end)

    {files |> Enum.uniq() |> Enum.sort(), truncated?}
  end

  defp base_dir(root), do: if(File.dir?(root), do: root, else: Path.dirname(root))

  defp walk([], files, _count), do: {files, false}
  defp walk(_pending, files, count) when count >= @max_files, do: {files, true}

  defp walk([path | rest], files, count) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_file_bytes ->
        walk(rest, [path | files], count + 1)

      {:ok, %File.Stat{type: :directory}} ->
        children =
          case File.ls(path) do
            {:ok, entries} ->
              entries
              |> Enum.reject(&(String.starts_with?(&1, ".") or &1 in @skip_dirs))
              |> Enum.sort()
              |> Enum.map(&Path.join(path, &1))

            {:error, _} ->
              []
          end

        walk(children ++ rest, files, count)

      _ ->
        walk(rest, files, count)
    end
  end

  # -- Scoring -----------------------------------------------------------------

  defp scan(files, keywords, cwd, signal) do
    files
    |> Enum.reduce_while({:ok, [], 0}, fn file, {:ok, acc, bytes} ->
      cond do
        aborted?(signal) ->
          {:halt, {:error, :aborted}}

        bytes >= @max_total_bytes ->
          {:halt, {:ok, acc, bytes}}

        true ->
          case File.read(file) do
            {:ok, content} ->
              {:cont,
               {:ok, score_file(file, content, keywords, cwd) ++ acc, bytes + byte_size(content)}}

            {:error, _} ->
              {:cont, {:ok, acc, bytes}}
          end
      end
    end)
    |> case do
      {:ok, acc, bytes} -> {:ok, acc, bytes >= @max_total_bytes}
      {:error, :aborted} = aborted -> aborted
    end
  end

  defp score_file(file, content, keywords, cwd) do
    if String.valid?(content) and not String.contains?(content, <<0>>) do
      rel = Path.relative_to(file, cwd)
      path_hits = hits(String.downcase(rel), keywords)
      pattern = definition_pattern()

      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {line, number} ->
        score_line(rel, line, number, keywords, path_hits, pattern)
      end)
      |> Enum.sort_by(&(-&1.score))
      |> Enum.take(@max_lines_per_file)
    else
      []
    end
  end

  defp score_line(rel, line, number, keywords, path_hits, pattern) do
    trimmed = String.trim(line)
    line_hits = if trimmed == "", do: 0, else: hits(String.downcase(trimmed), keywords)

    if line_hits == 0 do
      []
    else
      definition = if Regex.match?(pattern, line), do: 2, else: 0

      [
        %{
          path: rel,
          line: number,
          text: clean(trimmed),
          score: line_hits * line_hits * 2 + definition + path_hits
        }
      ]
    end
  end

  defp definition_pattern do
    ~r/^\s*(?:pub(?:\([a-z]+\))?\s+)?(?:async\s+)?(?:defmodule|defp?|defmacrop?|defstruct|fn|fun|func|function|class|struct|enum|trait|impl|interface|type|module|object|const|export|public|private|static)\b/
  end

  defp hits(text, keywords), do: Enum.count(keywords, &String.contains?(text, &1))

  defp clean(text) do
    text
    |> String.replace(~r/[\x00-\x1f\x7f]/u, " ")
    |> String.slice(0, @max_line_chars)
  end

  defp stem(word) do
    cond do
      String.length(word) >= 5 and String.ends_with?(word, "ied") ->
        String.replace_suffix(word, "ied", "y")

      String.length(word) >= 5 and String.ends_with?(word, "ies") ->
        String.replace_suffix(word, "ies", "y")

      true ->
        strip_suffix(word)
    end
  end

  defp strip_suffix(word) do
    Enum.find_value(["ing", "ed", "es", "s"], word, fn suffix ->
      if String.ends_with?(word, suffix) and String.length(word) - String.length(suffix) >= 4,
        do: String.replace_suffix(word, suffix, "")
    end)
  end
end
