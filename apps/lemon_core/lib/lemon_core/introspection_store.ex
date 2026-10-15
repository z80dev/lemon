defmodule LemonCore.IntrospectionStore do
  @moduledoc """
  Typed wrapper for introspection event persistence.

  Listing and counting preserve storage failures as `{:error, reason}`;
  an empty list or zero count means the query succeeded.
  """

  alias LemonCore.Store

  @spec append(map()) :: :ok | {:error, term()}
  def append(event), do: Store.append_introspection_event(event)

  @spec list(keyword()) :: [map()] | {:error, term()}
  def list(opts \\ []), do: Store.list_introspection_events(opts)

  @doc """
  Fetch all terminal run events since a UTC boundary without the listing limit.
  Used to rebuild daily counters; storage failures are not an empty history.
  """
  @spec terminal_events_since(non_neg_integer()) :: {:ok, [map()]} | {:error, term()}
  def terminal_events_since(since_ms) do
    with {:ok, entries} <- Store.fetch_all(:introspection_log) do
      events =
        for {_key, event} <- entries,
            event.event_type in [:run_completed, :run_failed, "run_completed", "run_failed"],
            event.ts_ms >= since_ms,
            do: event

      {:ok, events}
    end
  end

  @spec count(keyword()) :: non_neg_integer() | {:error, term()}
  def count(opts \\ []) do
    case list(opts) do
      events when is_list(events) -> length(events)
      {:error, _} = error -> error
    end
  end
end
