defmodule LemonGateway.Transports.Webhook.Helpers do
  @moduledoc """
  Shared utility functions used across webhook transport modules.

  Provides value normalization, map access, type coercion, and other
  primitives that multiple webhook submodules depend on.
  """

  @doc """
  Fetches a value from a map or keyword list, trying both atom and string keys.
  """
  @spec fetch(map() | keyword() | term(), atom() | String.t()) :: term()
  def fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  def fetch(list, key) when is_list(list) do
    Keyword.get(list, key) || Keyword.get(list, to_string(key))
  end

  def fetch(_value, _key), do: nil

  @doc """
  Fetches a value from a map by trying multiple key paths in order.
  Returns the first non-nil result.
  """
  @spec fetch_any(map() | term(), list(list(String.t()))) :: term()
  def fetch_any(map, paths) when is_map(map) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      fetch_path(map, path)
    end)
  end

  def fetch_any(_map, _paths), do: nil

  @doc """
  Fetches a nested value from a map following the given path segments.
  """
  @spec fetch_path(term(), list(String.t())) :: term()
  def fetch_path(value, []), do: value

  def fetch_path(value, [segment | rest]) do
    case fetch(value, segment) do
      nil -> nil
      next -> fetch_path(next, rest)
    end
  end

  @doc """
  Trims whitespace from a binary and returns nil if the result is empty.
  Non-binary values pass through unchanged.
  """
  @spec normalize_blank(term()) :: term()
  def normalize_blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  def normalize_blank(value), do: value

  @doc """
  Returns the first non-blank value from a list.
  """
  @spec first_non_blank(list()) :: term()
  def first_non_blank(values) when is_list(values) do
    Enum.find_value(values, fn value ->
      case normalize_blank(value) do
        nil -> nil
        normalized -> normalized
      end
    end)
  end

  @doc """
  Converts a value to an integer, returning a default if conversion fails.
  """
  @spec int_value(term(), term()) :: integer() | term()
  def int_value(nil, default), do: default
  def int_value(value, _default) when is_integer(value), do: value

  def int_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _} -> integer
      _ -> default
    end
  end

  def int_value(_value, default), do: default

  @doc """
  Normalizes a value into a map. Keyword lists become maps; other values become empty maps.
  """
  @spec normalize_map(term()) :: map()
  def normalize_map(map) when is_map(map), do: map

  def normalize_map(list) when is_list(list) do
    if Keyword.keyword?(list), do: Enum.into(list, %{}), else: %{}
  end

  def normalize_map(_), do: %{}

  @doc """
  Resolves a boolean from a list of candidate values, returning the first
  that can be interpreted as a boolean, or the default.
  """
  @spec resolve_boolean(list(), boolean()) :: boolean()
  def resolve_boolean(values, default) when is_list(values) do
    Enum.find_value(values, default, fn value ->
      bool_value(value)
    end)
  end

  @doc """
  Coerces a value to a boolean. Returns nil for unrecognized values.
  """
  @spec bool_value(term()) :: boolean() | nil
  def bool_value(value) when is_boolean(value), do: value
  def bool_value(value) when value in [1, "1", "true", "TRUE", "yes", "YES"], do: true
  def bool_value(value) when value in [0, "0", "false", "FALSE", "no", "NO"], do: false
  def bool_value(_value), do: nil

  @doc """
  Puts a key-value pair into a map only when the value is non-nil.
  """
  @spec maybe_put(map(), atom(), term()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)
end
