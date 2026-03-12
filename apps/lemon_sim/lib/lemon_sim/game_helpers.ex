defmodule LemonSim.GameHelpers do
  @moduledoc """
  Shared utilities for LemonSim game implementations.

  Provides flexible key access helpers for maps that may use atom or string keys.

  ## Usage

      import LemonSim.GameHelpers
  """

  @doc """
  Gets a value from a map, trying both atom and string key forms.
  """
  def get(map, key, default \\ nil) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  @doc """
  Fetches a value trying an atom key first, then a string key fallback.
  """
  def fetch(map, atom_key, string_key, default \\ nil) do
    Map.get(map, atom_key, Map.get(map, string_key, default))
  end

  @doc """
  Conditionally puts a key-value pair in a keyword list (skips nil values).
  """
  def maybe_put(opts, _key, nil), do: opts
  def maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
