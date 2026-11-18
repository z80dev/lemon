defmodule LemonCore.OutboundCopies do
  @moduledoc """
  Server-side provenance for private delivery copies.

  A tool that queues a file for channel delivery makes a private copy of the
  validated bytes (`LemonCore.FileAccess.retain_copy/2`) and registers that
  copy here under the session that made it. At completion the router's
  artifact tracker accepts a queued path outside the run cwd only when it can
  `take/2` a registration for the same session, so a path merely named in tool
  output (or anywhere else) is never trusted. Registrations are one-shot and
  expire with the copies themselves.

  Entries live in `LemonCore.RuntimeCache`'s ETS table, keyed by this module.
  """

  @table LemonCore.RuntimeCache
  @ttl_seconds 24 * 60 * 60

  @doc "Record `path` as a private copy made for `session_key`."
  @spec register(String.t(), String.t()) :: :ok | {:error, String.t()}
  def register(session_key, path)
      when is_binary(session_key) and session_key != "" and is_binary(path) do
    now = System.os_time(:second)
    prune(now - @ttl_seconds)
    true = :ets.insert(@table, {{__MODULE__, session_key, path}, now})
    :ok
  rescue
    ArgumentError -> {:error, "Failed to prepare the file for delivery."}
  end

  def register(_session_key, _path), do: {:error, "Failed to prepare the file for delivery."}

  @doc "Consume the registration of `path` for `session_key`; true when it existed and is fresh."
  @spec take(term(), term()) :: boolean()
  def take(session_key, path) when is_binary(session_key) and is_binary(path) do
    case :ets.take(@table, {__MODULE__, session_key, path}) do
      [{_key, at}] -> at >= System.os_time(:second) - @ttl_seconds
      [] -> false
    end
  rescue
    ArgumentError -> false
  end

  def take(_session_key, _path), do: false

  defp prune(cutoff) do
    :ets.select_delete(@table, [
      {{{__MODULE__, :_, :_}, :"$1"}, [{:<, :"$1", cutoff}], [true]}
    ])
  end
end
