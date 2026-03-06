defmodule LemonCore.IntrospectionStore do
  @moduledoc """
  Typed wrapper for introspection event persistence.
  """

  alias LemonCore.Store

  @spec append(map()) :: :ok | {:error, term()}
  def append(event), do: Store.append_introspection_event(event)

  @spec list(keyword()) :: list()
  def list(opts \\ []), do: Store.list_introspection_events(opts)

  @spec count(keyword()) :: non_neg_integer()
  def count(opts \\ []) do
    opts
    |> list()
    |> length()
  end
end
