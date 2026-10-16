defmodule LemonCore.Redact do
  @moduledoc """
  Shared credential redaction for text and nested data.

  `text/1` removes credential assignments, authorization values, common provider
  keys, JWTs, and PEM private keys (including an unfinished PEM block). `map/1`
  additionally masks values under sensitive atom/string keys, traversing maps,
  structs, lists, keyword lists, and tuples. Structs become plain maps; other
  scalar values and map keys are preserved. Repeated redaction is idempotent.

  This is a credential filter, not an export policy or a guarantee that arbitrary
  text is public. Callers must retain their content allowlists, URL/path omission,
  depth/item/byte bounds, and fixed runtime-error summaries. In particular, apply
  redaction before truncating text, not after cutting a credential in half.

  ## Tokenizer pass

  The regex pass runs first on the original input, exactly as without the
  tokenizer, and records which spans it replaced. A tokenizer then handles
  shapes the regexes miss: percent-encoded keys and delimiters (`%74oken=…`,
  `token%3D…`, double-encoded `%2574oken`), assignments nested behind a
  non-sensitive wrapper (`message%20text="api_key=first second"`), and
  shell-quoted `&`-joined assignments (`'PASSWORD=first&mode=last'`).

  The tokenizer computes two interval sets: wrapped-value intervals on the
  original input (unquoted sensitive values inside a closed quoted wrapper, up
  to the wrapper's closing quote, because the regex pass ends such values at
  whitespace and in `:drop_keys` mode removes the wrapper's opening quote), and
  ordinary intervals on the regex output. Wrapped intervals are mapped through
  each recorded regex replacement (a position inside a replaced span maps to the
  whole replacement), unioned with the ordinary intervals, and applied once.
  Nothing rewrites the input before the regex pass, so every regex replacement
  survives and the result is never less redacted than the regex pass alone.

  The text is scanned as a raw byte view plus up to three percent-decoded views;
  every decoded byte remembers its original byte span, so each view is checked
  independently and keys like `%access_key` (whose `%ac` is also a hex escape)
  still match in the raw view. Every `=`/`:` delimiter yields at most one
  interval; intervals from all views are unioned rather than skipped past a
  previous replacement, so overlapping or nested matches cannot leak.

  Complexity is linear in the input length. Each view is built in one pass.
  Next-quote and next-terminator positions are precomputed right to left, so a
  value's end is found in O(1). A key is scanned backwards only to the previous
  delimiter, so key scans partition the view. Per delimiter, the remaining work
  is O(1): the already-redacted check compares at most a constant number of
  bytes (longer values are never treated as markers), even though value spans
  of successive delimiters may overlap (`token=token=…secret`). Per-view
  interval lists are sorted by start, so the union is a linear merge of at most
  four lists. Mapping intervals through a regex replacement is a single
  forward walk over the sorted interval endpoints and replaced spans, done
  once per regex (a constant number). Applying disjoint intervals copies each
  byte at most once.
  """

  @marker "[REDACTED]"
  @key_pattern "(?:pairing[_-]?codes?|access[_-]?key|api[_-]?key|auth(?:orization|[_-]?token)|bearer|cookie|credential|master[_-]?key|oauth|passw(?:or)?d|private[_-]?key|secret|token|wallet[_-]?key)"
  @sensitive_key Regex.compile!(@key_pattern, "i")
  @private_key ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)/s
  @credentials ~r/(?:sk-[A-Za-z0-9_-]{8,}|(?i:(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{8,}|xox[a-z]-[A-Za-z0-9-]{8,})|AKIA[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{35}|\beyJ(?:[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|[A-Za-z0-9+\/_-]{30,}(?:\.[A-Za-z0-9+\/_-]+)*=*))/
  @authorization ~r/\bbearer\s+[A-Za-z0-9._~+\/=:-]+/i
  @assignment ~r/((?<![\w.-])["']?[A-Za-z0-9_.-]*(?:#{@key_pattern}|session|private)[A-Za-z0-9_.-]*["']?[ \t]*[:=][ \t]*)(basic[ \t]+[A-Za-z0-9._~+\/=:-]+|""".*?(?:"""|\z)|'''.*?(?:'''|\z)|"(?:\\.|[^"\\])*(?:"|\z)|'(?:\\.|[^'\\])*(?:'|\z)|\[REDACTED\]|[^\s,;"'{}\[\]]+)/is
  @config_assignment ~r/^([ \t]*[^#\n=\[]*?=[ \t]*)([^\n]+)$/m
  @pairing_code ~r/((?:pairing code:\s*|lemon pairing (?:approve|deny) (?:telegram|discord)\s+))[A-HJ-NP-Z2-9]{8}\b/i
  @hex_key ~r/0x[a-fA-F0-9]{64}/

  @doc "Redact credentials in a string, leaving non-string values unchanged."
  @spec text(term()) :: term()
  def text(value), do: text(value, [])

  @doc """
  Redact text with options for existing export contracts.

    * `:count` returns `{text, replacement_count}` instead of text.
    * `:drop_keys` removes entire credential assignments, including their names
      (durable memory must not disclose secret names).
    * `:strict` also removes complete sensitive config assignment lines, session
      and private config fields, and unlabelled 256-bit hex values. This is for
      portable profile/config exports, not ordinary diagnostic text.

  `tokenizer: false` (internal, for legacy-comparison tests) skips the tokenizer
  pass described in the module documentation.

  Counts measure replacements that changed the input, so already-redacted text
  contributes zero. These options do not impose output size limits.
  """
  @spec text(term(), keyword()) :: term() | {term(), non_neg_integer()}
  def text(value, opts) when is_binary(value) do
    drop_keys? = Keyword.get(opts, :drop_keys, false)
    strict? = Keyword.get(opts, :strict, false)

    tokenizer? = Keyword.get(opts, :tokenizer, true)

    {legacy, count, passes} =
      {value, 0, []}
      |> replace(@private_key, fn _ -> @marker end)
      |> replace(@authorization, fn _ -> @marker end)
      |> replace(@assignment, fn [original, prefix, secret] ->
        if sensitive_key?(prefix) or (strict? and strict_key?(prefix)) do
          cond do
            drop_keys? -> @marker
            redacted?(secret) -> original
            true -> prefix <> @marker
          end
        else
          original
        end
      end)
      |> replace(@credentials, fn _ -> @marker end)
      |> replace(@pairing_code, fn [_original, prefix] -> prefix <> @marker end)
      |> strict(strict?, drop_keys?)

    result = tokenize(value, legacy, count, passes, tokenizer?, strict?, drop_keys?)

    if Keyword.get(opts, :count, false), do: result, else: elem(result, 0)
  end

  def text(value, opts) do
    if Keyword.get(opts, :count, false), do: {value, 0}, else: value
  end

  @doc "Recursively redact credentials, converting structs to plain maps."
  @spec map(term()) :: term()
  def map(%{__struct__: _} = value), do: value |> Map.from_struct() |> map()

  def map(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, redact_field(key, nested)} end)
  end

  def map(value) when is_list(value), do: Enum.map(value, &map/1)
  def map({key, value}) when is_atom(key) or is_binary(key), do: {key, redact_field(key, value)}
  def map(value) when is_tuple(value), do: value |> Tuple.to_list() |> map() |> List.to_tuple()
  def map(value), do: text(value)

  @doc "Whether an atom or string key identifies credentials (case-insensitive)."
  @spec sensitive_key?(term()) :: boolean()
  def sensitive_key?(key) when is_atom(key), do: sensitive_key?(Atom.to_string(key))
  def sensitive_key?(key) when key in ["mcp_servers_json", "mcp_servers", "mcpServers"], do: true
  def sensitive_key?(key) when is_binary(key), do: Regex.match?(@sensitive_key, key)
  def sensitive_key?(_), do: false

  defp redact_field(key, value) do
    if sensitive_key?(key) and not is_nil(value), do: @marker, else: map(value)
  end

  defp redacted?(value), do: String.trim(value, "\"") |> String.trim("'") == @marker

  defp strict(result, false, _drop_keys?), do: result

  defp strict(result, true, drop_keys?) do
    result
    |> replace(@config_assignment, fn [original, prefix, _value] ->
      if sensitive_key?(prefix) or strict_key?(prefix) do
        if drop_keys?, do: @marker, else: prefix <> "\"" <> @marker <> "\""
      else
        original
      end
    end)
    |> replace(@hex_key, fn _ -> @marker end)
  end

  defp strict_key?(key), do: key |> String.downcase() |> String.contains?(["session", "private"])

  @tokenizer_rounds 3
  @quotes [?", ?']
  @terminators ~c" \t\r\n,;&\"'{}[]<>"

  defp tokenize(_original, legacy, count, _passes, false, _strict?, _drop?), do: {legacy, count}

  defp tokenize(original, legacy, count, passes, true, strict?, drop?) do
    wrapped =
      original
      |> intervals(%{strict?: strict?, drop?: false, wrapped?: true})
      |> map_through(Enum.reverse(passes))

    legacy
    |> intervals(%{strict?: strict?, drop?: drop?, wrapped?: false})
    |> merge_sorted(wrapped)
    |> union()
    |> apply_intervals(legacy, count)
  end

  defp intervals(text, mode) do
    if :binary.match(text, ["=", ":", "%"]) == :nomatch do
      []
    else
      raw = text |> :binary.bin_to_list() |> Enum.with_index(fn b, i -> {b, i, i + 1} end)

      [raw | decoded_views(raw, @tokenizer_rounds)]
      |> Enum.map(&scan_view(&1, mode))
      |> Enum.reduce([], &merge_sorted/2)
      |> union()
    end
  end

  # Map sorted, disjoint intervals through each regex pass's changed matches
  # ({start, size, new_size}, sorted, in that pass's input coordinates). Query
  # points ascend, so one forward walk over the matches suffices per pass.
  defp map_through(intervals, []), do: intervals

  defp map_through(intervals, [matches | passes]) do
    {mapped, _} =
      Enum.map_reduce(intervals, {matches, 0}, fn {a, b}, state ->
        {start, state} = map_point(a, :start, state)
        {stop, state} = map_point(b - 1, :end, state)
        {{start, stop}, state}
      end)

    mapped |> union() |> map_through(passes)
  end

  defp map_point(x, kind, {[{s, len, new} | rest], delta}) when s + len <= x,
    do: map_point(x, kind, {rest, delta + new - len})

  defp map_point(x, kind, {[{s, _len, new} | _] = matches, delta}) when s <= x do
    {if(kind == :start, do: s + delta, else: s + delta + new), {matches, delta}}
  end

  defp map_point(x, kind, {matches, delta}) do
    {if(kind == :start, do: x + delta, else: x + 1 + delta), {matches, delta}}
  end

  defp decoded_views(_view, 0), do: []

  defp decoded_views(view, rounds) do
    case percent_decode(view, [], false) do
      {decoded, true} -> [decoded | decoded_views(decoded, rounds - 1)]
      {_decoded, false} -> []
    end
  end

  defp percent_decode(
         [{?%, s, _} = percent, {h, _, _} = high, {l, _, e} = low | rest],
         acc,
         changed
       ) do
    case {hex(h), hex(l)} do
      {hi, lo} when is_integer(hi) and is_integer(lo) ->
        percent_decode(rest, [{hi * 16 + lo, s, e} | acc], true)

      _ ->
        percent_decode([high, low | rest], [percent | acc], changed)
    end
  end

  defp percent_decode([entry | rest], acc, changed),
    do: percent_decode(rest, [entry | acc], changed)

  defp percent_decode([], acc, changed), do: {Enum.reverse(acc), changed}

  defp hex(c) when c in ?0..?9, do: c - ?0
  defp hex(c) when c in ?a..?f, do: c - ?a + 10
  defp hex(c) when c in ?A..?F, do: c - ?A + 10
  defp hex(_), do: nil

  # One view: a list of {byte, original_start, original_end}. Returns redaction
  # intervals in original byte offsets, sorted by start.
  defp scan_view(view, mode) do
    bytes = view |> Enum.map(&elem(&1, 0)) |> List.to_tuple()
    spans = List.to_tuple(view)
    n = tuple_size(bytes)
    nexts = next_positions(bytes, n)
    ctx = Map.merge(mode, %{bytes: bytes, spans: spans, n: n, nexts: nexts})

    0
    |> Range.new(n - 1, 1)
    |> Enum.reduce([], fn i, acc ->
      if elem(bytes, i) in [?=, ?:], do: delimiter(ctx, i, acc), else: acc
    end)
    |> Enum.reverse()
  end

  # Right-to-left pass: for each position, the next unescaped double quote,
  # single quote, and value terminator at or after it (n when absent).
  defp next_positions(bytes, n) do
    escaped = escaped_flags(bytes, n)

    {dq, sq, term, _} =
      Enum.reduce((n - 1)..0//-1, {[], [], [], {n, n, n}}, fn i, {dq, sq, term, {d, s, t}} ->
        byte = elem(bytes, i)
        quote? = byte in @quotes and not elem(escaped, i)
        d = if quote? and byte == ?", do: i, else: d
        s = if quote? and byte == ?', do: i, else: s
        t = if byte in @terminators, do: i, else: t
        {[d | dq], [s | sq], [t | term], {d, s, t}}
      end)

    %{?" => List.to_tuple(dq), ?' => List.to_tuple(sq), term: List.to_tuple(term)}
  end

  defp escaped_flags(bytes, n) do
    {flags, _} =
      Enum.map_reduce(0..(n - 1)//1, false, fn i, escape_next? ->
        {escape_next?, not escape_next? and elem(bytes, i) == ?\\}
      end)

    List.to_tuple(flags)
  end

  defp next(%{nexts: nexts, n: n}, kind, i) when i < n, do: elem(Map.fetch!(nexts, kind), i)
  defp next(%{n: n}, _kind, _i), do: n

  defp delimiter(ctx, i, acc) do
    key_end = skip_back(ctx, i - 1, [?\s, ?\t]) + 1
    {key_end, key_quoted?} = closing_key_quote(ctx, key_end)
    key_start = skip_back(ctx, key_end - 1, :key) + 1
    key = for j <- key_start..(key_end - 1)//1, into: <<>>, do: <<elem(ctx.bytes, j)>>
    opener = if key_start > 0, do: elem(ctx.bytes, key_start - 1)
    wrapper = if opener in @quotes and not key_quoted?, do: opener

    with true <- key != "" and (sensitive_key?(key) or (ctx.strict? and strict_key?(key))),
         v = skip_forward(ctx, i + 1),
         true <- not ctx.wrapped? or wrapped_value?(ctx, v, wrapper),
         value_end when value_end > v <- value_end(ctx, v, wrapper),
         false <- marker_at?(ctx, v, value_end) do
      start = if ctx.drop?, do: if(opener in @quotes, do: key_start - 1, else: key_start), else: v
      [{elem(elem(ctx.spans, start), 1), elem(elem(ctx.spans, value_end - 1), 2)} | acc]
    else
      _ -> acc
    end
  end

  defp closing_key_quote(ctx, key_end) do
    if key_end > 0 and elem(ctx.bytes, key_end - 1) in @quotes,
      do: {key_end - 1, true},
      else: {key_end, false}
  end

  defp skip_back(_ctx, j, _class) when j < 0, do: j

  defp skip_back(ctx, j, class) do
    if member?(elem(ctx.bytes, j), class), do: skip_back(ctx, j - 1, class), else: j
  end

  defp member?(c, :key), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c"_.-%"
  defp member?(c, set), do: c in set

  defp skip_forward(%{n: n} = ctx, v) when v < n do
    if elem(ctx.bytes, v) in [?\s, ?\t], do: skip_forward(ctx, v + 1), else: v
  end

  defp skip_forward(_ctx, v), do: v

  defp wrapped_value?(ctx, v, wrapper) do
    wrapper != nil and v < ctx.n and elem(ctx.bytes, v) not in @quotes and
      next(ctx, wrapper, v) < ctx.n
  end

  defp value_end(%{n: n}, v, _wrapper) when v >= n, do: v

  defp value_end(ctx, v, wrapper) do
    byte = elem(ctx.bytes, v)

    cond do
      byte in @quotes -> min(next(ctx, byte, v + 1) + 1, ctx.n)
      wrapper && next(ctx, wrapper, v) < ctx.n -> next(ctx, wrapper, v)
      true -> next(ctx, :term, v)
    end
  end

  # Bounded: values longer than this are never treated as markers (only more
  # redaction), so overlapping value spans cannot make this check quadratic.
  @marker_window byte_size(@marker) + 22

  defp marker_at?(_ctx, v, value_end) when value_end - v > @marker_window, do: false

  defp marker_at?(ctx, v, value_end) do
    value = for j <- v..(value_end - 1)//1, into: <<>>, do: <<elem(ctx.bytes, j)>>
    redacted?(value)
  end

  defp merge_sorted(a, b), do: merge_sorted(a, b, [])
  defp merge_sorted([], b, acc), do: Enum.reverse(acc, b)
  defp merge_sorted(a, [], acc), do: Enum.reverse(acc, a)

  defp merge_sorted([x | a], [y | _] = b, acc) when x <= y, do: merge_sorted(a, b, [x | acc])
  defp merge_sorted(a, [y | b], acc), do: merge_sorted(a, b, [y | acc])

  defp union([]), do: []

  defp union([first | rest]) do
    {last, acc} =
      Enum.reduce(rest, {first, []}, fn {s, e}, {{cs, ce}, acc} ->
        if s < ce, do: {{cs, max(ce, e)}, acc}, else: {{s, e}, [{cs, ce} | acc]}
      end)

    Enum.reverse([last | acc])
  end

  defp apply_intervals([], text, count), do: {text, count}

  defp apply_intervals(intervals, text, count) do
    {parts, offset, count} =
      Enum.reduce(intervals, {[], 0, count}, fn {s, e}, {parts, offset, count} ->
        original = binary_part(text, s, e - s)

        {redacted, count} =
          if redacted?(original), do: {original, count}, else: {@marker, count + 1}

        {[redacted, binary_part(text, offset, s - offset) | parts], e, count}
      end)

    suffix = binary_part(text, offset, byte_size(text) - offset)
    {IO.iodata_to_binary(Enum.reverse([suffix | parts])), count}
  end

  # Build once from match offsets rather than repeatedly copying the growing
  # string; count actual replacements, not markers from an earlier pass.
  defp replace({text, count, passes}, regex, replacement) do
    case Regex.scan(regex, text, return: :index) do
      [] ->
        {text, count, passes}

      matches ->
        {parts, offset, count, changed} =
          Enum.reduce(matches, {[], 0, count, []}, fn [{start, size} | _] = spans,
                                                      {parts, offset, count, changed} ->
            captures = Enum.map(spans, fn {at, length} -> binary_part(text, at, length) end)
            original = hd(captures)
            redacted = replacement.(captures)
            prefix = binary_part(text, offset, start - offset)

            {count, changed} =
              if original == redacted,
                do: {count, changed},
                else: {count + 1, [changed_span(start, size, original, redacted) | changed]}

            {[redacted, prefix | parts], start + size, count, changed}
          end)

        suffix = binary_part(text, offset, byte_size(text) - offset)
        text = IO.iodata_to_binary(Enum.reverse([suffix | parts]))
        {text, count, [Enum.reverse(changed) | passes]}
    end
  end

  # Record only the bytes after the kept prefix (e.g. `password=`), so mapped
  # tokenizer intervals expand to the replacement, not to the key name.
  defp changed_span(start, size, original, redacted) do
    kept = :binary.longest_common_prefix([original, redacted])
    {start + kept, size - kept, byte_size(redacted) - kept}
  end
end
