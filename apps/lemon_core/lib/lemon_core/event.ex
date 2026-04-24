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
  Builds a validated engine action event for run-status surfaces.
  """
  @spec engine_action(map(), map()) :: t()
  def engine_action(payload, meta) when is_map(payload) and is_map(meta) do
    validate_action_payload!(payload)
    new(:engine_action, payload, meta)
  end

  @doc """
  Builds a validated reasoning-status event.
  """
  @spec reasoning_status(map(), map()) :: t()
  def reasoning_status(reasoning, meta) when is_map(reasoning) and is_map(meta) do
    text = Map.get(reasoning, :text) || Map.get(reasoning, "text")

    unless is_binary(text) and String.trim(text) != "" do
      raise ArgumentError, "reasoning_status requires non-empty text"
    end

    new(:reasoning_status, normalize_reasoning(reasoning), meta)
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

  defp normalize_reasoning(reasoning) do
    %{
      text: Map.get(reasoning, :text) || Map.get(reasoning, "text"),
      source: Map.get(reasoning, :source) || Map.get(reasoning, "source") || "unknown",
      phase: Map.get(reasoning, :phase) || Map.get(reasoning, "phase") || "updated"
    }
  end
end
