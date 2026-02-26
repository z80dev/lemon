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
  @spec new_with_ts(type :: atom(), ts_ms :: non_neg_integer(), payload :: term(), meta :: map() | nil) :: t()
  def new_with_ts(type, ts_ms, payload, meta \\ nil) do
    %__MODULE__{
      type: type,
      ts_ms: ts_ms,
      payload: payload,
      meta: meta
    }
  end
end
