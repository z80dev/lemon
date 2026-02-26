defmodule LemonCore.Idempotency do
  @moduledoc """
  Idempotency service for deduplicating operations.

  This module provides a mechanism to ensure operations like `send`, `agent`,
  and `node.invoke` are executed at-most-once by tracking operation keys.

  ## Storage

  Backed by `LemonCore.Store` table `:idempotency`.
  Values include `{result, inserted_at_ms}`.

  ## Examples

      # Check for existing result
      case LemonCore.Idempotency.get("messages", "msg_abc123") do
        {:ok, result} ->
          # Return cached result
          result
        :miss ->
          # Execute operation and store result
          result = execute_operation()
          LemonCore.Idempotency.put("messages", "msg_abc123", result)
          result
      end

  """

  @type scope :: binary()
  @type key :: binary()
  @type result :: term()

  @table :idempotency
  @default_ttl_ms 24 * 60 * 60 * 1000  # 24 hours

  @doc """
  Get a cached result for a scope and key.

  Returns `{:ok, result}` if found, or `:miss` if not found.
  """
  @spec get(scope(), key()) :: {:ok, result()} | :miss
  def get(scope, key) do
    full_key = make_key(scope, key)

    case LemonCore.Store.get(@table, full_key) do
      nil ->
        :miss

      %{"result" => result, "inserted_at_ms" => inserted_at_ms} ->
        if expired?(inserted_at_ms) do
          # Clean up expired entry
          LemonCore.Store.delete(@table, full_key)
          :miss
        else
          {:ok, result}
        end

      # Legacy format without timestamp
      result ->
        {:ok, result}
    end
  end

  @doc """
  Store a result for a scope and key.

  Always overwrites any existing value.
  """
  @spec put(scope(), key(), result()) :: :ok
  def put(scope, key, result) do
    full_key = make_key(scope, key)
    value = %{
      "result" => result,
      "inserted_at_ms" => LemonCore.Event.now_ms()
    }
    LemonCore.Store.put(@table, full_key, value)
  end

  @doc """
  Store a result only if the key doesn't already exist.

  Returns `:ok` if stored, or `:exists` if the key already exists.
  """
  @spec put_new(scope(), key(), result()) :: :ok | :exists
  def put_new(scope, key, result) do
    case get(scope, key) do
      {:ok, _} ->
        :exists

      :miss ->
        put(scope, key, result)
        :ok
    end
  end

  @doc """
  Delete an idempotency entry.
  """
  @spec delete(scope(), key()) :: :ok
  def delete(scope, key) do
    full_key = make_key(scope, key)
    LemonCore.Store.delete(@table, full_key)
  end

  @doc """
  Execute a function with idempotency guarantees.

  If the key exists, returns the cached result.
  Otherwise, executes the function, caches the result, and returns it.
  """
  @spec execute(scope(), key(), (-> result())) :: result()
  def execute(scope, key, fun) when is_function(fun, 0) do
    case get(scope, key) do
      {:ok, result} ->
        result

      :miss ->
        result = fun.()
        put(scope, key, result)
        result
    end
  end

  # Private functions

  defp make_key(scope, key) do
    "#{scope}:#{key}"
  end

  defp expired?(inserted_at_ms) do
    now = LemonCore.Event.now_ms()
    now - inserted_at_ms > @default_ttl_ms
  end
end
