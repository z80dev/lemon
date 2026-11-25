defmodule LemonCore.SessionLifecycle.ExecApprovalGrants do
  @moduledoc false
  # Built-in lifecycle participant: session-scope exec-approval grants
  # (including invocation-context grants of the session). A deterministic
  # session key reused after delete or reset must not inherit them.

  @behaviour LemonCore.SessionLifecycle.Participant

  alias LemonCore.ExecApprovalStore

  @impl true
  def snapshot(session_key, _operation), do: ExecApprovalStore.fetch_session_grants(session_key)

  @impl true
  def delete(_session_key, _operation, grants) do
    Enum.reduce_while(grants, :ok, fn {key, _grant}, :ok ->
      case ExecApprovalStore.delete_session_grant(key) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  @impl true
  def verify_deleted(session_key, _operation, _grants) do
    case ExecApprovalStore.fetch_session_grants(session_key) do
      {:ok, []} -> :ok
      {:ok, _remaining} -> {:error, :grants_remain}
      error -> error
    end
  end

  @impl true
  def restore(_session_key, _operation, grants) do
    Enum.reduce_while(grants, :ok, fn {key, grant}, :ok ->
      case ExecApprovalStore.restore_session_grant(key, grant) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
