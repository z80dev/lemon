defmodule LemonCore.MapHelpers do
  @moduledoc """
  Helpers for accessing map keys that may be stored as either atoms or strings.

  Many parts of the codebase deal with maps that may have atom keys or string
  keys (e.g. from JSON decoding). `get_key/2` unifies access by trying both
  representations, eliminating the repeated `Map.get(m, k) || Map.get(m, Atom.to_string(k))`
  pattern found across the codebase.
  """

  @doc """
  Gets a value from a map, trying both the given key and its atom/string
  counterpart.

  When `key` is an atom, tries the atom first then its string representation.
  When `key` is a string, tries the string first then its existing atom
  representation (via `String.to_existing_atom/1` to avoid atom table pollution).

  Returns `nil` when the key is not found under either representation.

  ## Examples

      iex> LemonCore.MapHelpers.get_key(%{name: "Alice"}, :name)
      "Alice"

      iex> LemonCore.MapHelpers.get_key(%{"name" => "Alice"}, :name)
      "Alice"

      iex> LemonCore.MapHelpers.get_key(%{name: "Alice"}, "name")
      "Alice"

      iex> LemonCore.MapHelpers.get_key(%{"age" => 30}, "age")
      30

      iex> LemonCore.MapHelpers.get_key(%{}, :missing)
      nil
  """
  @spec get_key(map(), atom()) :: any()
  def get_key(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  @spec get_key(map(), String.t()) :: any()
  def get_key(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end

  def get_key(_, _), do: nil

  @doc """
  Recursively converts all map keys to strings.

  Traverses nested maps and lists, converting atom keys (and any other key
  types) to their string representation via `to_string/1`.

  ## Examples

      iex> LemonCore.MapHelpers.stringify_keys(%{foo: %{bar: 1}})
      %{"foo" => %{"bar" => 1}}

      iex> LemonCore.MapHelpers.stringify_keys(%{"already" => "string"})
      %{"already" => "string"}

      iex> LemonCore.MapHelpers.stringify_keys([%{a: 1}, %{b: 2}])
      [%{"a" => 1}, %{"b" => 2}]
  """
  @spec stringify_keys(map()) :: map()
  @spec stringify_keys(list()) :: list()
  @spec stringify_keys(term()) :: term()
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {k, v} -> {to_string(k), stringify_keys(v)} end)
  end

  def stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  def stringify_keys(value), do: value

  @doc """
  Merges an optional overrides value into a base config map.

  Handles `nil` (no-op), maps (direct merge), keyword lists (converted to map
  then merged), and ignores anything else.

  ## Examples

      iex> LemonCore.MapHelpers.merge_config(%{a: 1}, %{b: 2})
      %{a: 1, b: 2}

      iex> LemonCore.MapHelpers.merge_config(%{a: 1}, nil)
      %{a: 1}

      iex> LemonCore.MapHelpers.merge_config(%{a: 1}, [b: 2])
      %{a: 1, b: 2}
  """
  @spec merge_config(map(), term()) :: map()
  def merge_config(base, nil), do: base
  def merge_config(base, opts) when is_map(opts), do: Map.merge(base, opts)

  def merge_config(base, opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: Map.merge(base, Enum.into(opts, %{})), else: base
  end

  def merge_config(base, _opts), do: base

  @doc """
  Recursively merges `override` into `base`, with the override side winning.

  At any key present in both maps, two map values are merged recursively; every
  other pair — including a map facing a non-map, on either side — is replaced by
  the `override` value. When either top-level argument is not a map, `override`
  is returned as-is. Merging an empty map on either side is therefore the
  identity on the other.

  This is the shared implementation behind config layering (global ← project ←
  overrides); it is intentionally *not* associative in general, because nesting
  vs. replacement depends on the shape at each level.

  ## Examples

      iex> LemonCore.MapHelpers.deep_merge(%{a: %{x: 1, y: 2}}, %{a: %{y: 3, z: 4}})
      %{a: %{x: 1, y: 3, z: 4}}

      iex> LemonCore.MapHelpers.deep_merge(%{a: 1}, %{})
      %{a: 1}

      iex> LemonCore.MapHelpers.deep_merge(%{}, %{a: 1})
      %{a: 1}

      iex> LemonCore.MapHelpers.deep_merge(%{a: %{x: 1}}, %{a: 2})
      %{a: 2}

      iex> LemonCore.MapHelpers.deep_merge(%{a: 1}, "scalar")
      "scalar"
  """
  @spec deep_merge(term(), term()) :: term()
  def deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _key, base_val, override_val ->
      deep_merge(base_val, override_val)
    end)
  end

  def deep_merge(_base, override), do: override
end
