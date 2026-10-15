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

  @spec count(keyword()) :: non_neg_integer() | {:error, term()}
  def count(opts \\ []) do
    case list(opts) do
      events when is_list(events) -> length(events)
      {:error, _} = error -> error
    end
  end
end
