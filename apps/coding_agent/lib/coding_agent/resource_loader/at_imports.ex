defmodule CodingAgent.ResourceLoader.AtImports do
  @moduledoc """
  Expands `@path` imports inside instruction files (`AGENTS.md`, `CLAUDE.md`,
  `GEMINI.md`, ...), following the convention used by Claude Code and other
  coding agents:

  - `@` must start a line or follow a space or tab, so `user@example.com` and
    `git@github.com:org/repo` are never imports.
  - Relative paths resolve against the importing file's directory; `~` and
    `~/...` resolve against the home directory; absolute paths are used as-is.
  - Tokens inside fenced code blocks and inline code spans stay literal.
  - Trailing sentence punctuation (`. , ; : ! ? ) ] } " '`) is not part of the
    path, so `See @docs/setup.md.` imports `docs/setup.md`.
  - Imports recurse up to five hops. A file already pulled into the expansion
    tree is not imported again, so cycles stop silently.
  - A missing, unreadable, non-UTF-8 or non-regular target leaves the original
    `@token` text in place.

  Imported content is bounded: each imported file contributes at most 64 KiB
  and one top-level file at most 256 KiB of imported content in total; beyond
  that, further tokens stay literal.
  """

  @max_depth 5
  @max_import_bytes 65_536
  @max_total_import_bytes 262_144

  @import_regex ~r/(^|[ \t])@([.\/~A-Za-z0-9_-][^\s]*)/
  @trailing_punct ~r/[.,;:!?)\]}"']+$/

  @doc """
  Expand `@path` imports in `content`, which was read from `file_path`.

  Options:

    * `:home` - directory used for `~` imports (required)
  """
  @spec expand(String.t(), String.t(), keyword()) :: String.t()
  def expand(content, file_path, opts) when is_binary(content) do
    home = Keyword.fetch!(opts, :home)
    source = Path.expand(file_path)

    state = %{
      home: home,
      visited: MapSet.new([source]),
      budget: @max_total_import_bytes
    }

    {expanded, _state} = expand_content(content, Path.dirname(source), 0, state)
    expanded
  end

  defp expand_content(content, _base_dir, depth, state) when depth >= @max_depth,
    do: {content, state}

  defp expand_content(content, base_dir, depth, state) do
    if String.contains?(content, "@") do
      {lines, {state, _fence}} =
        content
        |> String.split("\n")
        |> Enum.map_reduce({state, nil}, fn line, {state, fence} ->
          expand_markdown_line(line, fence, base_dir, depth, state)
        end)

      {Enum.join(lines, "\n"), state}
    else
      {content, state}
    end
  end

  # Fenced code blocks are kept verbatim. A closing fence uses the opening
  # fence's character with at least as many marks.
  defp expand_markdown_line(line, nil, base_dir, depth, state) do
    case match_fence(line) do
      nil ->
        {line, state} = expand_line(line, base_dir, depth, state)
        {line, {state, nil}}

      fence ->
        {line, {state, fence}}
    end
  end

  defp expand_markdown_line(line, {char, len} = fence, _base_dir, _depth, state) do
    case match_fence(line) do
      {^char, close_len} when close_len >= len -> {line, {state, nil}}
      _ -> {line, {state, fence}}
    end
  end

  defp match_fence(line) do
    case Regex.run(~r/^[ \t]*(`{3,}|~{3,})/, line, capture: :all_but_first) do
      [<<char, _::binary>> = marks] -> {char, byte_size(marks)}
      nil -> nil
    end
  end

  defp expand_line(line, base_dir, depth, state) do
    if String.contains?(line, "@") do
      matches =
        @import_regex
        |> Regex.scan(line, return: :index)
        |> Enum.flat_map(fn [_whole, {lead_start, lead_len}, {token_start, token_len}] ->
          at_pos = lead_start + lead_len
          token = binary_part(line, token_start, token_len)
          trimmed = Regex.replace(@trailing_punct, token, "")

          cond do
            inside_inline_code?(line, at_pos) -> []
            trimmed == "" -> []
            true -> [{at_pos, at_pos + 1 + byte_size(trimmed), trimmed}]
          end
        end)

      splice(line, matches, 0, base_dir, depth, state, [])
    else
      {line, state}
    end
  end

  defp splice(line, [], cursor, _base_dir, _depth, state, acc) do
    rest = binary_part(line, cursor, byte_size(line) - cursor)
    {IO.iodata_to_binary(Enum.reverse([rest | acc])), state}
  end

  defp splice(line, [{start, stop, import_path} | rest], cursor, base_dir, depth, state, acc) do
    before = binary_part(line, cursor, start - cursor)

    {replacement, state} =
      case resolve_and_expand(import_path, base_dir, depth, state) do
        {nil, state} -> {binary_part(line, start, stop - start), state}
        {expanded, state} -> {expanded, state}
      end

    splice(line, rest, stop, base_dir, depth, state, [replacement, before | acc])
  end

  # Backtick-run parity scan: an odd number of runs before the `@` means the
  # token sits inside an inline code span.
  defp inside_inline_code?(line, position) do
    line
    |> binary_part(0, position)
    |> then(&Regex.scan(~r/`+/, &1))
    |> length()
    |> rem(2) == 1
  end

  defp resolve_and_expand(import_path, base_dir, depth, state) do
    resolved = resolve_path(import_path, base_dir, state.home)

    with false <- MapSet.member?(state.visited, resolved),
         true <- state.budget > 0,
         {:ok, content} <- read_import(resolved) do
      content = bound(content, min(@max_import_bytes, state.budget))
      state = %{state | visited: MapSet.put(state.visited, resolved)}
      state = %{state | budget: state.budget - byte_size(content)}
      {expanded, state} = expand_content(content, Path.dirname(resolved), depth + 1, state)
      {String.trim_trailing(expanded), state}
    else
      _ -> {nil, state}
    end
  end

  defp resolve_path("~", _base_dir, home), do: Path.expand(home)
  defp resolve_path("~/" <> rest, _base_dir, home), do: Path.expand(rest, home)
  defp resolve_path(path, base_dir, _home), do: Path.expand(path, base_dir)

  defp read_import(path) do
    with true <- File.regular?(path),
         {:ok, content} <- File.read(path),
         true <- String.valid?(content) do
      {:ok, content}
    else
      _ -> :error
    end
  end

  defp bound(content, limit) when byte_size(content) <= limit, do: content

  defp bound(content, limit) do
    content
    |> binary_part(0, limit)
    |> valid_prefix()
    |> Kernel.<>("\n[... imported file truncated at #{limit} bytes]")
  end

  defp valid_prefix(binary) do
    if String.valid?(binary),
      do: binary,
      else: valid_prefix(binary_part(binary, 0, byte_size(binary) - 1))
  end
end
