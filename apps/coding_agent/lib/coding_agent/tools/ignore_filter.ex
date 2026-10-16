defmodule CodingAgent.Tools.IgnoreFilter do
  @moduledoc """
  `.gitignore`/`.ignore` filtering for the Elixir fallbacks of `find` and
  `grep`, matching what `fd`/`rg` skip by default.

  Git supplies repository/global `.gitignore` semantics through `check-ignore`.
  When Git is unavailable or the search root is itself ignored, local
  `.gitignore` files under that root are evaluated instead. Hierarchical
  `.ignore` files are evaluated independently, including outside a repository,
  and take precedence over all `.gitignore` rules.
  """

  # Keep Git requests bounded; stdin and stdout both use NUL-delimited paths.
  @check_ignore_chunk 200

  @doc "Drops ignored paths, using local rules when Git cannot classify the search root."
  @spec reject_ignored([String.t()], String.t()) :: [String.t()]
  def reject_ignored([], _search_dir), do: []

  def reject_ignored(paths, search_dir) do
    {ignored, git_fallback?} =
      case git_ignored(paths, search_dir) do
        {:ok, ignored} -> {ignored, false}
        :unavailable -> {MapSet.new(), true}
      end

    directories =
      Enum.reduce(paths, MapSet.new(), fn path, dirs ->
        Enum.reduce(parents(path), dirs, &MapSet.put(&2, &1))
      end)

    rules = Map.new(directories, &{&1, read_rules(&1, ".ignore")})

    git_rules =
      if git_fallback? do
        directories
        |> Enum.filter(&(&1 == search_dir or String.starts_with?(&1, search_dir <> "/")))
        |> Map.new(&{&1, read_rules(&1, ".gitignore")})
      else
        %{}
      end

    Enum.reject(paths, fn path ->
      ancestors = path |> parents() |> Enum.reverse()

      own_rules =
        Enum.flat_map(ancestors, &Map.get(git_rules, &1, [])) ++
          Enum.flat_map(ancestors, &Map.get(rules, &1, []))

      ignored? =
        ignored_by_rules?(path, File.dir?(path), own_rules, MapSet.member?(ignored, path))

      blocked_parent? =
        path
        |> parents()
        |> Enum.take_while(&(&1 != search_dir))
        |> Enum.any?(&ignored_by_rules?(&1, true, own_rules, false))

      ignored? or blocked_parent?
    end)
  end

  defp parents(path), do: parents(Path.dirname(path), [])

  defp parents(path, acc) do
    parent = Path.dirname(path)
    if parent == path, do: Enum.reverse([path | acc]), else: parents(parent, [path | acc])
  end

  defp read_rules(dir, filename) do
    case File.read(Path.join(dir, filename)) do
      {:ok, text} ->
        if String.valid?(text),
          do: text |> String.split("\n") |> Enum.flat_map(&compile_rule(&1, dir)),
          else: []

      _ ->
        []
    end
  end

  defp compile_rule(line, dir) do
    line = line |> String.trim_trailing("\r") |> String.replace(~r/(?<!\\) +$/, "")

    cond do
      line == "" or String.starts_with?(line, "#") ->
        []

      true ->
        include? = String.starts_with?(line, "!")
        pattern = if include?, do: binary_part(line, 1, byte_size(line) - 1), else: line
        directory? = String.ends_with?(pattern, "/")

        anchored? =
          String.starts_with?(pattern, "/") or
            String.contains?(String.trim_trailing(pattern, "/"), "/")

        pattern = pattern |> String.trim_leading("/") |> String.trim_trailing("/")
        prefix = if anchored?, do: "^", else: "(?:^|/)"

        case if(pattern == "",
               do: {:error, :empty},
               else: Regex.compile(prefix <> glob(pattern) <> "(?:/.*)?\\z", "s")
             ) do
          {:ok, regex} -> [%{dir: dir, regex: regex, include: include?, directory: directory?}]
          _ -> []
        end
    end
  end

  defp glob(""), do: ""
  defp glob("**/" <> rest), do: "(?:.*/)?" <> glob(rest)
  defp glob("**" <> rest), do: ".*" <> glob(rest)
  defp glob("*" <> rest), do: "[^/]*" <> glob(rest)
  defp glob("?" <> rest), do: "[^/]" <> glob(rest)
  defp glob(<<92, char::utf8, rest::binary>>), do: Regex.escape(<<char::utf8>>) <> glob(rest)

  defp glob("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [class, rest] when class != "" ->
        class =
          if String.starts_with?(class, "!"),
            do: "^" <> String.slice(class, 1..-1//1),
            else: class

        "[" <> class <> "]" <> glob(rest)

      _ ->
        "\\[" <> glob(rest)
    end
  end

  defp glob(<<char::utf8, rest::binary>>), do: Regex.escape(<<char::utf8>>) <> glob(rest)

  defp ignored_by_rules?(path, directory?, rules, initial) do
    Enum.reduce(rules, initial, fn rule, ignored ->
      if String.starts_with?(path, rule.dir <> "/") and (directory? or not rule.directory) and
           Regex.match?(rule.regex, Path.relative_to(path, rule.dir)),
         do: not rule.include,
         else: ignored
    end)
  end

  defp git_ignored(paths, search_dir) do
    with git when is_binary(git) <- System.find_executable("git"),
         {:ok, root_ignored} <- check_ignore(git, search_dir, [search_dir]),
         true <- MapSet.size(root_ignored) == 0 do
      paths
      |> Enum.chunk_every(@check_ignore_chunk)
      |> Enum.reduce_while({:ok, MapSet.new()}, fn chunk, {:ok, acc} ->
        case check_ignore(git, search_dir, chunk) do
          {:ok, ignored} -> {:cont, {:ok, MapSet.union(acc, ignored)}}
          :unavailable -> {:halt, :unavailable}
        end
      end)
    else
      _ -> :unavailable
    end
  end

  defp check_ignore(git, search_dir, paths) do
    # Git accepts -z only with --stdin. Verbose non-matches produce exactly
    # four NUL-delimited fields per input, so we can read the complete batch
    # before closing stdin. GIT_FLUSH avoids waiting on Git's output buffer.
    args = [
      "-C",
      search_dir,
      "check-ignore",
      "--no-index",
      "--stdin",
      "-z",
      "--verbose",
      "--non-matching"
    ]

    port =
      LemonCore.NativeProcess.open({:spawn_executable, git}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        env: [{~c"GIT_FLUSH", ~c"1"}]
      ])

    try do
      true = Port.command(port, Enum.map(paths, &[&1, 0]))
      collect_check_ignore(port, length(paths) * 4, [])
    after
      if Port.info(port), do: Port.close(port)
    end
  rescue
    _ -> :unavailable
  end

  defp collect_check_ignore(port, remaining, chunks) do
    receive do
      {^port, {:data, data}} ->
        remaining = remaining - length(:binary.matches(data, <<0>>))
        chunks = [data | chunks]

        if remaining == 0 do
          ignored =
            chunks
            |> Enum.reverse()
            |> IO.iodata_to_binary()
            |> String.split(<<0>>)
            |> Enum.chunk_every(4, 4, :discard)
            |> Enum.reduce(MapSet.new(), fn [_source, _line, pattern, path], ignored ->
              if pattern == "" or String.starts_with?(pattern, "!"),
                do: ignored,
                else: MapSet.put(ignored, path)
            end)

          {:ok, ignored}
        else
          collect_check_ignore(port, remaining, chunks)
        end

      {^port, {:exit_status, _status}} ->
        :unavailable
    after
      5_000 -> :unavailable
    end
  end
end
