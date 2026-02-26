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
end
