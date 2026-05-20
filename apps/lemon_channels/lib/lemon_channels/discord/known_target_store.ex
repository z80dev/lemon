defmodule LemonChannels.Discord.KnownTargetStore do
  @moduledoc """
  Typed wrapper for Discord known-target metadata.
  """

  alias LemonCore.Store

  @table :discord_known_targets

  @spec get(term()) :: term()
  def get(key), do: Store.get(@table, key)

  @spec put(term(), map()) :: :ok
  def put(key, value), do: Store.put(@table, key, value)

  @spec list() :: list()
  def list, do: Store.list(@table)

  @spec list_available() :: list()
  def list_available do
    if Process.whereis(Store) do
      list()
    else
      list_from_configured_backend()
    end
  end

  defp list_from_configured_backend do
    config =
      Application.get_env(:lemon_core, Store, [])
      |> merge_runtime_override(Application.get_env(:lemon_core, :store_runtime_override, []))

    backend = Keyword.get(config, :backend, LemonCore.Store.EtsBackend)
    backend_opts = Keyword.get(config, :backend_opts, [])

    case backend.init(backend_opts) do
      {:ok, state} ->
        case backend.list(state, @table) do
          {:ok, entries, state} ->
            close_backend(backend, state)
            entries

          _ ->
            close_backend(backend, state)
            []
        end

      _ ->
        []
    end
  end

  defp merge_runtime_override(config, []), do: config

  defp merge_runtime_override(config, override) when is_list(config) and is_list(override) do
    override_without_backend_opts = Keyword.delete(override, :backend_opts)
    merged = Keyword.merge(config, override_without_backend_opts)

    case Keyword.fetch(override, :backend_opts) do
      {:ok, override_backend_opts} ->
        backend_opts =
          Keyword.merge(Keyword.get(config, :backend_opts, []), override_backend_opts)

        Keyword.put(merged, :backend_opts, backend_opts)

      :error ->
        merged
    end
  end

  defp merge_runtime_override(config, _override), do: config

  defp close_backend(backend, state) do
    if function_exported?(backend, :close, 1) do
      backend.close(state)
    else
      :ok
    end
  end
end
