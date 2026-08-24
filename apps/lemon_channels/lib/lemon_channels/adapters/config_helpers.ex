defmodule LemonChannels.Adapters.ConfigHelpers do
  @moduledoc """
  Coercions shared by the adapters that resolve a `[gateway.<id>]` section.

  These moved out of `LemonCore.Config.Gateway` together with the sections
  themselves: TOML gives every value as a string key with an untyped value, and
  each adapter has to atomize keys, drop blanks and coerce the odd
  string-encoded boolean the same way the library used to.
  """

  @doc """
  Atomizes a section's top-level keys, leaving values untouched.

  Existing atoms are reused where possible so a config file cannot grow the
  atom table without bound on repeated loads.
  """
  @spec atomize_keys(map()) :: map()
  def atomize_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {safe_to_atom(key), value} end)
  end

  @doc "Atomizes a single key, preferring an existing atom."
  @spec safe_to_atom(atom() | String.t()) :: atom()
  def safe_to_atom(key) when is_atom(key), do: key

  def safe_to_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> String.to_atom(key)
  end

  @doc "Maps blank and non-binary values to `nil`."
  @spec blank_to_nil(term()) :: String.t() | nil
  def blank_to_nil(nil), do: nil
  def blank_to_nil(""), do: nil
  def blank_to_nil(value) when is_binary(value), do: value
  def blank_to_nil(_value), do: nil

  @doc "Like `blank_to_nil/1` but keeps integers, which TOML ids often are."
  @spec blank_to_nil_or_integer(term()) :: String.t() | integer() | nil
  def blank_to_nil_or_integer(value) when is_integer(value), do: value
  def blank_to_nil_or_integer(value), do: blank_to_nil(value)

  @doc "Coerces TOML's booleans, including the string forms, falling back to `default`."
  @spec boolean(term(), boolean()) :: boolean()
  def boolean(nil, default), do: default
  def boolean(value, _default) when is_boolean(value), do: value
  def boolean("true", _default), do: true
  def boolean("false", _default), do: false
  def boolean(_value, default), do: default

  @doc "Drops every `nil` value from a map."
  @spec reject_nils(map()) :: map()
  def reject_nils(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end
end
