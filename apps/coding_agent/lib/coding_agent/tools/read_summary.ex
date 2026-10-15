defmodule CodingAgent.Tools.ReadSummary do
  @moduledoc false

  # This is deliberately a conservative outline, not a parser or an edit snapshot.
  # Keep declarations and shallow/top-level code; never infer omitted bodies.
  alias CodingAgent.Tools.AnchoredEdit
  alias LemonAgent.Tools.AbortHelpers

  @max_bytes 2 * 1024 * 1024
  @min_lines 300
  @extensions ~w(.ex .exs .py .js .jsx .ts .tsx .mjs .cjs .rs .go .c .h .cc .cpp .hpp .java .kt .kts .swift .rb .php .cs .scala .sh .bash .zsh .erl .hrl .clj .cljs .lua .r .jl .dart)
  @declaration ~r/^(?:(?:export|default|declare|abstract|public|private|protected|internal|static|final|override|open|unsafe|async|pub(?:\([^)]*\))?|virtual|sealed|partial|inline|constexpr|extern)\s+)*(?:def(?:module|p|macro|macrop|protocol|impl|struct|exception|delegate|guard|guardp)?|class|function\*?|fn|func|impl|struct|enum|trait|interface|type(?:alias)?|module|namespace|record|protocol|extension|actor|object|package|import|from|using|use|require|include|alias)\b/
  @method ~r/^(?!(?:if|for|while|switch|catch|return|throw|else|when|case)\b)(?:[\w:<>,?*\[\]&.]+\s+)*[\w!?]+\s*\([^;]*\)\s*(?::[^=]+)?(?:\{|do\b|=>)/

  def read(path, stat, signal, opts) do
    if eligible?(path, stat.size) do
      with :ok <- AbortHelpers.check_abort(signal),
           {:ok, content} <- File.open(path, [:read, :binary], &IO.binread(&1, @max_bytes + 1)),
           :ok <- AbortHelpers.check_abort(signal) do
        if is_binary(content), do: from_content(path, content, opts), else: :not_applicable
      else
        {:error, "Operation aborted"} = error -> error
        {:error, reason} -> {:error, "Failed to read file: #{path} (#{reason})"}
      end
    else
      :not_applicable
    end
  end

  def from_content(path, content, opts) do
    if eligible?(path, byte_size(content)) and String.valid?(content) and
         not String.contains?(content, <<0>>) do
      lines =
        content
        |> String.trim_leading("\uFEFF")
        |> String.replace("\r\n", "\n")
        |> AnchoredEdit.lines()

      if length(lines) >= @min_lines do
        build(path, content, lines, opts)
      else
        :not_applicable
      end
    else
      :not_applicable
    end
  end

  defp eligible?(path, size),
    do: size <= @max_bytes and String.downcase(Path.extname(path)) in @extensions

  defp build(path, content, lines, opts) do
    total = length(lines)
    header = "[Structural summary; partial immutable view of #{path} (#{total} lines)]"

    guidance =
      "Re-read needed bodies with #{path}:a-b selectors (ranges below), or use #{path}:raw / offset=1 for full text. summary: false disables outlining."

    budget =
      Keyword.get(opts, :max_bytes, 50 * 1024) - byte_size(header) - byte_size(guidance) -
        byte_size(path) - 300

    line_budget = max(div(Keyword.get(opts, :max_lines, 2000) - 4, 2), 0)

    if budget > 0 and line_budget > 0 do
      kept =
        lines
        |> declarations(path)
        |> Enum.reduce_while({[], budget, line_budget}, fn {number, line},
                                                           {kept, bytes, remaining} ->
          cost = byte_size(line) + byte_size(Integer.to_string(number)) + 50

          if cost <= bytes and remaining > 0,
            do: {:cont, {[{number, line} | kept], bytes - cost, remaining - 1}},
            else: {:halt, {kept, bytes, remaining}}
        end)
        |> elem(0)
        |> Enum.reverse()

      {body, ranges} = render(kept, 1, total, [], [])

      if ranges == [] do
        :not_applicable
      else
        examples = ranges |> Enum.take(5) |> Enum.map_join(",", fn {a, b} -> "#{a}-#{b}" end)

        footer =
          "[Structural summary; bodies omitted. #{guidance} Examples: #{path}:#{examples}.]"

        {:ok,
         %{
           text: header <> "\n" <> Enum.join(body, "\n") <> "\n\n" <> footer,
           total_lines: total,
           lines_shown: length(kept),
           elided_ranges: ranges,
           digest: :erlang.md5(content)
         }}
      end
    else
      :not_applicable
    end
  end

  defp declarations(lines, path) do
    hash_comments? = Path.extname(path) not in ~w(.c .h .cc .cpp .hpp .cs)

    {kept, _} =
      lines
      |> Enum.with_index(1)
      |> Enum.reduce({[], %{mode: :code, braces: 0, parens: 0, header: false}}, fn {line, number},
                                                                                   {kept, state} ->
        {code, mode} = lex(line, state.mode, hash_comments?, [])
        text = String.trim(code)
        indent = byte_size(line) - byte_size(String.trim_leading(line))
        braces = max(0, state.braces + count(code, "{") - count(code, "}"))
        parens = max(0, state.parens + count(code, "(") - count(code, ")"))
        declaration? = Regex.match?(@declaration, text) or String.starts_with?(text, "@")
        shallow_method? = state.braces <= 1 and indent <= 4 and Regex.match?(@method, text)
        top_level? = indent == 0 and (state.braces == 0 or braces == 0)
        continuation? = state.header and state.parens > 0

        keep? =
          state.mode == :code and String.trim(line) != "" and
            (declaration? or shallow_method? or top_level? or continuation?)

        # A continued signature may contain a multiline string default value.
        keep? = keep? or (continuation? and text != "")
        header? = (declaration? or shallow_method? or continuation? or top_level?) and parens > 0
        mode = if mode in ["'", "\""], do: :code, else: mode
        next = %{mode: mode, braces: braces, parens: parens, header: header?}
        {if(keep?, do: [{number, line} | kept], else: kept), next}
      end)

    Enum.reverse(kept)
  end

  defp count(text, token), do: length(:binary.matches(text, token))

  defp render([], cursor, total, body, ranges) do
    {body, ranges} = elide(cursor, total, body, ranges)
    {Enum.reverse(body), Enum.reverse(ranges)}
  end

  defp render([{number, line} | rest], cursor, total, body, ranges) do
    {body, ranges} = elide(cursor, number - 1, body, ranges)
    render(rest, number + 1, total, ["#{number}: #{line}" | body], ranges)
  end

  defp elide(first, last, body, ranges) when first <= last,
    do: {["… [lines #{first}-#{last} elided]" | body], [{first, last} | ranges]}

  defp elide(_, _, body, ranges), do: {body, ranges}

  # Strip strings and comments only for structural decisions, retaining their
  # state across lines. In particular, declarations inside docstrings are not code.
  defp lex("", mode, _, acc), do: {acc |> Enum.reverse() |> IO.iodata_to_binary(), mode}
  defp lex(<<"*/", rest::binary>>, :comment, hash?, acc), do: lex(rest, :code, hash?, acc)
  defp lex(<<_, rest::binary>>, :comment, hash?, acc), do: lex(rest, :comment, hash?, acc)

  defp lex(<<"\\", _, rest::binary>>, mode, hash?, acc) when is_binary(mode),
    do: lex(rest, mode, hash?, acc)

  defp lex(text, mode, hash?, acc) when is_binary(mode) do
    if String.starts_with?(text, mode) do
      lex(
        binary_part(text, byte_size(mode), byte_size(text) - byte_size(mode)),
        :code,
        hash?,
        acc
      )
    else
      <<_, rest::binary>> = text
      lex(rest, mode, hash?, acc)
    end
  end

  defp lex(<<"/*", rest::binary>>, :code, hash?, acc), do: lex(rest, :comment, hash?, [" " | acc])
  defp lex(<<"//", _::binary>>, :code, _, acc), do: lex("", :code, false, acc)
  defp lex(<<"#", _::binary>>, :code, true, acc), do: lex("", :code, true, acc)

  defp lex(<<"\"\"\"", rest::binary>>, :code, hash?, acc),
    do: lex(rest, "\"\"\"", hash?, [" " | acc])

  defp lex(<<"'''", rest::binary>>, :code, hash?, acc), do: lex(rest, "'''", hash?, [" " | acc])

  defp lex(<<quote, rest::binary>>, :code, hash?, acc) when quote in [?", ?', ?`],
    do: lex(rest, <<quote>>, hash?, [" " | acc])

  defp lex(<<char, rest::binary>>, :code, hash?, acc),
    do: lex(rest, :code, hash?, [<<char>> | acc])
end
