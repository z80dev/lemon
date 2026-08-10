defmodule LemonCore.MapHelpersDeepMergePropertyTest do
  @moduledoc """
  Property-based invariants for `LemonCore.MapHelpers.deep_merge/2`, the shared
  config-layering merge lifted out of `LemonCore.Config` and
  `LemonCore.Config.Modular`.

  The invariants asserted:

    * the empty map is a two-sided identity (`m ← {}` and `{} ← m` both yield `m`);
    * the override side wins — every non-map leaf in `override` appears, at its
      own path, in the result;
    * keys present only on one side are preserved;
    * two map values at the same key recurse, while a non-map override value
      replaces whatever the base held.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias LemonCore.MapHelpers

  doctest LemonCore.MapHelpers, only: [deep_merge: 2]

  # Leaf (non-map) values that a config tree holds.
  defp leaf do
    one_of([
      integer(),
      boolean(),
      string(:printable),
      constant(nil),
      list_of(integer(), max_length: 3)
    ])
  end

  defp key, do: one_of([atom(:alphanumeric), string(:alphanumeric, min_length: 1)])

  # A bounded nested map: values are leaves or (shrinking) sub-maps.
  defp nested_map(0), do: map_of(key(), leaf(), max_length: 4)

  defp nested_map(depth) do
    map_of(key(), one_of([leaf(), nested_map(depth - 1)]), max_length: 4)
  end

  defp nested_map, do: nested_map(3)

  # All {path, value} pairs at non-map leaves, path as a list of keys.
  defp leaves(map, prefix \\ []) do
    Enum.flat_map(map, fn {k, v} ->
      path = prefix ++ [k]
      if is_map(v), do: leaves(v, path), else: [{path, v}]
    end)
  end

  defp get_path(value, []), do: {:ok, value}

  defp get_path(map, [k | rest]) when is_map(map) do
    case Map.fetch(map, k) do
      {:ok, v} -> get_path(v, rest)
      :error -> :error
    end
  end

  defp get_path(_value, _path), do: :error

  property "the empty map is a two-sided identity" do
    check all(m <- nested_map()) do
      assert MapHelpers.deep_merge(m, %{}) == m
      assert MapHelpers.deep_merge(%{}, m) == m
    end
  end

  property "every non-map leaf in override wins at its own path" do
    check all(
            base <- nested_map(),
            override <- nested_map()
          ) do
      result = MapHelpers.deep_merge(base, override)

      for {path, value} <- leaves(override) do
        assert get_path(result, path) == {:ok, value},
               "override leaf at #{inspect(path)} should win"
      end
    end
  end

  property "keys present on only one side are preserved" do
    check all(
            base <- nested_map(),
            override <- nested_map()
          ) do
      result = MapHelpers.deep_merge(base, override)

      only_base = Map.keys(base) -- Map.keys(override)
      only_override = Map.keys(override) -- Map.keys(base)

      for k <- only_base, do: assert(Map.fetch(result, k) == Map.fetch(base, k))
      for k <- only_override, do: assert(Map.fetch(result, k) == Map.fetch(override, k))

      # The key set of a merge is exactly the union of both key sets.
      assert MapSet.new(Map.keys(result)) ==
               MapSet.union(MapSet.new(Map.keys(base)), MapSet.new(Map.keys(override)))
    end
  end

  property "two maps at the same key recurse; a non-map override replaces" do
    check all(
            k <- key(),
            base_sub <- nested_map(),
            other <- one_of([leaf(), nested_map()])
          ) do
      # Same key, both map values -> recurse (equal to merging the sub-maps).
      if is_map(other) do
        assert MapHelpers.deep_merge(%{k => base_sub}, %{k => other}) ==
                 %{k => MapHelpers.deep_merge(base_sub, other)}
      else
        # Same key, override is a non-map -> it replaces the base sub-map wholesale.
        assert MapHelpers.deep_merge(%{k => base_sub}, %{k => other}) == %{k => other}
      end
    end
  end

  property "a non-map on either top-level side returns the override unchanged" do
    check all(
            m <- nested_map(),
            scalar <- leaf()
          ) do
      assert MapHelpers.deep_merge(scalar, m) == m
      assert MapHelpers.deep_merge(m, scalar) == scalar
      assert MapHelpers.deep_merge(scalar, scalar) == scalar
    end
  end
end
