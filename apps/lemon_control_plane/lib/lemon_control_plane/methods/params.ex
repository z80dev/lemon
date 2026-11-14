defmodule LemonControlPlane.Methods.Params do
  @moduledoc false

  def get_map(map, key, default \\ nil)
  def get_map(nil, _key, default), do: default

  def get_map(map, key, default) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      is_atom(key) and Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> default
    end
  rescue
    _ -> default
  end

  def get_map(_map, _key, default), do: default

  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(_), do: false

  def to_ms(nil), do: nil
  def to_ms(ms) when is_integer(ms) and ms > 9_999_999_999, do: ms
  def to_ms(sec) when is_integer(sec), do: sec * 1000
  def to_ms(_), do: nil

  def truthy?(value, _default) when is_boolean(value), do: value
  def truthy?(value, _default) when value in ["true", "TRUE", "1", 1, "yes", "on"], do: true
  def truthy?(value, _default) when value in ["false", "FALSE", "0", 0, "no", "off"], do: false
  def truthy?(_value, default), do: default

  def normalize_limit(limit, _default, max) when is_integer(limit) and limit > 0,
    do: min(limit, max)

  def normalize_limit(limit, default, max) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _} when parsed > 0 -> min(parsed, max)
      _ -> default
    end
  end

  def normalize_limit(_, default, _), do: default

  def get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  def get_param(_params, _key), do: nil
end
