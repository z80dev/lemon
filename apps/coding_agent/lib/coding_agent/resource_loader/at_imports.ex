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

  Containment follows file ownership (`:root`). Home-owned global instruction
  files pass `:unconfined` and may import any regular file. Project and
  ancestor files pass their `LemonCore.TrustedRoot`: every import, nested
  ones included, must resolve (after symlinks) to a regular, single-linked
  file inside that root. A refused import stays literal and logs a warning
  naming the token, never the target's content.

  Each imported span is wrapped as `<!-- @import <realpath> -->…<!-- /@import -->`
  so the prompt records where the text came from.

  Imported content is bounded: each imported file contributes at most 64 KiB
  and one top-level file at most 256 KiB of imported content in total; beyond
  that, further tokens stay literal.
  """

  require Logger

  alias LemonCore.TrustedRoot

  @max_depth 5
  @max_import_bytes 65_536
  @max_total_import_bytes 262_144

  @import_regex ~r/(^|[ \t])@([.\/~A-Za-z0-9_-][^\s]*)/
  @trailing_punct ~r/[.,;:!?)\]}"']+$/

  @doc """
  Expand `@path` imports in `content`, which was read from `file_path`.

  Options:

    * `:home` - directory used for `~` imports (required)
    * `:root` - the importing file's trusted root, or `:unconfined` for a
      home-owned global instruction file (required)
  """
  @spec expand(String.t(), String.t(), keyword()) :: String.t()
  def expand(content, file_path, opts) when is_binary(content) do
    home = Keyword.fetch!(opts, :home)
    root = Keyword.fetch!(opts, :root)
    true = root == :unconfined or is_binary(root)

    source =
      case TrustedRoot.realpath(file_path) do
        {:ok, real} -> real
        {:error, _} -> Path.expand(file_path)
      end

    state = %{
      home: home,
      root: root,
      source: source,
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
      {lines, {state, _code_state}} =
        content
        |> String.split("\n")
        |> Enum.map_reduce({state, {nil, nil}}, fn line, {state, code_state} ->
          expand_markdown_line(line, code_state, base_dir, depth, state)
        end)

      {Enum.join(lines, "\n"), state}
    else
      {content, state}
    end
  end

  # Fenced code blocks are kept verbatim. A closing fence uses the opening
  # fence's character with at least as many marks.
  defp expand_markdown_line(line, {nil, inline}, base_dir, depth, state) do
    case match_fence(line) do
      nil ->
        next_inline = inline_state(line, byte_size(line), inline)
        {line, state} = expand_line(line, inline, base_dir, depth, state)
        {line, {state, {nil, next_inline}}}

      fence ->
        {line, {state, {fence, nil}}}
    end
  end

  defp expand_markdown_line(line, {{char, len} = fence, inline}, _base_dir, _depth, state) do
    case match_fence(line) do
      {^char, close_len} when close_len >= len -> {line, {state, {nil, nil}}}
      _ -> {line, {state, {fence, inline}}}
    end
  end

  defp match_fence(line) do
    case Regex.run(~r/^[ \t]*(`{3,}|~{3,})/, line, capture: :all_but_first) do
      [<<char, _::binary>> = marks] -> {char, byte_size(marks)}
      nil -> nil
    end
  end

  defp expand_line(line, inline, base_dir, depth, state) do
    if String.contains?(line, "@") do
      matches =
        @import_regex
        |> Regex.scan(line, return: :index)
        |> Enum.flat_map(fn [_whole, {lead_start, lead_len}, {token_start, token_len}] ->
          at_pos = lead_start + lead_len
          token = binary_part(line, token_start, token_len)
          trimmed = Regex.replace(@trailing_punct, token, "")

          cond do
            inline_state(line, at_pos, inline) != nil -> []
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

  # Only a backtick run of the opening delimiter's length closes a code span.
  # Carry the opening length across lines so multiline examples stay literal.
  defp inline_state(line, position, initial) do
    line
    |> binary_part(0, position)
    |> then(&Regex.scan(~r/`+/, &1))
    |> Enum.reduce(initial, fn [marks], opening ->
      len = byte_size(marks)

      cond do
        opening == nil -> len
        opening == len -> nil
        true -> opening
      end
    end)
  end

  defp resolve_and_expand(import_path, base_dir, depth, state) do
    resolved = resolve_path(import_path, base_dir, state.home)

    with {:ok, real} <- admit(import_path, resolved, state),
         false <- MapSet.member?(state.visited, real),
         true <- state.budget > 0,
         {:ok, content} <- read_import(real, state.root) do
      content = bound(content, min(@max_import_bytes, state.budget))
      state = %{state | visited: MapSet.put(state.visited, real)}
      state = %{state | budget: state.budget - byte_size(content)}
      {expanded, state} = expand_content(content, Path.dirname(real), depth + 1, state)
      {"<!-- @import #{real} -->" <> String.trim_trailing(expanded) <> "<!-- /@import -->", state}
    else
      _ -> {nil, state}
    end
  end

  defp resolve_path("~", _base_dir, home), do: Path.expand(home)
  defp resolve_path("~/" <> rest, _base_dir, home), do: Path.expand(rest, home)
  defp resolve_path(path, base_dir, _home), do: Path.expand(path, base_dir)

  # A missing target stays literal silently; an existing target outside the
  # trusted root (directly, through a symlink or as a hard link) is refused
  # and logged without its content.
  defp admit(import_path, resolved, state) do
    case TrustedRoot.realpath(resolved) do
      {:ok, real} when state.root == :unconfined ->
        {:ok, real}

      {:ok, _real} ->
        case TrustedRoot.file(resolved, state.root) do
          {:ok, real} ->
            {:ok, real}

          :error ->
            Logger.warning(
              "Refused @import #{import_path} in #{state.source}: target is outside the " <>
                "trusted root #{state.root}, not a regular file, or hard-linked"
            )

            :error
        end

      {:error, _} ->
        :error
    end
  end

  defp read_import(path, root) do
    with {:ok, content} <- read_target(path, root),
         true <- String.valid?(content) do
      {:ok, content}
    else
      _ -> :error
    end
  end

  defp read_target(path, :unconfined) do
    if File.regular?(path), do: File.read(path), else: :error
  end

  defp read_target(path, root) do
    case TrustedRoot.read(path, root) do
      {:ok, content, _real} -> {:ok, content}
      :error -> :error
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
