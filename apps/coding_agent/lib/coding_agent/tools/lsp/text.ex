defmodule CodingAgent.Tools.Lsp.Text do
  @moduledoc """
  Text helpers for the `lsp` tool: file URIs, UTF-16 position mapping, symbol
  column lookup and in-memory `TextEdit` application.

  LSP positions are zero-based lines and UTF-16 code-unit offsets (the default
  `positionEncoding`, the only one the tool advertises). Files are UTF-8 on
  disk, so every conversion between a position and a byte offset walks the
  line's code points. Lines end at `\\n`; a preceding `\\r` belongs to the line
  terminator, never to the line's text.
  """

  @bare_identifier ~r/^[$A-Za-z_][\w$]*$/

  @doc "Convert an absolute path to a `file://` URI."
  @spec path_to_uri(String.t()) :: String.t()
  def path_to_uri(path) do
    "file://" <> URI.encode(Path.expand(path), &(URI.char_unreserved?(&1) or &1 == ?/))
  end

  @doc "Convert a `file://` URI to an absolute path; other schemes return `:error`."
  @spec uri_to_path(String.t()) :: {:ok, String.t()} | :error
  def uri_to_path("file://" <> rest) do
    path =
      case rest do
        "localhost/" <> tail -> "/" <> tail
        _ -> rest
      end

    {:ok, URI.decode(path)}
  end

  def uri_to_path(_uri), do: :error

  @doc """
  Display `path` relative to `cwd` when it lies inside it (also through the
  cwd's resolved real path, since servers often report canonical paths such
  as `/private/var/...` for `/var/...`), else as an absolute path.
  """
  @spec display_path(String.t(), String.t()) :: String.t()
  def display_path(path, cwd) do
    path = Path.expand(path)

    Enum.find_value([Path.expand(cwd), realpath(cwd)], path, fn base ->
      cond do
        path == base -> "."
        String.starts_with?(path, base <> "/") -> Path.relative_to(path, base)
        true -> nil
      end
    end)
  end

  @doc "Resolve symlinks in every component of an absolute path (best effort)."
  @spec realpath(String.t()) :: String.t()
  def realpath(path), do: path |> Path.expand() |> resolve_links(0) |> elem(0)

  # `hops` counts symlinks followed across the whole resolution, so cycles end.
  defp resolve_links(path, hops) do
    path
    |> Path.split()
    |> Enum.reduce({"/", hops}, fn
      "/", acc ->
        acc

      part, {current, hops} ->
        candidate = Path.join(current, part)

        case File.read_link(candidate) do
          {:ok, target} when hops < 32 ->
            target |> Path.expand(Path.dirname(candidate)) |> resolve_links(hops + 1)

          _ ->
            {candidate, hops}
        end
    end)
  end

  @doc "Split content into line texts without terminators."
  @spec lines(String.t()) :: [String.t()]
  def lines(content) do
    content
    |> String.split("\n")
    |> Enum.map(&strip_cr/1)
  end

  @doc "Return the zero-based line's text, or `:error` past the end of the content."
  @spec line_at(String.t(), non_neg_integer()) :: {:ok, String.t()} | :error
  def line_at(content, line) when is_integer(line) and line >= 0 do
    case Enum.at(String.split(content, "\n"), line) do
      nil -> :error
      text -> {:ok, strip_cr(text)}
    end
  end

  def line_at(_content, _line), do: :error

  @doc "Number of UTF-16 code units in `text`."
  @spec utf16_length(binary()) :: non_neg_integer()
  def utf16_length(text), do: utf16_length(text, 0)

  defp utf16_length(<<cp::utf8, rest::binary>>, acc), do: utf16_length(rest, acc + units(cp))
  defp utf16_length(<<_byte, rest::binary>>, acc), do: utf16_length(rest, acc + 1)
  defp utf16_length(<<>>, acc), do: acc

  @doc """
  Byte offset inside `line_text` for a UTF-16 `character` offset.

  Offsets past the end of the line clamp to the line end, as the protocol
  requires; an offset inside a surrogate pair resolves to the pair's start.
  """
  @spec utf16_to_byte(binary(), non_neg_integer()) :: non_neg_integer()
  def utf16_to_byte(line_text, character), do: utf16_to_byte(line_text, character, 0, 0)

  defp utf16_to_byte(_rest, character, units, bytes) when units >= character, do: bytes

  defp utf16_to_byte(<<cp::utf8, rest::binary>> = text, character, units, bytes) do
    next = units + units(cp)

    if next > character,
      do: bytes,
      else: utf16_to_byte(rest, character, next, bytes + byte_size(text) - byte_size(rest))
  end

  defp utf16_to_byte(<<_byte, rest::binary>>, character, units, bytes),
    do: utf16_to_byte(rest, character, units + 1, bytes + 1)

  defp utf16_to_byte(<<>>, _character, _units, bytes), do: bytes

  @doc "1-based code-point column for a UTF-16 `character` offset in `line_text`."
  @spec display_column(binary(), non_neg_integer()) :: pos_integer()
  def display_column(line_text, character) do
    prefix = binary_part(line_text, 0, utf16_to_byte(line_text, character))
    length(String.codepoints(prefix)) + 1
  end

  @doc "UTF-16 offset of the first `count` code points of `line_text` (clamped)."
  @spec codepoints_to_utf16(binary(), non_neg_integer()) :: non_neg_integer()
  def codepoints_to_utf16(line_text, count) do
    line_text
    |> String.codepoints()
    |> Enum.take(count)
    |> Enum.join()
    |> utf16_length()
  end

  @doc """
  Resolve the UTF-16 character for a request position on 1-based `line`.

  `symbol` locates text on that line (`name#N` selects the Nth occurrence; a
  bare identifier only matches at word boundaries; an exact match is preferred
  over a case-insensitive one). Without a symbol, a 1-based code-point
  `column` is used, and without either the first non-whitespace character.
  """
  @spec resolve_character(String.t(), pos_integer(), String.t() | nil, pos_integer() | nil) ::
          {:ok, non_neg_integer()} | {:error, String.t()}
  def resolve_character(content, line, symbol, column) do
    case line_at(content, line - 1) do
      :error ->
        {:error, "Line #{line} is past the end of the file (#{length(lines(content))} lines)"}

      {:ok, text} ->
        cond do
          is_binary(symbol) and symbol != "" -> symbol_character(text, line, symbol)
          is_integer(column) -> {:ok, codepoints_to_utf16(text, column - 1)}
          true -> {:ok, first_non_whitespace(text)}
        end
    end
  end

  defp symbol_character(text, line, spec) do
    {symbol, occurrence} = parse_symbol_spec(spec)

    indexes =
      case match_indexes(text, symbol, false) do
        [] -> match_indexes(text, symbol, true)
        exact -> exact
      end

    cond do
      indexes == [] ->
        {:error, "Symbol #{inspect(symbol)} not found on line #{line}"}

      occurrence > length(indexes) ->
        {:error,
         "Symbol #{inspect(symbol)} occurrence #{occurrence} is out of bounds on line #{line} (found #{length(indexes)})"}

      true ->
        byte_index = Enum.at(indexes, occurrence - 1)
        {:ok, utf16_length(binary_part(text, 0, byte_index))}
    end
  end

  defp parse_symbol_spec(spec) do
    case Regex.run(~r/^(.+)#(\d+)$/s, spec) do
      [_, symbol, n] -> {symbol, max(String.to_integer(n), 1)}
      _ -> {spec, 1}
    end
  end

  defp match_indexes(text, symbol, case_insensitive?) do
    {haystack, needle} =
      if case_insensitive?,
        do: {String.downcase(text), String.downcase(symbol)},
        else: {text, symbol}

    word? = Regex.match?(@bare_identifier, symbol)

    # Downcasing can change byte lengths for non-ASCII text; only trust
    # case-insensitive indexes when the byte layout is preserved.
    if byte_size(haystack) != byte_size(text) or needle == "" do
      []
    else
      haystack
      |> :binary.matches(needle)
      |> Enum.map(fn {index, _length} -> index end)
      |> Enum.filter(fn index -> not word? or word_boundary?(text, index, byte_size(needle)) end)
    end
  end

  defp word_boundary?(text, index, length) do
    before = if index > 0, do: :binary.at(text, index - 1)
    after_index = index + length
    after_char = if after_index < byte_size(text), do: :binary.at(text, after_index)
    not identifier_byte?(before) and not identifier_byte?(after_char)
  end

  defp identifier_byte?(nil), do: false

  defp identifier_byte?(byte),
    do: byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in [?_, ?$]

  defp first_non_whitespace(text) do
    case Regex.run(~r/^\s*/u, text) do
      [leading] -> utf16_length(leading)
      _ -> 0
    end
  end

  @doc """
  Apply LSP `TextEdit`s to `content`.

  Edits are validated as a set before any is applied: every range must be
  well formed, ranges may touch but not overlap, byte-identical duplicates
  collapse, and inserts at the same position keep their array order.
  Snippet-format edits are rejected.
  """
  @spec apply_edits(String.t(), [map()]) :: {:ok, String.t()} | {:error, String.t()}
  def apply_edits(content, edits) when is_list(edits) do
    line_starts = line_starts(content)

    with {:ok, spans} <- to_spans(content, line_starts, edits),
         {:ok, spans} <- order_spans(spans) do
      {iodata, cursor} =
        Enum.reduce(spans, {[], 0}, fn {start, stop, text, _index}, {acc, cursor} ->
          {[acc, binary_part(content, cursor, start - cursor), text], stop}
        end)

      {:ok,
       IO.iodata_to_binary([iodata, binary_part(content, cursor, byte_size(content) - cursor)])}
    end
  end

  defp to_spans(content, line_starts, edits) do
    edits
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {edit, index}, {:ok, acc} ->
      case to_span(content, line_starts, edit, index) do
        {:ok, span} -> {:cont, {:ok, [span | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp to_span(_content, _starts, %{"insertTextFormat" => 2}, _index),
    do: {:error, "snippet-formatted LSP edits are unsupported"}

  defp to_span(content, starts, %{"range" => range, "newText" => text}, index)
       when is_binary(text) do
    with {:ok, start} <- offset(content, starts, range["start"]),
         {:ok, stop} <- offset(content, starts, range["end"]) do
      if stop < start,
        do: {:error, "LSP edit range ends before it starts: #{format_range(range)}"},
        else: {:ok, {start, stop, text, index}}
    end
  end

  defp to_span(_content, _starts, edit, _index),
    do: {:error, "Malformed LSP text edit: #{inspect(edit, limit: 5)}"}

  defp offset(content, starts, %{"line" => line, "character" => character})
       when is_integer(line) and line >= 0 and is_integer(character) and character >= 0 do
    if line >= tuple_size(starts) do
      {:ok, byte_size(content)}
    else
      start = elem(starts, line)

      line_end =
        if line + 1 < tuple_size(starts), do: elem(starts, line + 1) - 1, else: byte_size(content)

      text = content |> binary_part(start, line_end - start) |> strip_cr()
      {:ok, start + utf16_to_byte(text, character)}
    end
  end

  defp offset(_content, _starts, position),
    do: {:error, "Malformed LSP position: #{inspect(position)}"}

  defp order_spans(spans) do
    sorted =
      spans
      |> Enum.sort_by(fn {start, _stop, _text, index} -> {start, index} end)
      |> Enum.dedup_by(fn {start, stop, text, _index} ->
        if start == stop, do: make_ref(), else: {start, stop, text}
      end)

    sorted
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [{_s1, stop1, _t1, _i1}, {start2, _s2, _t2, _i2}] -> stop1 > start2 end)
    |> case do
      nil ->
        {:ok, sorted}

      _overlap ->
        {:error, "overlapping LSP edits; the language server produced inconsistent edits"}
    end
  end

  defp line_starts(content) do
    content
    |> :binary.matches("\n")
    |> Enum.map(fn {index, 1} -> index + 1 end)
    |> then(&List.to_tuple([0 | &1]))
  end

  defp format_range(%{"start" => s, "end" => e}),
    do: "#{s["line"] + 1}:#{s["character"] + 1}-#{e["line"] + 1}:#{e["character"] + 1}"

  defp format_range(range), do: inspect(range)

  defp strip_cr(text) do
    if String.ends_with?(text, "\r"), do: binary_part(text, 0, byte_size(text) - 1), else: text
  end

  defp units(cp) when cp > 0xFFFF, do: 2
  defp units(_cp), do: 1
end
