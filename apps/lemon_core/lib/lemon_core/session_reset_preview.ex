defmodule LemonCore.SessionResetPreview do
  @moduledoc false

  alias LemonCore.Store

  @table :session_reset_previews
  @ttl_ms 600_000
  @max_previews 64

  @spec retain(String.t(), String.t()) :: {:ok, String.t()} | {:error, :session_store_unavailable}
  def retain(session_key, digest) when is_binary(session_key) and is_binary(digest) do
    locked(fn ->
      owner = Process.whereis(Store)
      now = System.system_time(:millisecond)

      with true <- is_pid(owner),
           {:ok, entries} <- Store.fetch_all(@table),
           :ok <- evict(entries, owner, now) do
        token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

        entry = %{
          session_key: session_key,
          digest: digest,
          store_owner: owner,
          expires_at_ms: now + @ttl_ms,
          sequence: System.unique_integer([:positive, :monotonic])
        }

        with :ok <- Store.put(Store, @table, token, entry, durable: true),
             true <- Process.whereis(Store) == owner do
          {:ok, token}
        else
          _ -> {:error, :session_store_unavailable}
        end
      else
        _ -> {:error, :session_store_unavailable}
      end
    end)
  end

  @spec consume(String.t(), String.t(), String.t()) ::
          :ok | {:error, :confirmation_mismatch | :session_store_unavailable}
  def consume(session_key, token, expected_digest)
      when is_binary(session_key) and is_binary(token) and is_binary(expected_digest) do
    locked(fn ->
      case Store.fetch(@table, token) do
        {:ok, entry} when is_map(entry) ->
          # Consume durably before any destructive write so a stale or failed
          # confirmation can never be replayed.
          case Store.compare_and_delete(Store, @table, token, entry, durable: true) do
            :ok ->
              now = System.system_time(:millisecond)

              if entry[:session_key] == session_key and
                   entry[:store_owner] == Process.whereis(Store) and
                   is_integer(entry[:expires_at_ms]) and
                   entry.expires_at_ms > now and
                   secure_equal?(entry[:digest], expected_digest) do
                :ok
              else
                {:error, :confirmation_mismatch}
              end

            {:error, :mismatch} ->
              {:error, :confirmation_mismatch}

            _ ->
              {:error, :session_store_unavailable}
          end

        {:ok, nil} ->
          {:error, :confirmation_mismatch}

        _ ->
          {:error, :session_store_unavailable}
      end
    end)
  end

  defp evict(entries, owner, now) do
    {live, expired} =
      Enum.split_with(entries, fn {_, entry} ->
        is_map(entry) and entry[:store_owner] == owner and
          is_integer(entry[:expires_at_ms]) and entry.expires_at_ms > now
      end)

    evicted =
      live
      |> Enum.sort_by(fn {_, entry} -> entry.sequence end, :desc)
      |> Enum.drop(@max_previews - 1)

    Enum.reduce_while(expired ++ evicted, :ok, fn {token, entry}, :ok ->
      case Store.compare_and_delete(Store, @table, token, entry, durable: true) do
        :ok -> {:cont, :ok}
        _ -> {:halt, {:error, :session_store_unavailable}}
      end
    end)
  end

  defp locked(fun) do
    case :global.trans({{__MODULE__, :previews}, self()}, fun, [node()], 3) do
      :aborted -> {:error, :session_store_unavailable}
      result -> result
    end
  end

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right),
    do: byte_size(left) == byte_size(right) and :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false
end
