defmodule LemonCore.Config do
  @moduledoc """
  Configuration access for Lemon.

  Provides a consistent interface for accessing configuration values
  across the umbrella.
  """

  @doc """
  Get a configuration value.
  """
  @spec get(key :: atom(), default :: term()) :: term()
  def get(key, default \\ nil) do
    Application.get_env(:lemon_core, key, default)
  end

  @doc """
  Get all configuration values.
  """
  @spec all() :: keyword()
  def all do
    Application.get_all_env(:lemon_core)
  end

  @doc """
  Put a configuration value at runtime.
  """
  @spec put(key :: atom(), value :: term()) :: :ok
  def put(key, value) do
    Application.put_env(:lemon_core, key, value)
  end

  @doc """
  Get a nested configuration value.
  """
  @spec get_in(keys :: [atom()], default :: term()) :: term()
  def get_in(keys, default \\ nil) do
    case keys do
      [key] ->
        get(key, default)

      [key | rest] ->
        case get(key) do
          nil -> default
          value when is_map(value) -> Map.get(value, hd(rest), default)
          value when is_list(value) -> Kernel.get_in(value, rest) || default
          _ -> default
        end
    end
  end
end
