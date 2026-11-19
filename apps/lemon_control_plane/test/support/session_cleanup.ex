defmodule LemonControlPlane.TestSupport.SessionCleanup do
  @moduledoc false
  # Test setup/cleanup only: runs a destructive session lifecycle mutation under
  # a lifecycle fence generation taken directly in the fence store, without the
  # router's idle proof.

  alias LemonCore.{LifecycleFenceStore, SessionLifecycle}

  def delete(session_key, opts \\ []) when is_binary(session_key) do
    fenced(
      session_key,
      :delete,
      &SessionLifecycle.delete(session_key, opts ++ [fence_generation: &1])
    )
  end

  def reset(session_key, opts \\ []) when is_binary(session_key) do
    with {:ok, %{confirm_token: token}} <- SessionLifecycle.reset(session_key, dry_run: true) do
      fenced(
        session_key,
        :reset,
        &SessionLifecycle.reset(
          session_key,
          opts ++ [dry_run: false, confirm_token: token, fence_generation: &1]
        )
      )
    end
  end

  defp fenced(session_key, operation, fun) do
    case LifecycleFenceStore.acquire(session_key, self(), operation, "test-cleanup") do
      {:ok, %{generation: generation}} ->
        try do
          fun.(generation)
        after
          LifecycleFenceStore.release(session_key, generation)
        end

      {:error, _reason} = error ->
        error
    end
  end
end
