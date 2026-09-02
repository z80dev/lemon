defmodule LemonCore.Store.Table do
  @moduledoc """
  Declares which generic `LemonCore.Store` tables a domain module owns.

  The declaration is metadata, not a generated repository API. Domain modules
  still define their own meaningful operations and validation:

      defmodule MyApp.WidgetStore do
        use LemonCore.Store.Table,
          tables: [widgets: [cached: true, version: 2]]

        def get(id), do: LemonCore.Store.get(:widgets, id)
      end

  `mix lemon.quality` reads the same declaration from source and verifies every
  generic Store call in an owner module. A call is exempt only when its table
  can be resolved to one of that module's declarations. Declaring `:widgets`
  therefore does not authorize access to `:accounts`.

  The policy fields are intentionally descriptive in this change. Store
  backends do not consume them yet; that runtime migration can proceed in a
  separate, behavior-changing change.

  ## Options per table

    * `:cached` - whether the table is intended for a read-cache mirror;
      defaults to `false`.
    * `:retention` - either `[expires_at: field]` or
      `[max_age_ms: milliseconds, timestamp: field | {module, function}]`.
    * `:persistence` - `:durable` (the default) or `:ephemeral`.
    * `:version` - a positive schema version owned by the domain; defaults to
      `1`.
  """

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

  @doc "The table metadata declared by a module using this behaviour."
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

  @doc "Builds and validates the table declarations for `owner`."
  @spec declare!(module(), keyword()) :: [t()]
  def declare!(owner, tables) when is_atom(owner) and is_list(tables) do
    if tables == [] do
      raise ArgumentError, "#{inspect(owner)} declares no tables"
    end

    declarations =
      Enum.map(tables, fn
        {name, opts} when is_atom(name) and not is_nil(name) and is_list(opts) ->
          build!(owner, name, opts)

        other ->
          raise ArgumentError,
                "#{inspect(owner)}: a table is declared as `name: options`, " <>
                  "got #{inspect(other)}"
      end)

    names = Enum.map(declarations, & &1.name)

    case names -- Enum.uniq(names) do
      [] ->
        declarations

      duplicates ->
        raise ArgumentError,
              "#{inspect(owner)} declares duplicate tables #{inspect(Enum.uniq(duplicates))}"
    end
  end

  defp build!(owner, name, opts) do
    keys = Keyword.keys(opts)

    case keys -- Enum.uniq(keys) do
      [] ->
        :ok

      duplicates ->
        raise ArgumentError,
              "#{inspect(owner)}.#{name}: duplicate options #{inspect(Enum.uniq(duplicates))}"
    end

    case Enum.uniq(keys) -- @options do
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

  defp retention!(_owner, _name, expires_at: field)
       when is_atom(field) and not is_nil(field),
       do: [expires_at: field]

  defp retention!(owner, name, retention) when is_list(retention) do
    keys = Keyword.keys(retention)

    case keys -- Enum.uniq(keys) do
      [] ->
        :ok

      duplicates ->
        raise ArgumentError,
              "#{inspect(owner)}.#{name}: retention has duplicate options " <>
                inspect(Enum.uniq(duplicates))
    end

    case Enum.uniq(keys) -- [:max_age_ms, :timestamp] do
      [] ->
        :ok

      unsupported ->
        raise ArgumentError,
              "#{inspect(owner)}.#{name}: retention has unsupported options " <>
                inspect(unsupported)
    end

    max_age_ms = Keyword.get(retention, :max_age_ms)
    timestamp = Keyword.get(retention, :timestamp)

    unless is_integer(max_age_ms) and max_age_ms > 0 do
      raise ArgumentError,
            "#{inspect(owner)}.#{name}: retention needs a positive :max_age_ms, " <>
              "got #{inspect(retention)}"
    end

    unless (is_atom(timestamp) and not is_nil(timestamp)) or
             match?(
               {module, function}
               when is_atom(module) and not is_nil(module) and is_atom(function) and
                      not is_nil(function),
               timestamp
             ) do
      raise ArgumentError,
            "#{inspect(owner)}.#{name}: retention :timestamp must be an atom field or " <>
              "{module, function}, got #{inspect(timestamp)}"
    end

    [max_age_ms: max_age_ms, timestamp: timestamp]
  end

  defp retention!(owner, name, other) do
    raise ArgumentError, "#{inspect(owner)}.#{name}: invalid retention #{inspect(other)}"
  end

  defp persistence!(_owner, _name, value) when value in [:durable, :ephemeral], do: value

  defp persistence!(owner, name, value) do
    raise ArgumentError,
          "#{inspect(owner)}.#{name}: persistence must be :durable or :ephemeral, " <>
            "got #{inspect(value)}"
  end

  defp version!(_owner, _name, value) when is_integer(value) and value > 0, do: value

  defp version!(owner, name, value) do
    raise ArgumentError,
          "#{inspect(owner)}.#{name}: version must be a positive integer, got #{inspect(value)}"
  end
end
