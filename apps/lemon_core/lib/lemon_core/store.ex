defmodule LemonCore.Store do
  @moduledoc """
  Thin wrapper over LemonGateway.Store to avoid other apps depending
  directly on LemonGateway internals.

  This module provides a stable interface for storage operations that
  other lemon_* apps can depend on.

  ## Tables

  New tables required for parity (beyond LemonGateway's existing `:chat/:runs/:run_history`):

  - `:idempotency` - Idempotency key storage
  - `:agents` - Agent configurations
  - `:agent_files` - Agent file storage
  - `:sessions_index` - Session index cache
  - `:skills_status_cache` - Skills status cache
  - `:skills_config` - Skills configuration
  - `:cron_jobs` - Cron job definitions
  - `:cron_runs` - Cron run history
  - `:exec_approvals_policy` - Global approval policy
  - `:exec_approvals_policy_agent` - Per-agent approval overrides
  - `:exec_approvals_policy_node` - Per-node approval overrides
  - `:exec_approvals_pending` - Pending approval requests
  - `:nodes_pairing` - Node pairing state
  - `:nodes_registry` - Registered nodes
  - `:voicewake_config` - Voice wake configuration (optional)
  - `:tts_config` - TTS configuration (optional)
  """

  @doc """
  Put a value into a table.
  """
  @spec put(table :: atom(), key :: term(), value :: term()) :: :ok
  def put(table, key, value) do
    apply(store_mod(), :put, [table, key, value])
  end

  @doc """
  Get a value from a table.

  Returns `nil` if the key doesn't exist.
  """
  @spec get(table :: atom(), key :: term()) :: term() | nil
  def get(table, key) do
    apply(store_mod(), :get, [table, key])
  end

  @doc """
  Delete a key from a table.
  """
  @spec delete(table :: atom(), key :: term()) :: :ok
  def delete(table, key) do
    apply(store_mod(), :delete, [table, key])
  end

  @doc """
  List all key-value pairs in a table.
  """
  @spec list(table :: atom()) :: [{term(), term()}]
  def list(table) do
    apply(store_mod(), :list, [table])
  end

  @doc """
  Update a value in a table using an update function.

  If the key doesn't exist, the function receives `nil`.
  """
  @spec update(table :: atom(), key :: term(), (term() | nil -> term())) :: :ok
  def update(table, key, fun) when is_function(fun, 1) do
    current = get(table, key)
    new_value = fun.(current)
    put(table, key, new_value)
  end

  @doc """
  Get multiple keys from a table.

  Returns a map of key => value for found keys.
  """
  @spec get_many(table :: atom(), keys :: [term()]) :: %{term() => term()}
  def get_many(table, keys) do
    keys
    |> Enum.map(fn key -> {key, get(table, key)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  @doc """
  Put multiple key-value pairs into a table.
  """
  @spec put_many(table :: atom(), entries :: [{term(), term()}] | %{term() => term()}) :: :ok
  def put_many(table, entries) when is_list(entries) do
    Enum.each(entries, fn {key, value} -> put(table, key, value) end)
  end

  def put_many(table, entries) when is_map(entries) do
    put_many(table, Map.to_list(entries))
  end

  # Avoid a compile-time dependency on lemon_gateway (umbrella compile order),
  # while still using the shared LemonGateway.Store at runtime.
  defp store_mod do
    Application.get_env(:lemon_core, :store_mod, :"Elixir.LemonGateway.Store")
  end
end
