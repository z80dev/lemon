defmodule LemonMemory.SessionParticipant do
  @moduledoc """
  `LemonCore.SessionLifecycle.Participant` for durable memory: deleting a
  session deletes its memory documents and their search rows, so recall and
  search never return a deleted conversation.

  Reset keeps memory: recall of earlier work is durable by design.
  """

  @behaviour LemonCore.SessionLifecycle.Participant

  alias LemonMemory.Store

  @impl true
  def snapshot(session_key, :delete), do: Store.fetch_session_documents(session_key)

  @impl true
  def delete(session_key, :delete, _documents), do: Store.delete_by_session(session_key)

  @impl true
  def verify_deleted(session_key, :delete, _documents) do
    case Store.fetch_session_documents(session_key) do
      {:ok, []} -> :ok
      {:ok, _remaining} -> {:error, :documents_remain}
      {:error, _} = error -> error
    end
  end

  @impl true
  def restore(_session_key, :delete, documents), do: Store.restore_documents(documents)
end
