defmodule LemonGateway.Shared do
  @moduledoc """
  Shared utility functions used across LemonGateway modules.
  
  This module centralizes common helper functions to reduce duplication
  and provide consistent behavior for configuration access, data normalization,
  and type conversions across the codebase.
  """

  @doc """
  Fetches a value from a map or keyword list, trying both atom and string keys.
  """
  @spec fetch(map() | keyword(), atom() | String.t()) :: any()
  def fetch(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  def fetch(list, key) when is_list(list) do
    Keyword.get(list, key) || Keyword.get(list, to_string(key))
  end

  def fetch(_value, _key), do: nil

  @doc """
  Fetches a nested value from a map by trying multiple key paths.
  Returns the first non-nil value found.
  """
  @spec fetch_any(map() | keyword(), list(list(String.t() | atom()))) :: any()
  def fetch_any(map, paths) when is_map(map) and is_list(paths) do
    Enum.find_value(paths, fn path ->
      fetch_path(map, path)
    end)
  end

  def fetch_any(_map, _paths), do: nil

  @doc """
  Fetches a value from a nested map structure following a path of keys.
  """
  @spec fetch_path(any(), list(String.t() | atom())) :: any()
  def fetch_path(value, []), do: value

  def fetch_path(value, [segment | rest]) do
    case fetch(value, segment) do
      nil -> nil
      next -> fetch_path(next, rest)
    end
  end

  @doc """
  Normalizes a blank value (nil or empty/whitespace string) to nil.
  """
  @spec normalize_blank(any()) :: any()
  def normalize_blank(nil), do: nil

  def normalize_blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  def normalize_blank(value), do: value

  @doc """
  Returns the first non-blank value from a list.
  """
  @spec first_non_blank(list()) :: any()
  def first_non_blank(values) when is_list(values) do
    Enum.find_value(values, fn value ->
      case normalize_blank(value) do
        nil -> nil
        normalized -> normalized
      end
    end)
  end

  @doc """
  Returns the first non-nil value from a list.
  """
  @spec first_non_nil(list()) :: any()
  def first_non_nil(values) when is_list(values) do
    Enum.find(values, &(not is_nil(&1)))
  end

  @doc """
  Converts a value to an integer with a default fallback.
  """
  @spec int_value(any(), integer()) :: integer()
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
  Converts a value to a boolean with a default fallback.
  """
  @spec resolve_boolean(list(any()), boolean()) :: boolean()
  def resolve_boolean(values, default) when is_list(values) do
    Enum.find_value(values, default, &bool_value/1)
  end

  @spec bool_value(any()) :: boolean() | nil
  def bool_value(value) when is_boolean(value), do: value
  def bool_value(value) when value in [1, "1", "true", "TRUE", "yes", "YES"], do: true
  def bool_value(value) when value in [0, "0", "false", "FALSE", "no", "NO"], do: false
  def bool_value(_value), do: nil

  @doc """
  Checks if a value is truthy.
  """
  @spec truthy?(any()) :: boolean()
  def truthy?(value) when is_boolean(value), do: value
  def truthy?(value) when is_integer(value), do: value != 0

  def truthy?(value) when is_binary(value) do
    String.downcase(String.trim(value)) in ["1", "true", "yes", "on"]
  end

  def truthy?(_), do: false

  @doc """
  Puts a value into a map only if the value is not nil.
  """
  @spec maybe_put(map(), any(), any()) :: map()
  def maybe_put(map, _key, nil), do: map
  def maybe_put(map, key, value), do: Map.put(map, key, value)

  @doc """
  Converts a map to a normalized map (handles keyword lists).
  """
  @spec normalize_map(map() | keyword()) :: map()
  def normalize_map(map) when is_map(map), do: map

  def normalize_map(list) when is_list(list) do
    if Keyword.keyword?(list), do: Enum.into(list, %{}), else: %{}
  end

  def normalize_map(_), do: %{}

  @doc """
  Determines if a transport is enabled based on Config and Application env.
  """
  @spec transport_enabled?(atom()) :: boolean()
  def transport_enabled?(config_key) when is_atom(config_key) do
    if is_pid(Process.whereis(LemonGateway.Config)) do
      LemonGateway.Config.get(config_key) == true
    else
      cfg = Application.get_env(:lemon_gateway, LemonGateway.Config, %{})

      cond do
        is_list(cfg) -> Keyword.get(cfg, config_key, false)
        is_map(cfg) -> fetch(cfg, config_key) || false
        true -> false
      end
    end
  rescue
    _ -> false
  end

  @doc """
  Gets configuration for a transport from Config or Application env.
  """
  @spec get_transport_config(atom(), atom()) :: map()
  def get_transport_config(config_key, app_env_key) when is_atom(config_key) do
    cfg =
      if is_pid(Process.whereis(LemonGateway.Config)) do
        LemonGateway.Config.get(config_key) || %{}
      else
        Application.get_env(:lemon_gateway, app_env_key, %{})
      end

    normalize_map(cfg)
  rescue
    _ -> %{}
  end

  @doc """
  Parses an IP address string into a tuple.
  """
  @spec parse_ip(String.t()) :: :inet.ip_address() | nil
  def parse_ip(value) when is_binary(value) do
    value
    |> String.to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, ip} -> ip
      _ -> nil
    end
  end

  def parse_ip(_), do: nil

  @doc """
  Normalizes a bind IP configuration value to :loopback, :any, or parsed IP.
  """
  @spec normalize_bind_ip(any()) :: :loopback | :any | :inet.ip_address()
  def normalize_bind_ip(nil), do: :loopback
  def normalize_bind_ip("127.0.0.1"), do: :loopback
  def normalize_bind_ip("localhost"), do: :loopback
  def normalize_bind_ip("0.0.0.0"), do: :any
  def normalize_bind_ip("any"), do: :any
  def normalize_bind_ip(other), do: parse_ip(other) || :loopback

  @doc """
  Canonicalizes a hostname by trimming, removing trailing dot, and lowercasing.
  """
  @spec canonicalize_host(String.t()) :: String.t() | nil
  def canonicalize_host(host) when is_binary(host) do
    host
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
    |> normalize_blank()
  end

  def canonicalize_host(_), do: nil

  @doc """
  Safely emits telemetry events if LemonCore.Telemetry is available.
  """
  @spec emit_telemetry(atom(), map()) :: any()
  def emit_telemetry(event_name, metadata) do
    if Code.ensure_loaded?(LemonCore.Telemetry) do
      apply(LemonCore.Telemetry, event_name, [metadata])
    end
  end

  @doc """
  Safely broadcasts to LemonCore.Bus if available.
  """
  @spec broadcast_to_bus(String.t(), any()) :: :ok
  def broadcast_to_bus(topic, event) do
    if Code.ensure_loaded?(LemonCore.Bus) do
      LemonCore.Bus.broadcast(topic, event)
    end

    :ok
  rescue
    _ -> :ok
  end
end
