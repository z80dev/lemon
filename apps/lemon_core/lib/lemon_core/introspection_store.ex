defmodule LemonCore.IntrospectionStore do
  @moduledoc """
  Canonical introspection events, newest first, kept for a retention window.

  Owns the `:introspection_log` table, keyed by `{ts_ms, event_id}`. `append/2`
  validates and normalizes an event before writing it asynchronously, so a
  malformed event is refused immediately without a round trip to the store.
  `list/2` filters by run, session, agent, event type and time range, newest
  first, and pushes the ordered page into the backend when no field filter is
  set and the backend can do that (`LemonCore.Store.list_recent/3`).

  Events older than #{7} days are removed by the store's sweep.
  """

  use LemonCore.Store.Table,
    tables: [
      introspection_log: [
        retention: [max_age_ms: 7 * 24 * 60 * 60 * 1000, timestamp: {__MODULE__, :timestamp_ms}]
      ]
    ]

  alias LemonCore.{MapHelpers, Store}

  @table :introspection_log
  @default_limit 100
  @max_limit 1_000
  @provenances [:direct, :inferred, :unavailable]

  @type event :: %{
          required(:event_id) => binary(),
          required(:event_type) => atom() | binary(),
          required(:ts_ms) => pos_integer(),
          required(:run_id) => binary() | nil,
          required(:session_key) => binary() | nil,
          required(:agent_id) => binary() | nil,
          required(:parent_run_id) => binary() | nil,
          required(:engine) => binary() | nil,
          required(:provenance) => :direct | :inferred | :unavailable,
          required(:payload) => map()
        }

  @doc """
  Append a canonical introspection event.

  Requires a non-empty `event_id`, a positive `ts_ms`, an atom or non-empty
  string `event_type`, a map `payload` and a known `provenance` (default
  `:direct`); keys may be atoms or strings. Asynchronous once accepted.
  """
  @spec append(Store.server(), map()) :: :ok | {:error, :invalid_introspection_event}
  def append(server \\ Store, event) do
    case normalize(event) do
      {:ok, normalized} ->
        Store.put_async(server, @table, {normalized.ts_ms, normalized.event_id}, normalized)

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  List introspection events, newest first.

  ## Options

    * `:run_id`, `:session_key`, `:agent_id` — exact matches
    * `:event_type` — one type, or a list of accepted types
    * `:since_ms`, `:until_ms` — inclusive bounds on `ts_ms`
    * `:limit` — at most this many events (default #{@default_limit}, at most #{@max_limit})
  """
  @spec list(keyword()) :: [event()]
  def list(opts \\ []) when is_list(opts), do: list(Store, opts)

  @spec list(Store.server(), keyword()) :: [event()]
  def list(server, opts) when is_list(opts) do
    limit = normalize_limit(Keyword.get(opts, :limit, @default_limit))

    server
    |> entries(opts, limit)
    |> Enum.map(fn {_key, event} -> event end)
    |> Enum.filter(&matches?(&1, opts))
    |> Enum.sort_by(&sort_key/1, :desc)
    |> Enum.take(limit)
  end

  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) when is_list(opts), do: opts |> list() |> length()

  @doc false
  # The retention timestamp: from the key when it has the canonical shape,
  # else from the event itself.
  @spec timestamp_ms(term(), term()) :: integer() | nil
  def timestamp_ms({ts_ms, _event_id}, _event) when is_integer(ts_ms), do: ts_ms

  def timestamp_ms(_key, event) when is_map(event) do
    case MapHelpers.get_key(event, :ts_ms) do
      ts when is_integer(ts) -> ts
      _ -> nil
    end
  end

  def timestamp_ms(_key, _event), do: nil

  # Without field filters the backend can hand back the newest `limit` rows
  # itself; a backend that cannot, or a filtered query, reads the table.
  defp entries(server, opts, limit) do
    if field_filters?(opts) do
      Store.list(server, @table)
    else
      case Store.list_recent(server, @table, limit) do
        {:ok, entries} -> entries
        {:error, _unsupported_or_unavailable} -> Store.list(server, @table)
      end
    end
  end

  defp normalize(event) when is_map(event) do
    event_id = MapHelpers.get_key(event, :event_id)
    ts_ms = MapHelpers.get_key(event, :ts_ms)
    event_type = MapHelpers.get_key(event, :event_type)
    payload = MapHelpers.get_key(event, :payload) || %{}
    provenance = MapHelpers.get_key(event, :provenance) || :direct

    with true <- is_binary(event_id) and event_id != "",
         true <- is_integer(ts_ms) and ts_ms > 0,
         true <- valid_event_type?(event_type),
         true <- provenance in @provenances,
         true <- is_map(payload) do
      {:ok,
       %{
         event_id: event_id,
         event_type: event_type,
         ts_ms: ts_ms,
         run_id: optional_binary(MapHelpers.get_key(event, :run_id)),
         session_key: optional_binary(MapHelpers.get_key(event, :session_key)),
         agent_id: optional_binary(MapHelpers.get_key(event, :agent_id)),
         parent_run_id: optional_binary(MapHelpers.get_key(event, :parent_run_id)),
         engine: optional_binary(MapHelpers.get_key(event, :engine)),
         provenance: provenance,
         payload: payload
       }}
    else
      _ -> {:error, :invalid_introspection_event}
    end
  end

  defp normalize(_event), do: {:error, :invalid_introspection_event}

  defp valid_event_type?(value) when is_atom(value), do: not is_nil(value)
  defp valid_event_type?(value) when is_binary(value), do: value != ""
  defp valid_event_type?(_value), do: false

  defp optional_binary(value) when is_binary(value) and value != "", do: value
  defp optional_binary(_value), do: nil

  defp field_filters?(opts) do
    Enum.any?(
      [:run_id, :session_key, :agent_id, :event_type, :since_ms, :until_ms],
      &(Keyword.get(opts, &1) != nil)
    )
  end

  defp matches?(event, opts) do
    optional_binary_match?(Keyword.get(opts, :run_id), MapHelpers.get_key(event, :run_id)) and
      optional_binary_match?(
        Keyword.get(opts, :session_key),
        MapHelpers.get_key(event, :session_key)
      ) and
      optional_binary_match?(Keyword.get(opts, :agent_id), MapHelpers.get_key(event, :agent_id)) and
      event_type_match?(Keyword.get(opts, :event_type), MapHelpers.get_key(event, :event_type)) and
      in_range?(
        MapHelpers.get_key(event, :ts_ms),
        Keyword.get(opts, :since_ms),
        Keyword.get(opts, :until_ms)
      )
  end

  defp optional_binary_match?(nil, _actual), do: true
  defp optional_binary_match?(expected, actual) when is_binary(expected), do: expected == actual
  defp optional_binary_match?(_expected, _actual), do: false

  defp event_type_match?(nil, _actual), do: true

  defp event_type_match?(expected, actual) when is_list(expected) do
    Enum.any?(expected, &event_type_equal?(&1, actual))
  end

  defp event_type_match?(expected, actual), do: event_type_equal?(expected, actual)

  defp event_type_equal?(expected, actual) when is_atom(expected) and is_atom(actual),
    do: expected == actual

  defp event_type_equal?(expected, actual) when is_binary(expected) and is_binary(actual),
    do: expected == actual

  defp event_type_equal?(expected, actual) when is_atom(expected) and is_binary(actual),
    do: Atom.to_string(expected) == actual

  defp event_type_equal?(expected, actual) when is_binary(expected) and is_atom(actual),
    do: expected == Atom.to_string(actual)

  defp event_type_equal?(_expected, _actual), do: false

  defp in_range?(ts_ms, since_ms, until_ms) when is_integer(ts_ms) do
    (is_nil(since_ms) or (is_integer(since_ms) and ts_ms >= since_ms)) and
      (is_nil(until_ms) or (is_integer(until_ms) and ts_ms <= until_ms))
  end

  defp in_range?(_ts_ms, _since_ms, _until_ms), do: false

  defp sort_key(event) do
    ts_ms =
      case MapHelpers.get_key(event, :ts_ms) do
        ts when is_integer(ts) -> ts
        _ -> 0
      end

    event_id =
      case MapHelpers.get_key(event, :event_id) do
        id when is_binary(id) -> id
        _ -> ""
      end

    {ts_ms, event_id}
  end

  defp normalize_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_limit)
  defp normalize_limit(_limit), do: @default_limit
end
