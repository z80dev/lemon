defmodule LemonControlPlane.Methods.SessionsPrune do
  @moduledoc """
  Dry-run-first, confirmation-bound stale-session pruning.

  Each confirmed deletion runs under the session's lifecycle fence with the
  session proven idle (`LemonControlPlane.Methods.SessionLifecycleFence`); a
  busy or fenced session is reported as a failure and left unchanged.
  """

  alias LemonControlPlane.Methods.SessionLifecycleFence
  alias LemonControlPlane.SessionLifecycle

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "sessions.prune"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    opts = [
      older_than_ms: params["olderThanMs"],
      archived_only: Map.get(params, "archivedOnly", true),
      include_pinned: Map.get(params, "includePinned", false),
      dry_run: Map.get(params, "dryRun", true),
      confirm_token: params["confirmToken"],
      fenced_delete: &fenced_delete/2
    ]

    case SessionLifecycle.prune(opts) do
      {:ok, result} ->
        {:ok, format_result(result)}

      {:error, :invalid_older_than_ms} ->
        {:error, {:invalid_params, "olderThanMs must be a positive integer", nil}}

      {:error, :confirmation_required} ->
        {:error, {:conflict, "Run a dry-run preview and provide its confirmToken", nil}}

      {:error, :confirmation_mismatch} ->
        {:error, {:conflict, "Prune candidates changed; run a new dry-run preview", nil}}

      {:error, {:partial_failure, result}} ->
        {:error,
         {:internal_error, "Some session deletions could not be verified",
          safe_failure_summary(result)}}
    end
  end

  defp fenced_delete(session_key, delete_opts) do
    SessionLifecycleFence.run(session_key, :delete, fn generation ->
      SessionLifecycle.delete(session_key, [fence_generation: generation] ++ delete_opts)
    end)
  end

  defp format_result(result) do
    %{
      "dryRun" => result.dry_run,
      "olderThanMs" => result.older_than_ms,
      "archivedOnly" => result.archived_only,
      "includePinned" => result.include_pinned,
      "confirmToken" => result.confirmation_token,
      "candidateSessionKeys" => result.candidate_session_keys,
      "candidateCount" => result.candidate_count,
      "deletedSessionKeys" => result.deleted_session_keys,
      "deletedCount" => result.deleted_count,
      "verified" => result.verified,
      "summary" => %{
        "requiresConfirmation" => result.dry_run and result.candidate_count > 0,
        "cleanup" => %{
          "archivedOnlyByDefault" => true,
          "pinnedExcludedByDefault" => true,
          "confirmationBindsExactCandidates" => true,
          "deletionVerified" => result.verified,
          "includesMessages" => false,
          "includesRunEvents" => false,
          "includesCredentials" => false,
          "includesSecretValues" => false
        }
      }
    }
  end

  defp safe_failure_summary(result) do
    %{
      "candidateCount" => result.candidate_count,
      "deletedCount" => result.deleted_count,
      "failureCount" => length(result.failures || [])
    }
  end
end
