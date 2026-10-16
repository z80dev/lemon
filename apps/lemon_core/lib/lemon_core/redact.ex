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

  Inside a conservative unquoted URL-like token after `?`, an `&key=value`
  starts an independent query pair, so non-sensitive query pairs are retained.
  Keys use ASCII letters, digits, `.`, `_`, `%`, or `-`; values also allow `~` and `+`.
  Queries containing quotes, fragments or ambiguous syntax retain the legacy
  output, except that the literal `[REDACTED]` and `"[REDACTED]"` are inert
  values so repeated redaction stays idempotent. Strict sensitivity, including
  session and private keys, is unchanged. Outside qualifying queries,
  assignment behavior is unchanged.

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

  The text is scanned as a raw byte view plus up to three percent-decoded views.
  Each view is a binary plus a sorted table of its decoded escapes (decoded
  position and original byte span), so any byte maps back to its original span
  by binary search. Each view is checked independently, and keys like
  `%access_key` (whose `%ac` is also a hex escape) still match in the raw view.
  Every `=`/`:` delimiter yields at most one interval; intervals from all views
  are unioned rather than skipped past a previous replacement, so overlapping
  or nested matches cannot leak.

  Complexity is linear in the input length, and plain text stays cheap. Input
  without `=`, `:` or `%` is skipped, a view is decoded only when it contains a
  hex escape, and a view that cannot contain a sensitive key (no case-insensitive
  key-pattern match) is not scanned. Delimiters are found with
  `:binary.matches/2`; no per-byte tables are built. Next-quote and
  next-terminator searches use `:binary.match/3` from the value start and cache
  the last result per kind; value starts ascend, so each search resumes past the
  previous result and every byte is searched at most once per kind. An escaped
  quote is detected by counting the backslashes right before it, and those runs
  are disjoint. A key is scanned backwards only to the previous delimiter, so
  key scans partition the view. Per delimiter, the remaining work is O(1): the
  already-redacted check compares at most a constant number of bytes (longer
  values are never treated as markers), even though value spans of successive
  delimiters may overlap (`token=token=…secret`). Per-view interval lists are
  sorted by start, so the union is a linear merge of at most four lists.
  Mapping intervals through a regex replacement is a single forward walk over
  the sorted interval endpoints and replaced spans, done once per regex (a
  constant number). Applying disjoint intervals copies each byte at most once.
  """

  @marker "[REDACTED]"
  @key_pattern "(?:pairing[_-]?codes?|access[_-]?key|api[_-]?key|auth(?:orization|[_-]?token)|bearer|cookie|credential|master[_-]?key|oauth|passw(?:or)?d|private[_-]?key|secret|token|wallet[_-]?key)"
  @sensitive_key Regex.compile!(@key_pattern, "i")
  @private_key ~r/-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----.*?(?:-----END [A-Z0-9 ]*PRIVATE KEY-----|\z)/s
  @credentials ~r/(?:sk-[A-Za-z0-9_-]{8,}|(?i:(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{8,}|xox[a-z]-[A-Za-z0-9-]{8,})|AKIA[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{35}|\beyJ(?:[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|[A-Za-z0-9+\/_-]{30,}(?:\.[A-Za-z0-9+\/_-]+)*=*))/
  @authorization ~r/\bbearer\s+[A-Za-z0-9._~+\/=:-]+/i
  @assignment ~r/((?<![\w.-])["']?[A-Za-z0-9_.-]*(?:#{@key_pattern}|session|private)[A-Za-z0-9_.-]*["']?[ \t]*[:=][ \t]*)(basic[ \t]+[A-Za-z0-9._~+\/=:-]+|""".*?(?:"""|\z)|'''.*?(?:'''|\z)|"(?:\\.|[^"\\])*(?:"|\z)|'(?:\\.|[^'\\])*(?:'|\z)|\[REDACTED\]|[^\s,;&"'{}\[\]]+|&)/is
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

    {legacy, count, passes, _queries} =
      {value, 0, [], genuine_queries(value)}
      |> replace(@private_key, fn _ -> @marker end)
      |> replace(@authorization, fn _ -> @marker end)
      |> replace(@assignment, fn [original, prefix, secret], _query? ->
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
    |> replace(@config_assignment, fn [original, prefix, value], query? ->
      query? = query? and query_prefix?(prefix)

      if sensitive_key?(prefix) or strict_key?(prefix) do
        # Only a suffix adjacent to an unquoted query value is recoverable.
        # An ampersand after a fragment or inside quotes belongs to the legacy
        # secret extent, not to another query pair.
        suffix =
          if query? do
            case Regex.run(
                   ~r/\A(?:[A-Za-z0-9._~%+-]*|"\[REDACTED\]"|\[REDACTED\])((?:&[A-Za-z0-9._~%+-]+=(?:[A-Za-z0-9._~%+-]*|"\[REDACTED\]"|\[REDACTED\]))+)\z/,
                   value
                 ) do
              [_, pairs] -> pairs
              nil -> ""
            end
          else
            ""
          end

        if drop_keys?, do: @marker <> suffix, else: prefix <> "\"" <> @marker <> "\"" <> suffix
      else
        original
      end
    end)
    |> replace(@hex_key, fn _ -> @marker end)
  end

  defp strict_key?(key), do: key |> String.downcase() |> String.contains?(["session", "private"])

  @tokenizer_rounds 3
  @quotes [?", ?']
  @terminators Enum.map(~c" \t\r\n,;&\"'{}[]<>", &<<&1>>)
  # A case-insensitive superset of every key `sensitive_key?/1` accepts.
  @sensitive_hint Regex.compile!(@key_pattern <> "|mcp_?servers", "i")
  @strict_hint ~r/session|private/i

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
      [{text, {}} | decoded_views(text, {}, @tokenizer_rounds)]
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

  # A view is {bytes, escapes}: `escapes` is a tuple of {position, start, end}
  # sorted by position, one per decoded byte; other bytes are contiguous with
  # the preceding entry (or the view start) in the original.
  defp decoded_views(_bytes, _escapes, 0), do: []

  defp decoded_views(bytes, escapes, rounds) do
    case escape_positions(bytes) do
      [] ->
        []

      positions ->
        view = {decode(bytes, positions), remap(escapes, positions)}
        [view | decoded_views(elem(view, 0), elem(view, 1), rounds - 1)]
    end
  end

  # Positions of `%XX` escapes. Hex digits are never `%`, so escapes found from
  # every `%` cannot overlap, matching a left-to-right decode.
  defp escape_positions(bytes) do
    n = byte_size(bytes)

    for {p, 1} <- :binary.matches(bytes, "%"),
        p + 2 < n,
        hex(:binary.at(bytes, p + 1)) != nil and hex(:binary.at(bytes, p + 2)) != nil,
        do: p
  end

  defp decode(bytes, positions) do
    {parts, offset} =
      Enum.reduce(positions, {[], 0}, fn p, {parts, offset} ->
        byte = hex(:binary.at(bytes, p + 1)) * 16 + hex(:binary.at(bytes, p + 2))
        {[byte, binary_part(bytes, offset, p - offset) | parts], p + 3}
      end)

    IO.iodata_to_binary(
      Enum.reverse([binary_part(bytes, offset, byte_size(bytes) - offset) | parts])
    )
  end

  # Escape table of the decoded view: new escapes span from their `%` to their
  # second hex digit; old escapes not consumed by a new one shift left.
  defp remap(escapes, positions) do
    decoded =
      Enum.with_index(positions, fn p, k ->
        {p - 2 * k, elem(span(escapes, p), 0), elem(span(escapes, p + 2), 1)}
      end)

    escapes
    |> Tuple.to_list()
    |> shift_escapes(positions, 0, [])
    |> merge_sorted(decoded)
    |> List.to_tuple()
  end

  defp shift_escapes([], _positions, _shift, acc), do: Enum.reverse(acc)

  defp shift_escapes([{q, s, e} | rest], [], shift, acc),
    do: shift_escapes(rest, [], shift, [{q - shift, s, e} | acc])

  defp shift_escapes([{q, s, e} | rest], [p | _] = positions, shift, acc) when q < p,
    do: shift_escapes(rest, positions, shift, [{q - shift, s, e} | acc])

  defp shift_escapes([{q, _, _} | rest], [p | _] = positions, shift, acc) when q <= p + 2,
    do: shift_escapes(rest, positions, shift, acc)

  defp shift_escapes(escapes, [_ | positions], shift, acc),
    do: shift_escapes(escapes, positions, shift + 2, acc)

  # Original byte span of view position p.
  defp span(escapes, p) do
    case floor_escape(escapes, p, 0, tuple_size(escapes) - 1, nil) do
      nil -> {p, p + 1}
      {^p, s, e} -> {s, e}
      {q, _s, e} -> {e + p - q - 1, e + p - q}
    end
  end

  defp floor_escape(_escapes, _p, lo, hi, best) when lo > hi, do: best

  defp floor_escape(escapes, p, lo, hi, best) do
    mid = div(lo + hi, 2)
    entry = elem(escapes, mid)

    if elem(entry, 0) <= p,
      do: floor_escape(escapes, p, mid + 1, hi, entry),
      else: floor_escape(escapes, p, lo, mid - 1, best)
  end

  defp hex(c) when c in ?0..?9, do: c - ?0
  defp hex(c) when c in ?a..?f, do: c - ?a + 10
  defp hex(c) when c in ?A..?F, do: c - ?A + 10
  defp hex(_), do: nil

  # Returns redaction intervals in original byte offsets, sorted by start.
  defp scan_view({bytes, escapes}, mode) do
    if may_hold_key?(bytes, mode.strict?) do
      ctx = Map.merge(mode, %{bytes: bytes, escapes: escapes, n: byte_size(bytes)})

      bytes
      |> :binary.matches(["=", ":"])
      |> Enum.reduce({[], %{}}, fn {i, 1}, state ->
        delimiter(ctx, i, state)
      end)
      |> elem(0)
      |> Enum.reverse()
    else
      []
    end
  end

  defp may_hold_key?(bytes, strict?) do
    Regex.match?(@sensitive_hint, bytes) or (strict? and Regex.match?(@strict_hint, bytes))
  end

  # First unescaped `kind` quote or (`:term`) value terminator at or after i, n
  # when absent. The last result per kind is cached: it also answers any later
  # query between its start and the found position.
  defp next(%{n: n}, _kind, i, cache) when i >= n, do: {n, cache}

  defp next(ctx, kind, i, cache) do
    case cache do
      %{^kind => {from, found}} when from <= i and i <= found ->
        {found, cache}

      _ ->
        found = find(ctx, kind, i)
        {found, Map.put(cache, kind, {i, found})}
    end
  end

  defp find(%{n: n}, _kind, i) when i >= n, do: n

  defp find(%{bytes: bytes, n: n} = ctx, kind, i) do
    pattern = if kind == :term, do: @terminators, else: <<kind>>

    case :binary.match(bytes, pattern, scope: {i, n - i}) do
      :nomatch ->
        n

      {p, 1} when kind != :term ->
        if escaped?(bytes, p - 1, false), do: find(ctx, kind, p + 1), else: p

      {p, 1} ->
        p
    end
  end

  # A byte is escaped when an odd-length backslash run directly precedes it.
  defp escaped?(bytes, j, odd?) when j >= 0 do
    if :binary.at(bytes, j) == ?\\, do: escaped?(bytes, j - 1, not odd?), else: odd?
  end

  defp escaped?(_bytes, _j, odd?), do: odd?

  defp delimiter(ctx, i, {acc, cache}) do
    key_end = skip_back(ctx, i - 1, [?\s, ?\t]) + 1
    {key_end, key_quoted?} = closing_key_quote(ctx, key_end)
    key_start = skip_back(ctx, key_end - 1, :key) + 1
    key = binary_part(ctx.bytes, key_start, key_end - key_start)
    opener = if key_start > 0, do: :binary.at(ctx.bytes, key_start - 1)
    wrapper = if opener in @quotes and not key_quoted?, do: opener

    if key != "" and
         (sensitive_key?(key) or (ctx.strict? and strict_key?(key))) do
      v = skip_forward(ctx, i + 1)

      {wrapped?, cache} =
        if ctx.wrapped?, do: wrapped_value?(ctx, v, wrapper, cache), else: {true, cache}

      {value_end, cache} = if wrapped?, do: value_end(ctx, v, wrapper, cache), else: {v, cache}

      if value_end > v and not marker_at?(ctx, v, value_end) do
        start =
          if ctx.drop?, do: if(opener in @quotes, do: key_start - 1, else: key_start), else: v

        interval = {elem(span(ctx.escapes, start), 0), elem(span(ctx.escapes, value_end - 1), 1)}
        {[interval | acc], cache}
      else
        {acc, cache}
      end
    else
      {acc, cache}
    end
  end

  defp closing_key_quote(ctx, key_end) do
    if key_end > 0 and :binary.at(ctx.bytes, key_end - 1) in @quotes,
      do: {key_end - 1, true},
      else: {key_end, false}
  end

  defp skip_back(_ctx, j, _class) when j < 0, do: j

  defp skip_back(ctx, j, class) do
    if member?(:binary.at(ctx.bytes, j), class), do: skip_back(ctx, j - 1, class), else: j
  end

  defp member?(c, :key), do: c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in ~c"_.-%"
  defp member?(c, set), do: c in set

  defp skip_forward(%{n: n} = ctx, v) when v < n do
    if :binary.at(ctx.bytes, v) in [?\s, ?\t], do: skip_forward(ctx, v + 1), else: v
  end

  defp skip_forward(_ctx, v), do: v

  defp wrapped_value?(%{n: n} = ctx, v, wrapper, cache)
       when wrapper != nil and v < n do
    if :binary.at(ctx.bytes, v) in @quotes do
      {false, cache}
    else
      {found, cache} = next(ctx, wrapper, v, cache)
      {found < n, cache}
    end
  end

  defp wrapped_value?(_ctx, _v, _wrapper, cache), do: {false, cache}

  defp value_end(%{n: n}, v, _wrapper, cache) when v >= n, do: {v, cache}

  defp value_end(%{n: n} = ctx, v, wrapper, cache) do
    byte = :binary.at(ctx.bytes, v)

    if byte in @quotes do
      {found, cache} = next(ctx, byte, v + 1, cache)
      {min(found + 1, n), cache}
    else
      {found, cache} = if wrapper, do: next(ctx, wrapper, v, cache), else: {n, cache}
      if found < n, do: {found, cache}, else: next(ctx, :term, v, cache)
    end
  end

  # Bounded: values longer than this are never treated as markers (only more
  # redaction), so overlapping value spans cannot make this check quadratic.
  @marker_window byte_size(@marker) + 22

  defp marker_at?(_ctx, v, value_end) when value_end - v > @marker_window, do: false
  defp marker_at?(ctx, v, value_end), do: redacted?(binary_part(ctx.bytes, v, value_end - v))

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
  # Stop unquoted query values at '&', but retain the legacy extent everywhere
  # else. Both the context events and regex cursor advance monotonically: an
  # ampersand suffix is never scanned again for each preceding query pair.
  defp assignment_matches(text, events) do
    assignment_matches(text, 0, events, false, [])
  end

  defp assignment_matches(text, offset, events, query?, acc) do
    case Regex.run(@assignment, text, offset: offset, return: :index) do
      nil ->
        Enum.reverse(acc)

      [{start, size}, prefix, {value_start, value_size}] = spans ->
        {events, starts_in_query?} = query_context(text, events, start, query?)
        stop = start + size
        {events, query?} = query_context(text, events, stop, starts_in_query?)
        {prefix_start, prefix_size} = prefix

        query_assignment? =
          text
          |> binary_part(prefix_start, prefix_size)
          |> String.trim_trailing()
          |> String.ends_with?("=")

        split_query? = starts_in_query? and query? and query_assignment?

        boundary =
          if value_size == 1 and binary_part(text, value_start, 1) == "&",
            do: value_start,
            else: stop

        split_query? = split_query? and query_pair_at?(text, boundary)
        value = binary_part(text, value_start, value_size)

        stop =
          cond do
            split_query? and value == "&" ->
              value_start

            not split_query? and stop < byte_size(text) and
              (value == "&" or :binary.at(text, stop) == ?&) and
              not String.starts_with?(value, ["\"", "'", "[REDACTED]"]) and
                not Regex.match?(~r/^basic[ \t]/i, value) ->
              case :binary.match(
                     text,
                     [" ", "\t", "\r", "\n", "\f", "\v", ",", ";", "\"", "'", "{", "}", "[", "]"],
                     scope: {stop, byte_size(text) - stop}
                   ) do
                :nomatch -> byte_size(text)
                {at, _} -> at
              end

            true ->
              stop
          end

        spans =
          if stop == start + size,
            do: spans,
            else: [{start, stop - start}, prefix, {value_start, stop - value_start}]

        assignment_matches(text, stop, events, query?, [spans | acc])
    end
  end

  defp query_pair_at?(text, at) do
    at < byte_size(text) and :binary.at(text, at) == ?& and
      (at + 1 == byte_size(text) or
         Regex.match?(~r/\A&[A-Za-z0-9_.%-]+=/, binary_part(text, at, byte_size(text) - at)))
  end

  # Quotes are opaque, and fragments cannot start another query. An assignment
  # before '?' is not a URL-like token (for example, session="?").
  defp query_events(text, at, _state, _quote, _start, acc) when at == byte_size(text),
    do: Enum.reverse(acc)

  defp query_events(text, at, state, quote, start, acc) do
    byte = :binary.at(text, at)

    {state, quote, start, acc, step} =
      cond do
        quote != nil ->
          {delimiter, width, resume} = quote

          if at + width <= byte_size(text) and
               binary_part(text, at, width) == delimiter and
               (width == 3 or not escaped?(text, at - 1, false)) do
            {resume, nil, at + width, acc, width}
          else
            {state, quote, start, acc, 1}
          end

        state == :query and byte == ?" and at + 12 <= byte_size(text) and
            binary_part(text, at, 12) == "\"[REDACTED]\"" ->
          {state, nil, start, acc, 12}

        byte in [?", ?'] ->
          delimiter = <<byte, byte, byte>>

          width =
            if at + 3 <= byte_size(text) and binary_part(text, at, 3) == delimiter, do: 3, else: 1

          resume = if state == :fragment, do: :fragment, else: :assignment

          {:token, {binary_part(text, at, width), width, resume}, at + width, [{at, false} | acc],
           width}

        byte in [?\s, ?\t, ?\r, ?\n, ?\f, ?\v, ?;, ?,] ->
          {:token, nil, at + 1, [{at, false} | acc], 1}

        byte == ?# ->
          {:fragment, nil, start, [{at, false} | acc], 1}

        byte == ?? and state == :token and at > start ->
          if conservative_query?(text, start, at),
            do: {:query, nil, start, [{at, true} | acc], 1},
            else: {:assignment, nil, start, acc, 1}

        byte == ?? and state == :token ->
          {:assignment, nil, start, acc, 1}

        byte == ?= and state == :token ->
          {:assignment, nil, start, acc, 1}

        true ->
          {state, nil, start, acc, 1}
      end

    query_events(text, at + step, state, quote, start, acc)
  end

  # Qualification is deliberately narrow and scans each token only once:
  # invalid tokens never re-enter :token before a whitespace boundary.
  # Markers are accepted because later regex passes see earlier replacements.
  defp conservative_query?(text, start, question) do
    prefix = binary_part(text, start, question - start)
    tail = binary_part(text, question + 1, byte_size(text) - question - 1)

    Regex.match?(~r/\A[A-Za-z0-9:\/._~%+-]+\z/, prefix) and
      Regex.match?(
        ~r/\A[A-Za-z0-9_.%-]+=(?:[A-Za-z0-9._~%+-]*|"\[REDACTED\]"|\[REDACTED\])(?:&(?:[A-Za-z0-9_.%-]+=(?:[A-Za-z0-9._~%+-]*|"\[REDACTED\]"|\[REDACTED\]))?)*(?:\z|\s)/,
        tail
      )
  end

  defp query_context(text, [{at, query?} | rest], start, _query?) when at < start,
    do: query_context(text, rest, start, query?)

  defp query_context(_text, events, _start, query?), do: {events, query?}

  # Freeze recognition on the original input. Redacting a fragment, quote, or
  # malformed value in an earlier pass must never manufacture a genuine query.
  # The same linear endpoint mapping used by the tokenizer carries these
  # approved regions through every regex replacement.
  defp genuine_queries(text) do
    {regions, start} =
      text
      |> query_events(0, :token, nil, 0, [])
      |> Enum.reduce({[], nil}, fn
        {at, true}, {acc, nil} -> {acc, at}
        {at, false}, {acc, start} when start != nil -> {[{start, at} | acc], nil}
        _, state -> state
      end)

    regions = if start, do: [{start, byte_size(text)} | regions], else: regions
    Enum.reverse(regions)
  end

  defp region_events(regions),
    do: Enum.flat_map(regions, fn {a, b} -> [{a, true}, {b, false}] end)

  defp query_prefix?(prefix) do
    {_events, query?} =
      query_context(prefix, query_events(prefix, 0, :token, nil, 0, []), byte_size(prefix), false)

    query? and Regex.match?(~r/[?&][A-Za-z0-9_.-]+[ \t]*=[ \t]*\z/, prefix)
  end

  defp replace({text, count, passes, queries}, regex, replacement) do
    events = region_events(queries)

    matches =
      if regex.source == @assignment.source,
        do: assignment_matches(text, events),
        else: Regex.scan(regex, text, return: :index)

    case matches do
      [] ->
        {text, count, passes, queries}

      matches ->
        {parts, offset, count, changed, _, _} =
          Enum.reduce(
            matches,
            {[], 0, count, [], events, false},
            fn [{start, size} | _] = spans, {parts, offset, count, changed, events, query?} ->
              context_at =
                if regex.source == @config_assignment.source,
                  do: elem(Enum.at(spans, 2), 0),
                  else: start

              {events, query?} = query_context(text, events, context_at, query?)
              captures = Enum.map(spans, fn {at, length} -> binary_part(text, at, length) end)
              original = hd(captures)

              redacted =
                if is_function(replacement, 2),
                  do: replacement.(captures, query?),
                  else: replacement.(captures)

              prefix = binary_part(text, offset, start - offset)

              {count, changed} =
                if original == redacted,
                  do: {count, changed},
                  else: {count + 1, [changed_span(start, size, original, redacted) | changed]}

              {[redacted, prefix | parts], start + size, count, changed, events, query?}
            end
          )

        suffix = binary_part(text, offset, byte_size(text) - offset)
        text = IO.iodata_to_binary(Enum.reverse([suffix | parts]))
        changed = Enum.reverse(changed)
        {text, count, [changed | passes], map_through(queries, [changed])}
    end
  end

  # Record only the bytes after the kept prefix (e.g. `password=`), so mapped
  # tokenizer intervals expand to the replacement, not to the key name.
  defp changed_span(start, size, original, redacted) do
    kept = :binary.longest_common_prefix([original, redacted])
    {start + kept, size - kept, byte_size(redacted) - kept}
  end
end
