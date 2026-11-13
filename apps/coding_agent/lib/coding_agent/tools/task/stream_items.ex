defmodule CodingAgent.Tools.Task.StreamItems do
  @moduledoc """
  Incremental reader for the JSON arguments of a streaming `task` call.

  `feed/2` takes the accumulated argument text each time it grows and returns
  every `tasks[]` element whose object closed since the previous feed, decoded,
  as `{index, item, fields}`. `fields` holds the top-level members that were
  complete when the item closed (`tasks` itself excluded); members written after
  `tasks` are therefore never part of an item's snapshot.

  Only bytes beyond the previous feed are scanned. Structure (strings, escapes
  split across feeds, nesting) is tracked byte-wise; complete values are decoded
  with Jason, so escapes and unicode follow JSON exactly.

  Input that the finished call could not pass batch validation with — malformed
  JSON, a repeated top-level key, a `tasks` element that is not an object — makes
  the reader invalid; it returns nothing further.
  """

  @type item :: {non_neg_integer(), map(), map()}

  @type t :: %__MODULE__{
          pos: non_neg_integer(),
          stack: [:object | :array],
          string: nil | :key | :value | :other,
          escape: boolean(),
          top: atom(),
          kind: nil | :string | :scalar | :container,
          key: String.t() | nil,
          mark: non_neg_integer() | nil,
          item_mark: non_neg_integer() | nil,
          fields: map(),
          keys: MapSet.t(String.t()),
          count: non_neg_integer(),
          items: [item()]
        }

  # `top` follows the top-level object: :start (before `{`), :key, :key_string,
  # :colon, :value, :in_value (`kind` says which), :after_value, :done, :invalid.
  # `stack` holds open containers, innermost first; the top-level object is last.
  defstruct pos: 0,
            stack: [],
            string: nil,
            escape: false,
            top: :start,
            kind: nil,
            key: nil,
            mark: nil,
            item_mark: nil,
            fields: %{},
            keys: MapSet.new(),
            count: 0,
            items: []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Whether the text can no longer be a valid batch call."
  @spec invalid?(t()) :: boolean()
  def invalid?(%__MODULE__{top: top}), do: top == :invalid

  @doc """
  Advances over `json`, the full accumulated text (each feed extends the last).
  """
  @spec feed(t(), binary()) :: {t(), [item()]}
  def feed(%__MODULE__{top: top} = state, _json) when top in [:done, :invalid], do: {state, []}

  def feed(%__MODULE__{pos: pos} = state, json) when is_binary(json) and byte_size(json) >= pos do
    rest = binary_part(json, pos, byte_size(json) - pos)
    state = resume(rest, pos, json, %{state | items: []})
    {%{state | items: []}, Enum.reverse(state.items)}
  end

  def feed(%__MODULE__{} = state, _json), do: {invalid(state), []}

  # ── Scanning ─────────────────────────────────────────────────────────────

  # An escape split across feeds: its escaped byte is the first one now.
  defp resume(<<>>, i, _json, state), do: %{state | pos: i}

  defp resume(<<_, rest::binary>>, i, json, %{escape: true} = state),
    do: string(rest, i + 1, json, %{state | escape: false})

  defp resume(rest, i, json, %{string: nil} = state), do: scan(rest, i, json, state)
  defp resume(rest, i, json, state), do: string(rest, i, json, state)

  defp scan(<<>>, i, _json, state), do: %{state | pos: i}

  defp scan(_rest, i, _json, %{top: top} = state) when top in [:done, :invalid],
    do: %{state | pos: i}

  defp scan(<<c, rest::binary>>, i, json, state) when c in ~c" \t\r\n",
    do: scan(rest, i + 1, json, state)

  defp scan(<<?", rest::binary>>, i, json, state),
    do: string(rest, i + 1, json, open_string(state, i))

  defp scan(<<c, rest::binary>>, i, json, state) when c in ~c"{[",
    do: scan(rest, i + 1, json, open(state, c, i))

  defp scan(<<c, rest::binary>>, i, json, state) when c in ~c"}]",
    do: scan(rest, i + 1, json, close(state, c, i, json))

  defp scan(<<?:, rest::binary>>, i, json, state), do: scan(rest, i + 1, json, colon(state))

  defp scan(<<?,, rest::binary>>, i, json, state),
    do: scan(rest, i + 1, json, comma(state, i, json))

  defp scan(<<_, rest::binary>>, i, json, state), do: scan(rest, i + 1, json, scalar(state, i))

  # Inside a string only `"` and `\` matter; skip to the next of them.
  defp string(_rest, i, _json, %{top: :invalid} = state), do: %{state | pos: i}

  defp string(rest, i, json, state) do
    case :binary.match(rest, ["\"", "\\"]) do
      :nomatch ->
        %{state | pos: i + byte_size(rest)}

      {at, 1} ->
        case binary_part(rest, at, 1) do
          "\\" when at + 2 <= byte_size(rest) ->
            skip = at + 2
            string(binary_part(rest, skip, byte_size(rest) - skip), i + skip, json, state)

          "\\" ->
            %{state | pos: i + byte_size(rest), escape: true}

          "\"" ->
            kind = state.string
            state = close_string(%{state | string: nil}, kind, i + at, json)
            scan(binary_part(rest, at + 1, byte_size(rest) - at - 1), i + at + 1, json, state)
        end
    end
  end

  # ── Transitions ──────────────────────────────────────────────────────────

  defp open_string(%{stack: [:object], top: :key} = state, i),
    do: %{state | string: :key, mark: i, top: :key_string}

  defp open_string(%{stack: [:object], top: :value} = state, i),
    do: %{state | string: :value, mark: i, top: :in_value, kind: :string}

  defp open_string(%{stack: stack} = state, _i) when length(stack) < 2,
    do: invalid(%{state | string: :other})

  defp open_string(state, _i) do
    if tasks_element?(state),
      do: invalid(%{state | string: :other}),
      else: %{state | string: :other}
  end

  defp close_string(state, :key, last, json) do
    case Jason.decode(binary_part(json, state.mark, last - state.mark + 1)) do
      {:ok, key} ->
        if MapSet.member?(state.keys, key),
          do: invalid(state),
          else: %{state | key: key, keys: MapSet.put(state.keys, key), mark: nil, top: :colon}

      {:error, _reason} ->
        invalid(state)
    end
  end

  defp close_string(state, :value, last, json), do: complete(state, last, json)
  defp close_string(state, :other, _last, _json), do: state

  defp open(%{stack: [], top: :start} = state, ?{, _i), do: %{state | stack: [:object], top: :key}
  defp open(%{stack: []} = state, _c, _i), do: invalid(state)

  defp open(%{stack: [:object], top: :value} = state, c, i),
    do: %{state | stack: [container(c), :object], top: :in_value, kind: :container, mark: i}

  defp open(%{stack: [:object]} = state, _c, _i), do: invalid(state)

  defp open(state, c, i) do
    cond do
      tasks_element?(state) and c == ?{ ->
        %{state | stack: [:object | state.stack], item_mark: i}

      tasks_element?(state) ->
        invalid(state)

      true ->
        %{state | stack: [container(c) | state.stack]}
    end
  end

  defp close(%{stack: [open | outer]} = state, c, i, json) do
    if open == container(c), do: closed(%{state | stack: outer}, c, i, json), else: invalid(state)
  end

  defp close(state, _c, _i, _json), do: invalid(state)

  # The top-level object itself.
  defp closed(%{stack: [], top: :in_value, kind: :scalar} = state, _c, i, json) do
    case complete(state, i - 1, json) do
      %{top: :invalid} = state -> state
      state -> %{state | top: :done}
    end
  end

  defp closed(%{stack: [], top: top} = state, _c, _i, _json) when top in [:key, :after_value],
    do: %{state | top: :done}

  defp closed(%{stack: []} = state, _c, _i, _json), do: invalid(state)

  # A top-level member's array or object value.
  defp closed(%{stack: [:object], top: :in_value, kind: :container} = state, _c, i, json),
    do: complete(state, i, json)

  defp closed(%{stack: [:array, :object], item_mark: mark} = state, ?}, i, json)
       when is_integer(mark) do
    if tasks_element?(state) do
      case Jason.decode(binary_part(json, mark, i - mark + 1)) do
        {:ok, item} when is_map(item) ->
          %{
            state
            | items: [{state.count, item, state.fields} | state.items],
              count: state.count + 1,
              item_mark: nil
          }

        _ ->
          invalid(state)
      end
    else
      state
    end
  end

  defp closed(state, _c, _i, _json), do: state

  defp colon(%{stack: [:object], top: :colon} = state), do: %{state | top: :value}
  defp colon(%{stack: stack} = state) when length(stack) < 2, do: invalid(state)
  defp colon(state), do: state

  defp comma(%{stack: [:object], top: :in_value, kind: :scalar} = state, i, json) do
    case complete(state, i - 1, json) do
      %{top: :invalid} = state -> state
      state -> %{state | top: :key}
    end
  end

  defp comma(%{stack: [:object], top: :after_value} = state, _i, _json), do: %{state | top: :key}
  defp comma(%{stack: stack} = state, _i, _json) when length(stack) < 2, do: invalid(state)
  defp comma(state, _i, _json), do: state

  defp scalar(%{stack: [:object], top: :value} = state, i),
    do: %{state | top: :in_value, kind: :scalar, mark: i}

  defp scalar(%{stack: [:object], top: :in_value, kind: :scalar} = state, _i), do: state
  defp scalar(%{stack: stack} = state, _i) when length(stack) < 2, do: invalid(state)
  defp scalar(state, _i), do: if(tasks_element?(state), do: invalid(state), else: state)

  # Decodes the current top-level member's value, which ends at byte `last`.
  defp complete(%{mark: mark, key: key} = state, last, json) do
    case Jason.decode(binary_part(json, mark, last - mark + 1)) do
      {:ok, value} ->
        fields = if key == "tasks", do: state.fields, else: Map.put(state.fields, key, value)
        %{state | fields: fields, top: :after_value, kind: nil, mark: nil}

      {:error, _reason} ->
        invalid(state)
    end
  end

  # Directly inside the top-level `tasks` array, between or at its elements.
  defp tasks_element?(%{stack: [:array, :object], key: "tasks", top: :in_value}), do: true
  defp tasks_element?(_state), do: false

  defp container(c) when c in ~c"{}", do: :object
  defp container(c) when c in ~c"[]", do: :array

  defp invalid(state), do: %{state | top: :invalid}
end
