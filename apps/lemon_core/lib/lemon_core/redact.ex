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

  Counts measure replacements that changed the input, so already-redacted text
  contributes zero. These options do not impose output size limits.
  """
  @spec text(term(), keyword()) :: term() | {term(), non_neg_integer()}
  def text(value, opts) when is_binary(value) do
    drop_keys? = Keyword.get(opts, :drop_keys, false)
    strict? = Keyword.get(opts, :strict, false)

    result =
      {value, 0}
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

  # Build once from match offsets rather than repeatedly copying the growing
  # string; count actual replacements, not markers from an earlier pass.
  defp replace({text, count}, regex, replacement) do
    case Regex.scan(regex, text, return: :index) do
      [] ->
        {text, count}

      matches ->
        {parts, offset, count} =
          Enum.reduce(matches, {[], 0, count}, fn [{start, size} | _] = spans,
                                                  {parts, offset, count} ->
            captures = Enum.map(spans, fn {at, length} -> binary_part(text, at, length) end)
            original = hd(captures)
            redacted = replacement.(captures)
            prefix = binary_part(text, offset, start - offset)
            count = if original == redacted, do: count, else: count + 1
            {[redacted, prefix | parts], start + size, count}
          end)

        suffix = binary_part(text, offset, byte_size(text) - offset)
        {IO.iodata_to_binary(Enum.reverse([suffix | parts])), count}
    end
  end
end
