defmodule LemonChannels.SessionParticipant do
  @moduledoc """
  `LemonCore.SessionLifecycle.Participant` for channel-owned session state.

  Delete and reset both remove the Telegram message→session and message→resume
  index rows of the session (a reply to an old message must not resume the
  deleted or reset conversation) and Discord's pending selected resume. Delete
  also removes the Telegram and Discord per-session model overrides, which
  reset keeps as preferences.
  """

  @behaviour LemonCore.SessionLifecycle.Participant

  alias LemonChannels.Telegram.ResumeIndexStore
  alias LemonCore.SessionLifecycle.StoreRows

  # Session-keyed channel tables (owned by `LemonChannels.Telegram.StateStore`,
  # `LemonChannels.Adapters.Discord.ModelPolicyAdapter` and the Discord transport).
  @reset_tables [:discord_selected_resume]
  @delete_tables [
                   :telegram_session_model,
                   :discord_session_model
                 ] ++ @reset_tables

  @impl true
  def snapshot(session_key, operation) do
    with {:ok, index_rows} <- ResumeIndexStore.fetch_session_rows(session_key),
         {:ok, rows} <- StoreRows.snapshot(session_key, tables(operation)) do
      {:ok, index_rows ++ rows}
    end
  end

  @impl true
  def delete(_session_key, _operation, rows), do: StoreRows.delete(rows)

  @impl true
  def verify_deleted(session_key, operation, rows) do
    with {:ok, []} <- ResumeIndexStore.fetch_session_rows(session_key),
         :ok <- StoreRows.verify_deleted(session_key, tables(operation), rows) do
      :ok
    else
      {:ok, _remaining} -> {:error, :rows_remain}
      error -> error
    end
  end

  @impl true
  def restore(_session_key, _operation, rows), do: StoreRows.restore(rows)

  defp tables(:delete), do: @delete_tables
  defp tables(:reset), do: @reset_tables
end
