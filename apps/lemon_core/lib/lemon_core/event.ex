defmodule LemonCore.Event do
  @moduledoc """
  Canonical event envelope used on the Bus and in persisted streams.

  ## Fields

  - `:type` - Event type as an atom (e.g., `:run_started`, `:delta`, `:completed`)
  - `:ts_ms` - Timestamp in milliseconds (monotonic wallclock)
  - `:payload` - Event-specific data
  - `:meta` - Optional metadata (should include `run_id`, `session_key`, `origin` where applicable)

  ## Examples

      iex> LemonCore.Event.new(:run_started, %{engine: "lemon"})
      %LemonCore.Event{type: :run_started, ts_ms: 1234567890, payload: %{engine: "lemon"}, meta: nil}

      iex> LemonCore.Event.new(:delta, %{text: "Hello"}, %{run_id: "abc", seq: 1})
      %LemonCore.Event{type: :delta, ts_ms: 1234567890, payload: %{text: "Hello"}, meta: %{run_id: "abc", seq: 1}}

  """

  @enforce_keys [:type, :ts_ms, :payload]
  defstruct [:type, :ts_ms, :payload, :meta]

  @type t :: %__MODULE__{
          type: atom(),
          ts_ms: non_neg_integer(),
          payload: term(),
          meta: map() | nil
        }

  @type engine_reasoning_attrs :: %{
          required(:run_id) => String.t(),
          required(:session_key) => String.t(),
          required(:text) => String.t(),
          optional(:source) => String.t(),
          optional(:phase) => String.t() | atom(),
          optional(:visibility) => atom() | String.t(),
          optional(:engine) => String.t(),
          optional(:action_id) => String.t(),
          optional(:parent_run_id) => String.t(),
          optional(:agent_id) => String.t(),
          optional(:task_id) => String.t()
        }

  @doc """
  Returns the current time in milliseconds.
  """
  @spec now_ms() :: non_neg_integer()
  def now_ms do
    System.system_time(:millisecond)
  end

  @doc """
  Creates a new event with the current timestamp.

  ## Parameters

  - `type` - The event type atom
  - `payload` - Event-specific payload data
  - `meta` - Optional metadata map (default: nil)

  ## Examples

      iex> event = LemonCore.Event.new(:run_started, %{engine: "lemon"})
      iex> event.type
      :run_started

  """
  @spec new(type :: atom(), payload :: term(), meta :: map() | nil) :: t()
  def new(type, payload, meta \\ nil) do
    %__MODULE__{
      type: type,
      ts_ms: now_ms(),
      payload: payload,
      meta: meta
    }
  end

  @doc """
  Creates a new event with a specific timestamp.
  """
  @spec new_with_ts(
          type :: atom(),
          ts_ms :: non_neg_integer(),
          payload :: term(),
          meta :: map() | nil
        ) :: t()
  def new_with_ts(type, ts_ms, payload, meta \\ nil) do
    %__MODULE__{
      type: type,
      ts_ms: ts_ms,
      payload: payload,
      meta: meta
    }
  end

  @doc """
  Adds authoritative run identity. Sequence is scoped to the run attempt:
  1 is start, 2 is durable completion, and 3 is an owner-failure notice.
  A run removed before execution can have no start. Session replay has its
  own independent cursor sequence.
  """
  def identify_run(%__MODULE__{type: type, meta: meta} = event, run_id, attempt_id \\ nil)
      when is_binary(run_id) and type in [:run_started, :run_completed, :run_failed] do
    meta = meta || %{}
    attempt_id = attempt_id || meta[:attempt_id] || "#{run_id}:attempt:1"
    seq = %{run_started: 1, run_completed: 2, run_failed: 3}[type]

    %{
      event
      | meta:
          Map.merge(meta, %{
            schema_version: 1,
            event_id: "run:#{byte_size(run_id)}:#{run_id}:#{attempt_id}:#{seq}",
            run_id: run_id,
            attempt_id: attempt_id,
            seq: seq
          })
    }
  end

  @doc """
  Decodes a lifecycle envelope at a package or JSON boundary. Unversioned
  envelopes are accepted as legacy and assigned the default attempt identity.
  Versioned identities are checked, not silently reminted.
  """
  @spec decode_run_lifecycle(map()) :: {:ok, t()} | {:error, term()}
  def decode_run_lifecycle(value) when is_map(value) do
    version = lifecycle_field(lifecycle_field(value, :meta) || %{}, :schema_version)

    if version in [nil, 1],
      do: decode_run(value, version),
      else: {:error, {:unsupported_schema_version, version}}
  end

  def decode_run_lifecycle(_), do: {:error, :invalid_run_lifecycle}

  defp decode_run(value, version) do
    meta = lifecycle_field(value, :meta) || %{}
    payload = lifecycle_field(value, :payload)

    with type when not is_nil(type) <- lifecycle_type(lifecycle_field(value, :type)),
         ts when is_integer(ts) and ts >= 0 <- lifecycle_field(value, :ts_ms),
         true <- is_map(payload),
         completed <- lifecycle_field(payload, :completed) || %{},
         run_id when is_binary(run_id) and run_id != "" <-
           lifecycle_field(meta, :run_id) || lifecycle_field(payload, :run_id) ||
             lifecycle_field(completed, :run_id),
         attempt when is_nil(attempt) or is_binary(attempt) <- lifecycle_field(meta, :attempt_id) do
      session_key =
        lifecycle_field(meta, :session_key) || lifecycle_field(payload, :session_key) ||
          lifecycle_field(completed, :session_key)

      event =
        new_with_ts(type, ts, LemonCore.Events.coerce(type, payload), %{session_key: session_key})

      event = identify_run(event, run_id, attempt)

      if is_nil(version) or
           (is_binary(attempt) and attempt != "" and
              lifecycle_field(meta, :event_id) == event.meta.event_id and
              lifecycle_field(meta, :seq) == event.meta.seq) do
        {:ok, event}
      else
        {:error, :invalid_run_identity}
      end
    else
      _ -> {:error, :invalid_run_lifecycle}
    end
  end

  defp lifecycle_type(type) when type in [:run_started, :run_completed, :run_failed], do: type
  defp lifecycle_type("run_started"), do: :run_started
  defp lifecycle_type("run_completed"), do: :run_completed
  defp lifecycle_type("run_failed"), do: :run_failed
  defp lifecycle_type(_), do: nil

  defp lifecycle_field(map, key) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp lifecycle_field(_, _), do: nil

  @doc """
  Builds a validated engine action event for run-status surfaces.
  """
  @spec engine_action(map(), map()) :: t()
  def engine_action(payload, meta) when is_map(payload) and is_map(meta) do
    validate_action_payload!(payload)
    new(:engine_action, payload, meta)
  end

  @doc """
  Builds a validated reasoning engine-action event for operator/status surfaces.
  """
  @spec engine_reasoning(engine_reasoning_attrs() | map()) :: t()
  def engine_reasoning(attrs) when is_map(attrs) do
    run_id = fetch_reasoning_value(attrs, :run_id)
    session_key = fetch_reasoning_value(attrs, :session_key)
    text = fetch_reasoning_value(attrs, :text)

    unless is_binary(text) and String.trim(text) != "" do
      raise ArgumentError, "engine_reasoning requires non-empty text"
    end

    unless is_binary(run_id) and run_id != "" do
      raise ArgumentError, "engine_reasoning requires run_id"
    end

    unless is_binary(session_key) and session_key != "" do
      raise ArgumentError, "engine_reasoning requires session_key"
    end

    source = normalize_reasoning_string(fetch_reasoning_value(attrs, :source), "unknown")
    phase = normalize_reasoning_string(fetch_reasoning_value(attrs, :phase), "updated")
    visibility = fetch_reasoning_value(attrs, :visibility) || :operator
    action_id = fetch_reasoning_value(attrs, :action_id) || stable_reasoning_action_id(attrs)

    payload = %{
      engine: fetch_reasoning_value(attrs, :engine),
      phase: normalize_action_phase(phase),
      ok: normalize_reasoning_ok(phase),
      message: nil,
      level: nil,
      action: %{
        id: action_id,
        kind: "reasoning",
        title: text,
        detail: %{reasoning: %{text: text, source: source, phase: phase}}
      }
    }

    meta =
      %{
        run_id: run_id,
        session_key: session_key,
        visibility: visibility
      }
      |> maybe_put(:parent_run_id, fetch_reasoning_value(attrs, :parent_run_id))
      |> maybe_put(:agent_id, fetch_reasoning_value(attrs, :agent_id))
      |> maybe_put(:task_id, fetch_reasoning_value(attrs, :task_id))

    engine_action(payload, meta)
  end

  defp validate_action_payload!(%{action: action}) when is_map(action) do
    id = Map.get(action, :id) || Map.get(action, "id")
    kind = Map.get(action, :kind) || Map.get(action, "kind")
    title = Map.get(action, :title) || Map.get(action, "title")

    unless is_binary(id) and id != "" do
      raise ArgumentError, "engine_action requires action.id"
    end

    unless kind in [
             "tool",
             "command",
             "file_change",
             "web_search",
             "subagent",
             "reasoning",
             :tool,
             :command,
             :file_change,
             :web_search,
             :subagent,
             :reasoning,
             :note,
             "note"
           ] do
      raise ArgumentError, "engine_action has invalid action.kind"
    end

    unless is_binary(title) do
      raise ArgumentError, "engine_action requires action.title"
    end

    :ok
  end

  defp validate_action_payload!(_payload) do
    raise ArgumentError, "engine_action requires action payload"
  end

  defp fetch_reasoning_value(map, key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp normalize_reasoning_string(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp normalize_reasoning_string(value, _default) when is_atom(value), do: Atom.to_string(value)
  defp normalize_reasoning_string(_value, default), do: default

  defp normalize_action_phase("started"), do: :started
  defp normalize_action_phase("updated"), do: :updated
  defp normalize_action_phase("completed"), do: :completed
  defp normalize_action_phase(_), do: :updated

  defp normalize_reasoning_ok("completed"), do: true
  defp normalize_reasoning_ok(_), do: nil

  defp stable_reasoning_action_id(attrs) do
    run_id = fetch_reasoning_value(attrs, :run_id)
    source = normalize_reasoning_string(fetch_reasoning_value(attrs, :source), "unknown")
    phase = normalize_reasoning_string(fetch_reasoning_value(attrs, :phase), "updated")
    text = fetch_reasoning_value(attrs, :text)

    digest =
      :crypto.hash(:sha256, "#{source}:#{phase}:#{text}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "reasoning:#{run_id}:#{digest}"
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
