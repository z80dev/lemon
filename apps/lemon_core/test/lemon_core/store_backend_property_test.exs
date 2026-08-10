defmodule LemonCore.StoreBackendPropertyTest do
  @moduledoc """
  Property-based invariants for the `LemonCore.Store` backend contract, driven
  against the default ETS backend.

  The example-based store tests fix specific tables/keys/values; these assert
  the two invariants a storage backend must never break for *any* term:

    * round-trip — `put` then `get` returns exactly what went in;
    * instance isolation — two independently `init/1`-ed backends never bleed
      into each other, even under identical table/key/value tuples.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias LemonCore.Store.EtsBackend

  # Arbitrary-but-bounded Elixir terms, so a value can be an atom, number,
  # binary, list, tuple, or nested map — the kind of thing callers actually
  # stash in the store.
  defp any_term do
    scalar =
      one_of([
        integer(),
        float(),
        boolean(),
        constant(nil),
        binary(),
        string(:printable),
        atom(:alphanumeric)
      ])

    one_of([
      scalar,
      list_of(scalar, max_length: 5),
      map_of(scalar, scalar, max_length: 5),
      tuple({scalar, scalar})
    ])
  end

  # Tables are addressed by atom; the backend creates unknown ones on demand.
  defp table, do: member_of([:chat, :progress, :runs, :arbitrary_table, :another])

  property "put then get returns exactly what was put, for any table/key/value" do
    check all(
            t <- table(),
            key <- any_term(),
            value <- any_term()
          ) do
      {:ok, state} = EtsBackend.init([])
      {:ok, state} = EtsBackend.put(state, t, key, value)

      assert {:ok, ^value, _state} = EtsBackend.get(state, t, key)
    end
  end

  property "the last write wins on the same table/key" do
    check all(
            t <- table(),
            key <- any_term(),
            first <- any_term(),
            second <- any_term()
          ) do
      {:ok, state} = EtsBackend.init([])
      {:ok, state} = EtsBackend.put(state, t, key, first)
      {:ok, state} = EtsBackend.put(state, t, key, second)

      assert {:ok, ^second, _state} = EtsBackend.get(state, t, key)
    end
  end

  property "two backend instances are fully isolated" do
    check all(
            t <- table(),
            key <- any_term(),
            value_a <- any_term(),
            value_b <- any_term()
          ) do
      {:ok, a} = EtsBackend.init([])
      {:ok, b} = EtsBackend.init([])

      {:ok, a} = EtsBackend.put(a, t, key, value_a)

      # Writing the same tuple into A must not make it visible in B.
      assert {:ok, nil, _b} = EtsBackend.get(b, t, key)

      # And a later write to B does not disturb A's value.
      {:ok, b} = EtsBackend.put(b, t, key, value_b)
      assert {:ok, ^value_a, _a} = EtsBackend.get(a, t, key)
      assert {:ok, ^value_b, _b} = EtsBackend.get(b, t, key)
    end
  end

  property "put_new refuses to overwrite an existing key but fills an empty one" do
    check all(
            t <- table(),
            key <- any_term(),
            first <- any_term(),
            second <- any_term()
          ) do
      {:ok, state} = EtsBackend.init([])

      assert {:ok, state} = EtsBackend.put_new(state, t, key, first)
      assert {:exists, state} = EtsBackend.put_new(state, t, key, second)
      assert {:ok, ^first, _state} = EtsBackend.get(state, t, key)
    end
  end

  property "delete makes a key unreadable regardless of the value stored" do
    check all(
            t <- table(),
            key <- any_term(),
            value <- any_term()
          ) do
      {:ok, state} = EtsBackend.init([])
      {:ok, state} = EtsBackend.put(state, t, key, value)
      {:ok, state} = EtsBackend.delete(state, t, key)

      assert {:ok, nil, _state} = EtsBackend.get(state, t, key)
    end
  end
end
