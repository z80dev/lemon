defmodule LemonSkills.TestSupport.SessionCleanup do
  @moduledoc false
  # Test setup/cleanup only: runs a destructive session lifecycle mutation under
  # a lifecycle fence generation taken directly in the fence store, without the
  # router's idle proof.

  alias LemonCore.{LifecycleFenceStore, SessionLifecycle}

  def delete(session_key, opts \\ []) when is_binary(session_key) do
    case LifecycleFenceStore.acquire(session_key, self(), :delete, "test-cleanup") do
      {:ok, %{generation: generation}} ->
        try do
          SessionLifecycle.delete(session_key, opts ++ [fence_generation: generation])
        after
          LifecycleFenceStore.release(session_key, generation)
        end

      {:error, _reason} = error ->
        error
    end
  end
end
