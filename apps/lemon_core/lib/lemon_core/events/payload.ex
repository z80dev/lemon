defmodule LemonCore.Events.Payload do
  @moduledoc """
  Shared scaffolding for typed `LemonCore.Bus` payloads.

  A payload module declares its event type and fields; this macro supplies the struct,
  the strict constructor publishers use, the lenient constructor consumers use on legacy
  maps, and — for one deprecation cycle — an `Access` implementation.

      defmodule LemonCore.Events.SecretChanged do
        use LemonCore.Events.Payload,
          type: :secret_changed,
          enforce: [:owner, :name, :action],
          fields: [owner: nil, name: nil, action: nil]
      end

  ## Why `Access`

  Payloads were free-form maps until Phase 3.1, and consumers read them with `payload[:key]`.
  `Access` is not implemented for structs, so without this shim every consumer of a topic
  would have to change in the same commit as its publisher. The shim lets publishers migrate
  one at a time. It is temporary: see `docs/platform/bus-events.md` §4.3.

  ## Callbacks each payload module gets

  - `event_type/0` — the atom used as `LemonCore.Event.type`
  - `event_version/0` — bumped only on a breaking field change
  - `new/1` — strict: raises on unknown keys or missing enforced keys. For publishers.
  - `from_map/1` — lenient: drops unknown keys, accepts string keys, passes structs through.
    For consumers reading a payload that may predate the struct.
  """

  @doc false
  defmacro __using__(opts) do
    type = Keyword.fetch!(opts, :type)
    fields = Keyword.fetch!(opts, :fields)
    enforce = Keyword.get(opts, :enforce, [])
    version = Keyword.get(opts, :version, 1)

    quote bind_quoted: [type: type, fields: fields, enforce: enforce, version: version] do
      @behaviour Access

      # Payloads are persisted by the JSONL store backend and rendered by the control
      # plane, both of which encode with Jason. Deriving keeps a struct payload as
      # encodable as the map it replaces.
      @derive Jason.Encoder
      @enforce_keys enforce
      defstruct fields

      @event_type type
      @event_version version
      @event_fields Keyword.keys(fields)

      @doc "The `LemonCore.Event` type atom this payload is published under."
      @spec event_type() :: atom()
      def event_type, do: @event_type

      @doc "Payload version. Bumped only for a breaking field change (see the semver table in docs/platform/bus-events.md §4.3)."
      @spec event_version() :: pos_integer()
      def event_version, do: @event_version

      @doc "The struct's field names, in declaration order."
      @spec fields() :: [atom()]
      def fields, do: @event_fields

      @doc """
      Build the payload, raising on unknown or missing keys.

      This is the publisher-side constructor: a typo should fail at the point of publish,
      not silently produce a payload with a nil field that a consumer reads as absent.
      """
      @spec new(map() | keyword()) :: struct()
      def new(%__MODULE__{} = payload), do: payload

      def new(attrs) when is_map(attrs) or is_list(attrs) do
        attrs = Map.new(attrs)

        case Map.keys(attrs) -- @event_fields do
          [] ->
            struct!(__MODULE__, attrs)

          unknown ->
            raise ArgumentError, "unknown #{inspect(__MODULE__)} fields: #{inspect(unknown)}"
        end
      end

      @doc """
      Build the payload from a map that may be a legacy free-form payload.

      Unknown keys are dropped and string keys are accepted, so a consumer can coerce
      whatever arrives on the topic. Enforced keys are still required — a map missing them
      is not a valid payload under any version.
      """
      @spec from_map(map() | struct() | keyword()) :: struct()
      def from_map(%__MODULE__{} = payload), do: payload

      def from_map(attrs) when is_map(attrs) or is_list(attrs) do
        attrs
        |> Map.new()
        |> Enum.reduce(%{}, fn {key, value}, acc ->
          case LemonCore.Events.Payload.normalize_key(key, @event_fields) do
            {:ok, field} -> Map.put(acc, field, value)
            :error -> acc
          end
        end)
        |> then(&struct!(__MODULE__, &1))
      end

      @doc false
      @deprecated "Pattern-match the struct or use Map.get/2. Access on Events payloads is removed in the next major; see docs/platform/bus-events.md §4.3."
      @impl Access
      def fetch(payload, key), do: Map.fetch(Map.from_struct(payload), key)

      @doc false
      @deprecated "Pattern-match the struct or use Map.get/2. Access on Events payloads is removed in the next major; see docs/platform/bus-events.md §4.3."
      @impl Access
      def get_and_update(payload, key, fun) when key in @event_fields do
        {get, update} =
          case fun.(Map.get(payload, key)) do
            :pop -> {Map.get(payload, key), nil}
            {get, update} -> {get, update}
          end

        {get, Map.put(payload, key, update)}
      end

      @doc false
      @deprecated "Pattern-match the struct or use Map.get/2. Access on Events payloads is removed in the next major; see docs/platform/bus-events.md §4.3."
      @impl Access
      def pop(payload, key) when key in @event_fields do
        {Map.get(payload, key), Map.put(payload, key, nil)}
      end

      def pop(payload, _key), do: {nil, payload}

      # Payloads with a nested payload field (or an enum to normalize) redefine `from_map/1`.
      # Without this, the generic clause above would win — it is defined first and matches any
      # map — and a nested value would silently stay a raw map instead of becoming its struct.
      defoverridable from_map: 1, new: 1
    end
  end

  @doc false
  @spec normalize_key(atom() | binary(), [atom()]) :: {:ok, atom()} | :error
  def normalize_key(key, fields) when is_atom(key) do
    if key in fields, do: {:ok, key}, else: :error
  end

  def normalize_key(key, fields) when is_binary(key) do
    Enum.find_value(fields, :error, fn field ->
      if Atom.to_string(field) == key, do: {:ok, field}
    end)
  end

  def normalize_key(_key, _fields), do: :error
end
