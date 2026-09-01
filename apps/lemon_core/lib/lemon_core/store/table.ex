defmodule LemonCore.Store.Table do
  @moduledoc """
  A table declaration: the one place a `LemonCore.Store` table is named,
  described and given its storage policy.

  A domain module declares the tables it owns:

      defmodule LemonAutomation.CronStore do
        use LemonCore.Store.Table,
          tables: [
            cron_jobs: [],
            cron_runs: [retention: [max_age_ms: :timer.hours(48), timestamp: :started_at_ms]]
          ]
      end

  and registers them with the store its application uses, normally at boot:

      LemonCore.Store.Table.register(LemonAutomation.CronStore)

  Declaring a table says who owns it and how the store should treat it; it
  generates no accessors. The owning module writes the storage calls it needs
  (`LemonCore.Store.put/4`, `fetch/3`, `update/5`, ...): the domain owns
  meaning, validation, defaults and compatibility with older values, the
  store owns backend access, atomic operations and cache coherence. Only an
  owning module names its table in a generic store call; `mix lemon.quality`
  counts the tables named anywhere else.

  ## Options per table

    * `:cached` — mirror the table into the store's read cache
      (`LemonCore.Store.ReadCache`) so reads skip the store process. Default
      `false`.
    * `:retention` — expire entries during the store's periodic sweep. Either
      `[expires_at: field]` for an absolute expiry stored in the value, or
      `[max_age_ms: ms, timestamp: field | {module, function}]` for an age
      measured from a timestamp. A `field` is looked up in map values under
      the atom and its string form; `{module, function}` is called with the
      key and the value and returns milliseconds or `nil`. Entries without a
      usable timestamp are kept.
    * `:persistence` — `:durable` (default) or `:ephemeral`, a hint a backend
      may honour by keeping the table in memory. The SQLite backend does.
    * `:version` — an integer recorded with the declaration for the owner's
      own schema evolution. The store does not migrate values; the owner reads
      the shapes it has written before.

  ## Ownership

  Registrations are kept per store instance. A table registered by one module
  cannot be registered by another; re-registering it from the same module
  (an application restart) replaces the declaration.
  """

  alias LemonCore.Contract

  @type retention ::
          [expires_at: atom()]
          | [max_age_ms: pos_integer(), timestamp: atom() | {module(), atom()}]

  @type t :: %__MODULE__{
          name: atom(),
          owner: module(),
          cached: boolean(),
          retention: retention() | nil,
          persistence: :durable | :ephemeral,
          version: pos_integer()
        }

  @enforce_keys [:name, :owner]
  defstruct name: nil,
            owner: nil,
            cached: false,
            retention: nil,
            persistence: :durable,
            version: 1

  @doc "The tables a module declares with `use LemonCore.Store.Table`."
  @callback __store_tables__() :: [t()]

  @options [:cached, :retention, :persistence, :version]

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour LemonCore.Store.Table

      @store_tables LemonCore.Store.Table.declare!(__MODULE__, Keyword.fetch!(opts, :tables))

      @doc false
      @impl LemonCore.Store.Table
      def __store_tables__, do: @store_tables
    end
  end

  @doc """
  Builds the declarations for `owner` from the `use` options.

  Raises `ArgumentError` on an option the store cannot honour, so a bad
  declaration fails at compile time rather than at the first sweep.
  """
  @spec declare!(module(), keyword()) :: [t()]
  def declare!(owner, tables) when is_atom(owner) and is_list(tables) do
    if tables == [] do
      raise ArgumentError, "#{inspect(owner)} declares no tables"
    end

    Enum.map(tables, fn
      {name, opts} when is_atom(name) and not is_nil(name) and is_list(opts) ->
        build!(owner, name, opts)

      other ->
        raise ArgumentError,
              "#{inspect(owner)}: a table is declared as `name: options`, got #{inspect(other)}"
    end)
  end

  defp build!(owner, name, opts) do
    case Keyword.keys(opts) -- @options do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, "#{inspect(owner)}.#{name}: unknown options #{inspect(unknown)}"
    end

    %__MODULE__{
      name: name,
      owner: owner,
      cached: boolean!(owner, name, :cached, Keyword.get(opts, :cached, false)),
      retention: retention!(owner, name, Keyword.get(opts, :retention)),
      persistence: persistence!(owner, name, Keyword.get(opts, :persistence, :durable)),
      version: version!(owner, name, Keyword.get(opts, :version, 1))
    }
  end

  defp boolean!(_owner, _name, _key, value) when is_boolean(value), do: value

  defp boolean!(owner, name, key, value) do
    raise ArgumentError,
          "#{inspect(owner)}.#{name}: #{key} must be a boolean, got #{inspect(value)}"
  end

  defp retention!(_owner, _name, nil), do: nil

  defp retention!(owner, name, expires_at: field) when is_atom(field) or is_binary(field) do
    _ = owner
    _ = name
    [expires_at: field_atom(field)]
  end

  defp retention!(owner, name, retention) when is_list(retention) do
    max_age_ms = Keyword.get(retention, :max_age_ms)
    timestamp = Keyword.get(retention, :timestamp)

    unless is_integer(max_age_ms) and max_age_ms > 0 do
      raise ArgumentError,
            "#{inspect(owner)}.#{name}: retention needs a positive :max_age_ms, got #{inspect(retention)}"
    end

    timestamp =
      case timestamp do
        field when is_atom(field) and not is_nil(field) ->
          field_atom(field)

        field when is_binary(field) ->
          field_atom(field)

        {module, function} when is_atom(module) and is_atom(function) ->
          {module, function}

        other ->
          raise ArgumentError,
                "#{inspect(owner)}.#{name}: retention :timestamp must be a field or {module, function}, got #{inspect(other)}"
      end

    [max_age_ms: max_age_ms, timestamp: timestamp]
  end

  defp retention!(owner, name, other) do
    raise ArgumentError, "#{inspect(owner)}.#{name}: invalid retention #{inspect(other)}"
  end

  defp persistence!(_owner, _name, value) when value in [:durable, :ephemeral], do: value

  defp persistence!(owner, name, value) do
    raise ArgumentError,
          "#{inspect(owner)}.#{name}: persistence must be :durable or :ephemeral, got #{inspect(value)}"
  end

  defp version!(_owner, _name, value) when is_integer(value) and value > 0, do: value

  defp version!(owner, name, value) do
    raise ArgumentError,
          "#{inspect(owner)}.#{name}: version must be a positive integer, got #{inspect(value)}"
  end

  defp field_atom(field) when is_atom(field), do: field
  defp field_atom(field) when is_binary(field), do: String.to_atom(field)

  ## Registration

  @doc """
  Registers every table `module` declares with `store`.

  Raises `ArgumentError` when `module` declares no tables or when one of them
  is already owned by another module: both are programming errors that
  should stop the application that made them from booting.
  """
  @spec register(atom(), module()) :: :ok
  def register(store \\ LemonCore.Store, module) when is_atom(store) and is_atom(module) do
    case Contract.validate(module, __MODULE__) do
      :ok ->
        :ok

      {:error, reason} ->
        raise ArgumentError,
              "#{inspect(module)} does not declare store tables (use LemonCore.Store.Table): " <>
                inspect(reason)
    end

    Enum.each(module.__store_tables__(), fn table ->
      case LemonCore.Store.register_table(store, table) do
        :ok ->
          :ok

        {:error, reason} ->
          raise ArgumentError,
                "cannot register #{inspect(table.name)} for #{inspect(module)}: #{inspect(reason)}"
      end
    end)
  end

  @doc false
  @spec put_registration(atom(), t()) :: :ok | {:error, {:already_owned, atom(), module()}}
  def put_registration(store, %__MODULE__{} = table) when is_atom(store) do
    current = registry(store)

    case Map.get(current, table.name) do
      %__MODULE__{owner: owner} when owner != table.owner ->
        {:error, {:already_owned, table.name, owner}}

      _ ->
        :persistent_term.put(registry_key(store), Map.put(current, table.name, table))
    end
  end

  @doc "Every table registered with `store`, in registration order of their names."
  @spec registered(atom()) :: [t()]
  def registered(store \\ LemonCore.Store) when is_atom(store) do
    store |> registry() |> Map.values() |> Enum.sort_by(& &1.name)
  end

  @doc "The registration for `name` on `store`, or `nil`."
  @spec fetch(atom(), atom()) :: t() | nil
  def fetch(store \\ LemonCore.Store, name) when is_atom(store) and is_atom(name) do
    Map.get(registry(store), name)
  end

  @doc false
  @spec clear(atom()) :: :ok
  def clear(store) when is_atom(store) do
    :persistent_term.erase(registry_key(store))
    :ok
  end

  ## Retention

  @doc """
  Whether `value` stored under `key` has expired at `now_ms` according to the
  table's retention. A table without retention never expires an entry.
  """
  @spec expired?(t(), term(), term(), integer()) :: boolean()
  def expired?(%__MODULE__{retention: nil}, _key, _value, _now_ms), do: false

  def expired?(%__MODULE__{retention: [expires_at: field]}, _key, value, now_ms) do
    case field_value(value, field) do
      expires_at when is_integer(expires_at) -> now_ms > expires_at
      _ -> false
    end
  end

  def expired?(%__MODULE__{retention: retention}, key, value, now_ms) do
    max_age_ms = Keyword.fetch!(retention, :max_age_ms)

    case timestamp_ms(Keyword.fetch!(retention, :timestamp), key, value) do
      ts when is_integer(ts) -> ts < now_ms - max_age_ms
      _ -> false
    end
  end

  defp timestamp_ms({module, function}, key, value), do: apply(module, function, [key, value])
  defp timestamp_ms(field, _key, value) when is_atom(field), do: field_value(value, field)

  defp field_value(value, field) when is_map(value) and is_atom(field) do
    case Map.get(value, field) do
      nil -> Map.get(value, Atom.to_string(field))
      found -> found
    end
  end

  defp field_value(_value, _field), do: nil

  defp registry(store), do: :persistent_term.get(registry_key(store), %{})
  defp registry_key(store), do: {__MODULE__, store}
end
