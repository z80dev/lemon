defmodule LemonControlPlane.Methods.SessionsMaintain do
  @moduledoc "Preview-first, confirmation-bound native journal and artifact maintenance."

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "sessions.maintain"

  @impl true
  def scopes, do: [:admin]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}

    with :ok <- validate(params) do
      LemonCore.SessionLifecycle.maintenance(
        older_than_ms: params["olderThanMs"],
        dry_run: Map.get(params, "dryRun", true),
        confirm_token: params["confirmToken"]
      )
      |> result()
    end
  end

  defp validate(params) when is_map(params) do
    cond do
      not is_integer(params["olderThanMs"]) or params["olderThanMs"] <= 0 ->
        result({:error, :invalid_older_than_ms})

      not is_boolean(Map.get(params, "dryRun", true)) ->
        {:error, {:invalid_params, "dryRun must be a boolean", nil}}

      not is_nil(params["confirmToken"]) and not is_binary(params["confirmToken"]) ->
        {:error, {:invalid_params, "confirmToken must be a string", nil}}

      true ->
        :ok
    end
  end

  defp validate(_params), do: {:error, {:invalid_params, "Expected maintenance parameters", nil}}

  defp result({:ok, report}), do: {:ok, format_report(report)}

  defp result({:error, :invalid_older_than_ms}),
    do:
      {:error,
       {:invalid_params, "olderThanMs must be a positive integer",
        %{"reason" => "invalid_older_than_ms"}}}

  defp result({:error, :confirmation_required}),
    do:
      {:error,
       {:conflict, "Run a maintenance preview and provide its exact cutoff and confirmToken",
        %{"reason" => "confirmation_required"}}}

  defp result({:error, :confirmation_mismatch}),
    do:
      {:error,
       {:conflict, "Maintenance candidates changed; run a new preview",
        %{"reason" => "confirmation_mismatch"}}}

  defp result({:error, {:partial_failure, report}}),
    do:
      {:error,
       {:internal_error, "Maintenance stopped with partial changes; run a new preview",
        %{"reason" => "partial_failure", "report" => format_report(report)}}}

  defp result({:error, _reason}),
    do:
      {:error,
       {:unavailable, "Session maintenance could not be completed safely",
        %{"reason" => "maintenance_unavailable"}}}

  defp format_report(report) do
    %{
      "dryRun" => report.dry_run,
      "olderThanMs" => report.older_than_ms,
      "confirmationToken" => report.confirmation_token,
      "archiveCount" => report.archive_count,
      "orphanCount" => report.orphan_count,
      "archivedCount" => report.archived_count,
      "sweptCount" => report.swept_count,
      "candidates" => Enum.map(report.candidates, &format_candidate/1),
      "verified" => report.verified
    }
  end

  defp format_candidate(candidate) do
    %{
      "kind" => Atom.to_string(candidate.kind),
      "id" => candidate.id,
      "bytes" => candidate.bytes
    }
  end
end
