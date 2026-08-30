defmodule LemonControlPlane.Methods.SessionsPrune do
  @moduledoc "Dry-run-first, confirmation-bound stale-session pruning."

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
      confirm_token: params["confirmToken"]
    ]

    case LemonCore.SessionLifecycle.prune(opts) do
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

      {:error, _reason} ->
        {:error, {:internal_error, "Failed to prune sessions", nil}}
    end
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
