defmodule LemonSim.State do
  @moduledoc """
  Persistent simulation state used to construct fresh decision context.
  """

  alias LemonSim.{Event, PlanStep}

  @enforce_keys [:sim_id, :world]
  defstruct sim_id: "",
            version: 0,
            world: %{},
            recent_events: [],
            intent: nil,
            plan_history: [],
            memory_index_path: "index.md",
            meta: %{}

  @type t :: %__MODULE__{
          sim_id: String.t(),
          version: non_neg_integer(),
          world: map(),
          recent_events: [Event.t()],
          intent: map() | nil,
          plan_history: [PlanStep.t() | map()],
          memory_index_path: String.t(),
          meta: map()
        }

  @doc """
  Builds a state struct from atom-key or string-key input.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs), do: attrs |> Enum.into(%{}) |> new()

  def new(attrs) when is_map(attrs) do
    sim_id =
      attrs
      |> fetch_required(:sim_id, "sim_id")
      |> to_string()

    %__MODULE__{
      sim_id: sim_id,
      version: fetch(attrs, :version, "version", 0),
      world: fetch(attrs, :world, "world", %{}),
      recent_events:
        attrs |> fetch(:recent_events, "recent_events", []) |> Enum.map(&Event.new/1),
      intent: fetch(attrs, :intent, "intent", nil),
      plan_history: fetch(attrs, :plan_history, "plan_history", []),
      memory_index_path: fetch(attrs, :memory_index_path, "memory_index_path", "index.md"),
      meta: fetch(attrs, :meta, "meta", %{})
    }
  end

  @doc """
  Appends one event and keeps the recent event window bounded.
  """
  @spec append_event(t(), Event.t() | map()) :: t()
  def append_event(%__MODULE__{} = state, event) do
    append_event(state, event, 25)
  end

  @doc """
  Appends one event and keeps the recent event window bounded.
  """
  @spec append_event(t(), Event.t() | map(), pos_integer()) :: t()
  def append_event(%__MODULE__{} = state, event, max_events)
      when is_integer(max_events) and max_events > 0 do
    events =
      (state.recent_events ++ [Event.new(event)])
      |> Enum.take(-max_events)

    %{state | recent_events: events, version: state.version + 1}
  end

  @spec append_event(t(), Event.kind(), map() | keyword()) :: t()
  def append_event(%__MODULE__{} = state, kind, payload)
      when (is_atom(kind) or is_binary(kind)) and (is_map(payload) or is_list(payload)) do
    append_event(state, Event.new(kind, payload))
  end

  @doc """
  Appends an event using a `kind`, `payload`, and `meta`.
  """
  @spec append_event(t(), Event.kind(), map() | keyword(), map() | keyword()) :: t()
  def append_event(%__MODULE__{} = state, kind, payload, meta)
      when (is_atom(kind) or is_binary(kind)) and (is_map(payload) or is_list(payload)) and
             (is_map(meta) or is_list(meta)) do
    append_event(state, Event.new(kind, payload, meta))
  end

  @doc """
  Appends an event using a `kind`, `payload`, `meta`, and bounded window size.
  """
  @spec append_event(t(), Event.kind(), map() | keyword(), map() | keyword(), pos_integer()) ::
          t()
  def append_event(%__MODULE__{} = state, kind, payload, meta, max_events)
      when (is_atom(kind) or is_binary(kind)) and (is_map(payload) or is_list(payload)) and
             (is_map(meta) or is_list(meta)) and is_integer(max_events) and max_events > 0 do
    append_event(state, Event.new(kind, payload, meta), max_events)
  end

  @doc """
  Appends multiple events in order while preserving the bounded event window.
  """
  @spec append_events(t(), [Event.t() | map()]) :: t()
  def append_events(%__MODULE__{} = state, events) when is_list(events) do
    append_events(state, events, 25)
  end

  @doc """
  Appends multiple events in order while preserving the bounded event window.
  """
  @spec append_events(t(), [Event.t() | map()], pos_integer()) :: t()
  def append_events(%__MODULE__{} = state, events, max_events)
      when is_list(events) and is_integer(max_events) and max_events > 0 do
    Enum.reduce(events, state, fn event, acc -> append_event(acc, event, max_events) end)
  end

  @doc """
  Shallow-merges fields into the world state.
  """
  @spec put_world(t(), map() | keyword()) :: t()
  def put_world(%__MODULE__{} = state, updates) when is_list(updates) do
    put_world(state, Enum.into(updates, %{}))
  end

  def put_world(%__MODULE__{} = state, updates) when is_map(updates) do
    %{state | world: Map.merge(state.world, updates)}
  end

  @doc """
  Applies a transformation to the current world state.
  """
  @spec update_world(t(), (map() -> map())) :: t()
  def update_world(%__MODULE__{} = state, updater) when is_function(updater, 1) do
    %{state | world: updater.(state.world)}
  end

  @doc """
  Appends a compact plan step.
  """
  @spec append_plan_step(t(), PlanStep.t() | map(), pos_integer()) :: t()
  def append_plan_step(%__MODULE__{} = state, step, max_steps \\ 50)
      when is_integer(max_steps) and max_steps > 0 do
    normalized =
      case step do
        %PlanStep{} = value ->
          value

        %{} = value ->
          PlanStep.new(fetch(value, :summary, "summary", ""))
          |> Map.merge(%{
            ts_ms: fetch(value, :ts_ms, "ts_ms", System.system_time(:millisecond)),
            rationale: fetch(value, :rationale, "rationale", nil),
            meta: fetch(value, :meta, "meta", %{})
          })
      end

    history =
      (state.plan_history ++ [normalized])
      |> Enum.take(-max_steps)

    %{state | plan_history: history}
  end

  defp fetch(map, atom_key, string_key, default) do
    map
    |> Map.get(atom_key, Map.get(map, string_key, default))
  end

  defp fetch_required(map, atom_key, string_key) do
    case fetch(map, atom_key, string_key, nil) do
      nil -> raise ArgumentError, "missing required key #{inspect(atom_key)}"
      value -> value
    end
  end
end
