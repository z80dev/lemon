defmodule LemonRouter.SessionCoordinatorSupervisor do
  @moduledoc """
  Dynamic supervisor wrapper for per-conversation session coordinators.
  """

  @spec ensure_started(term(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(conversation_key, opts \\ []) do
    spec =
      {LemonRouter.SessionCoordinator,
       Keyword.merge(opts, conversation_key: conversation_key)}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end
end
