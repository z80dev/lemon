defmodule LemonCore.ChatStateStore do
  @moduledoc """
  Per-scope chat state (`LemonCore.ChatState`) with a time to live.

  Owns the `:chat` table. Every write stamps `:expires_at` from the configured
  TTL, a read treats an expired entry as absent and removes it, and the
  store's periodic sweep removes the rest. The table is mirrored into the
  read cache, so reads skip the store process.

  Writes are synchronous: when `put/3` returns, a read cannot observe the
  previous value.

  ## Configuration

      config :lemon_core, LemonCore.ChatStateStore, ttl_ms: :timer.hours(24)
  """

  use LemonCore.Store.Table,
    tables: [chat: [cached: true, retention: [expires_at: :expires_at]]]

  alias LemonCore.{ChatState, Store}

  @table :chat
  # Default TTL: 24 hours in milliseconds
  @default_ttl_ms 24 * 60 * 60 * 1000

  @type scope :: term()
  @type state :: ChatState.t() | map()

  @doc "How long a written chat state lives, in milliseconds."
  @spec ttl_ms() :: pos_integer()
  def ttl_ms do
    :lemon_core
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:ttl_ms, @default_ttl_ms)
  end

  @doc """
  The chat state stored for `scope`, or `nil` when there is none, it has
  expired, or the store could not be reached (which the store logs).
  """
  @spec get(Store.server(), scope()) :: state() | nil
  def get(server \\ Store, scope) do
    case Store.fetch(server, @table, scope) do
      {:ok, %{expires_at: expires_at} = value} when is_integer(expires_at) ->
        if System.system_time(:millisecond) > expires_at do
          # Expired: drop it now rather than waiting for the sweep, and do not
          # hand it out.
          _ = Store.delete(server, @table, scope)
          nil
        else
          value
        end

      {:ok, value} ->
        value

      _absent_or_unavailable ->
        nil
    end
  end

  @doc """
  Stores `state` for `scope`, stamped with `:expires_at` from `ttl_ms/0`.

  Accepts a `LemonCore.ChatState` struct or a plain map; the read returns the
  same shape, with the stamp.
  """
  @spec put(Store.server(), scope(), state()) :: :ok | {:error, term()}
  def put(server \\ Store, scope, state) when is_map(state) do
    expires_at = System.system_time(:millisecond) + ttl_ms()
    Store.put(server, @table, scope, stamp(state, expires_at))
  end

  @spec delete(Store.server(), scope()) :: :ok | {:error, term()}
  def delete(server \\ Store, scope), do: Store.delete(server, @table, scope)

  defp stamp(%_{} = struct, expires_at), do: %{struct | expires_at: expires_at}
  defp stamp(map, expires_at), do: Map.put(map, :expires_at, expires_at)
end
