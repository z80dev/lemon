defmodule LemonSim.Event do
  @moduledoc """
  Canonical simulation event envelope.
  """

  @enforce_keys [:kind, :ts_ms]
  defstruct [:kind, :ts_ms, payload: %{}, meta: %{}]

  @type kind :: atom() | String.t()

  @type t :: %__MODULE__{
          kind: kind(),
          ts_ms: non_neg_integer(),
          payload: map(),
          meta: map()
        }

  @doc """
  Builds a normalized event from a map/keyword/struct.
  """
  @spec new(t() | map() | keyword()) :: t()
  def new(%__MODULE__{} = event), do: event

  def new(attrs) when is_list(attrs), do: attrs |> Enum.into(%{}) |> new()

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      kind: fetch(attrs, :kind, "kind", :event),
      ts_ms: fetch(attrs, :ts_ms, "ts_ms", System.system_time(:millisecond)),
      payload: fetch(attrs, :payload, "payload", %{}),
      meta: fetch(attrs, :meta, "meta", %{})
    }
  end

  @doc """
  Builds a new event from a kind and payload.
  """
  @spec new(kind(), map() | keyword()) :: t()
  def new(kind, payload)
      when (is_atom(kind) or is_binary(kind)) and (is_map(payload) or is_list(payload)) do
    new(kind, payload, %{})
  end

  @doc """
  Builds a new event from a kind, payload, and metadata.
  """
  @spec new(kind(), map() | keyword(), map() | keyword()) :: t()
  def new(kind, payload, meta)
      when (is_atom(kind) or is_binary(kind)) and (is_map(payload) or is_list(payload)) and
             (is_map(meta) or is_list(meta)) do
    %__MODULE__{
      kind: kind,
      ts_ms: System.system_time(:millisecond),
      payload: normalize_map(payload),
      meta: normalize_map(meta)
    }
  end

  defp fetch(map, atom_key, string_key, default) do
    map
    |> Map.get(atom_key, Map.get(map, string_key, default))
  end

  defp normalize_map(value) when is_list(value), do: Enum.into(value, %{})
  defp normalize_map(value) when is_map(value), do: value
end
