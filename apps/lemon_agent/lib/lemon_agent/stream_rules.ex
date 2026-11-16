defmodule LemonAgent.StreamRules do
  @moduledoc """
  Bounded, request-local matching for dormant streaming rules.

  `new/1` compiles rules once. `feed/2` observes provider `:text_delta` and
  `:tool_call_delta` events and returns the first matching rule, without changing
  messages, injecting content, counting injections, or performing I/O. The caller
  owns cancellation and durable injection limits, and must pass only eligible
  rules to each new attempt.

  ## Caller safety budgets

  These are fixed caller policies, not measured latency guarantees:

    * At most 32 rules, each with a nonempty name of at most 256 bytes, a body of
      at most 65,536 bytes, and a nonempty regex source of at most 1,024 bytes.
      `injection_limit` must be a positive integer. Only these four fields are
      retained; unrelated rule metadata is discarded.
    * At most 32 open streams, keyed separately by content kind and index.
      Indices must be nonnegative signed-32-bit integers. Block starts reset
      their buffer; block ends release it. Response lifecycle events clear all
      buffers. Deltas without a start event are also supported.
    * Each buffer retains at most 4,096 bytes. A delta may contain at most 16,384
      bytes and is scanned from its beginning in chunks of at most 1,024 bytes.
      Every chunk is appended to the buffer and the resulting 4,096-byte suffix
      is searched. No accepted delta's prefix is silently skipped.
    * Each delta runs at most 16 * 32 regex searches, with `match_limit: 10_000`
      and `match_limit_recursion: 100` for each search. As documented by Erlang's
      `:re.run/3`, the match counter can restart at each candidate position, so
      the 4,096-byte subject bound is also essential. Captures are not returned.
      `:report_errors` ensures engine exhaustion is never mistaken for a miss.

  Patterns use byte semantics (`:never_utf`); literals may contain UTF-8, but
  character classes and quantifiers operate on bytes. This permits fragments
  and windows ending inside a UTF-8 sequence without a decoding pass. Anchors
  and lookarounds apply to the current window, not the complete response. A
  match whose full required context spans at most 3,073 bytes fits a searched
  window across chunk boundaries; longer matches are not guaranteed. Lookahead
  and end anchors describe output so far, not future output. Within a window,
  declaration order breaks ties; the first matching window ends the search.

  Invalid configuration, oversized deltas, exhausted stream capacity, and regex
  engine limits raise `LemonAgent.StreamRules.Error` with a content-free reason.
  Callers must fail the attempt, not ignore the error or continue unchecked.
  With no rules, every event is a no-op and no output is retained.
  """

  defmodule Error do
    @moduledoc "An invalid or exhausted streaming-rule safety budget."
    defexception [:reason]

    @impl true
    def message(%__MODULE__{reason: reason}), do: "stream rule matching failed: #{reason}"
  end

  @max_rules 32
  @max_name_bytes 256
  @max_content_bytes 65_536
  @max_pattern_bytes 1024
  @max_streams 32
  @max_index 2_147_483_647
  @window_bytes 4096
  @chunk_bytes 1024
  @max_delta_bytes 16_384
  @match_options [
    :report_errors,
    {:capture, :none},
    {:match_limit, 10_000},
    {:match_limit_recursion, 100}
  ]

  @type rule :: %{
          name: binary(),
          content: binary(),
          stream_pattern: binary(),
          injection_limit: pos_integer()
        }
  @opaque t :: %__MODULE__{
            rules: [{rule(), :re.mp()}],
            buffers: %{{:text_delta | :tool_call_delta, non_neg_integer()} => binary()}
          }

  defstruct rules: [], buffers: %{}

  @doc "Compiles a bounded list of eligible rules, raising `Error` on invalid configuration."
  @spec new([rule()]) :: t()
  def new(rules) when is_list(rules) do
    validate_rule_count!(rules, @max_rules)
    %__MODULE__{rules: Enum.map(rules, &compile_rule!/1)}
  end

  def new(_rules), do: fail!(:invalid_rules)

  @doc "Observes one provider event; never inspects its partial-message snapshot."
  @spec feed(t(), term()) :: {t(), nil | rule()}
  def feed(%__MODULE__{rules: []} = state, _event), do: {state, nil}

  def feed(%__MODULE__{} = state, {kind, index, delta, _partial})
      when kind in [:text_delta, :tool_call_delta] do
    validate_delta!(delta)
    key = stream_key!(kind, index)

    if delta == "" do
      {state, nil}
    else
      validate_stream_capacity!(state.buffers, key)
      buffer = Map.get(state.buffers, key, "")
      {buffer, matched} = scan_delta(delta, buffer, state.rules)
      {%{state | buffers: Map.put(state.buffers, key, own_binary(buffer))}, matched}
    end
  end

  def feed(%__MODULE__{} = state, {kind, index, _partial})
      when kind in [:text_start, :tool_call_start] do
    key = stream_key!(delta_kind(kind), index)
    validate_stream_capacity!(state.buffers, key)
    {%{state | buffers: Map.put(state.buffers, key, "")}, nil}
  end

  def feed(%__MODULE__{} = state, {kind, index, _content, _partial})
      when kind in [:text_end, :tool_call_end] do
    key = stream_key!(delta_kind(kind), index)
    {%{state | buffers: Map.delete(state.buffers, key)}, nil}
  end

  def feed(%__MODULE__{} = state, {:start, _partial}), do: clear(state)
  def feed(%__MODULE__{} = state, {:done, _reason, _partial}), do: clear(state)
  def feed(%__MODULE__{} = state, {:error, _reason, _partial}), do: clear(state)
  def feed(%__MODULE__{} = state, {:canceled, _reason}), do: clear(state)
  def feed(%__MODULE__{} = state, _event), do: {state, nil}

  defp validate_rule_count!([], _remaining), do: :ok
  defp validate_rule_count!([_ | _], 0), do: fail!(:too_many_rules)

  defp validate_rule_count!([_ | rest], remaining),
    do: validate_rule_count!(rest, remaining - 1)

  defp validate_rule_count!(_rules, _remaining), do: fail!(:invalid_rules)

  defp compile_rule!(%{
         name: name,
         content: content,
         stream_pattern: source,
         injection_limit: limit
       })
       when is_binary(name) and name != "" and is_binary(content) and is_binary(source) and
              source != "" and is_integer(limit) and limit > 0 do
    cond do
      byte_size(name) > @max_name_bytes -> fail!(:name_too_large)
      byte_size(content) > @max_content_bytes -> fail!(:content_too_large)
      byte_size(source) > @max_pattern_bytes -> fail!(:pattern_too_large)
      true -> :ok
    end

    case :re.compile(source, [:never_utf]) do
      {:ok, compiled} ->
        rule = %{
          name: own_binary(name),
          content: own_binary(content),
          stream_pattern: own_binary(source),
          injection_limit: limit
        }

        {rule, compiled}

      {:error, _reason} ->
        fail!(:invalid_pattern)
    end
  end

  defp compile_rule!(_rule), do: fail!(:invalid_rule)

  defp validate_delta!(delta) when is_binary(delta) and byte_size(delta) <= @max_delta_bytes,
    do: :ok

  defp validate_delta!(delta) when is_binary(delta), do: fail!(:delta_too_large)
  defp validate_delta!(_delta), do: fail!(:invalid_delta)

  defp stream_key!(kind, index) when is_integer(index) and index >= 0 and index <= @max_index,
    do: {kind, index}

  defp stream_key!(_kind, _index), do: fail!(:invalid_stream_index)

  defp validate_stream_capacity!(buffers, key) do
    if map_size(buffers) >= @max_streams and not is_map_key(buffers, key) do
      fail!(:too_many_streams)
    end
  end

  defp delta_kind(kind) when kind in [:text_start, :text_end], do: :text_delta
  defp delta_kind(kind) when kind in [:tool_call_start, :tool_call_end], do: :tool_call_delta

  defp scan_delta(<<>>, buffer, _rules), do: {buffer, nil}

  defp scan_delta(delta, buffer, rules) do
    size = min(byte_size(delta), @chunk_bytes)
    <<chunk::binary-size(^size), rest::binary>> = delta
    keep = min(byte_size(buffer), @window_bytes - size)
    buffer = binary_part(buffer, byte_size(buffer) - keep, keep) <> chunk

    case match_rule(rules, buffer) do
      nil -> scan_delta(rest, buffer, rules)
      rule -> {buffer, rule}
    end
  end

  defp match_rule([], _buffer), do: nil

  defp match_rule([{rule, compiled} | rest], buffer) do
    case :re.run(buffer, compiled, @match_options) do
      :match -> rule
      :nomatch -> match_rule(rest, buffer)
      {:error, reason} -> fail!(reason)
    end
  end

  # A small provider fragment or rule field may be a slice of a much larger
  # binary. Retaining that backing binary would defeat the byte budgets.
  defp own_binary(binary) do
    if :binary.referenced_byte_size(binary) > byte_size(binary),
      do: :binary.copy(binary),
      else: binary
  end

  defp clear(state), do: {%{state | buffers: %{}}, nil}
  defp fail!(reason), do: raise(Error, reason: reason)
end
