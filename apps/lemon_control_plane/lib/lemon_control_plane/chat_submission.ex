defmodule LemonControlPlane.ChatSubmission do
  @moduledoc false

  alias LemonControlPlane.Protocol.Errors

  @modes [:new_run, :queued, :merged, :steer_pending, :steer, :steer_backlog_pending,
          :steer_backlog, :redirect_pending, :redirect, :interrupt]

  def run_id(params) do
    case Map.fetch(params, "runId") do
      :error -> {:ok, LemonCore.Id.run_id()}
      {:ok, id} when is_binary(id) ->
        if byte_size(id) <= 128 and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/, id),
          do: {:ok, id},
          else: invalid_id()
      _ -> invalid_id()
    end
  end

  def submit(request, callback) do
    case callback.(request) do
      {:ok, %{run_id: id, session_key: session_key, state: :accepted,
              effective_mode: mode, target_run_id: target} = receipt}
      when id == request.run_id and session_key == request.session_key and mode in @modes and
             is_binary(target) and target != "" ->
        {:ok, project(receipt)}

      {:error, :outcome_unknown} -> unknown(request)
      {:error, :run_id_conflict} ->
        {:error, Errors.error(:conflict, "Run ID belongs to a different request", %{
          "code" => "RUN_ID_CONFLICT", "runId" => request.run_id, "retrySafe" => false
        })}
      {:error, _} -> {:error, {:internal_error, "Chat submission failed", nil}}
      _ -> unknown(request)
    end
  rescue
    _ -> unknown(request)
  catch
    _, _ -> unknown(request)
  end

  def project(receipt) do
    %{
      "runId" => receipt.run_id,
      "sessionKey" => receipt.session_key,
      "state" => to_string(receipt.state),
      "effectiveMode" => if(receipt.effective_mode, do: to_string(receipt.effective_mode)),
      "targetRunId" => receipt.target_run_id,
      "retrySafe" => false
    }
  end

  defp unknown(request) do
    {:error, Errors.error(:unavailable, "Chat submission outcome is unknown", %{
      "code" => "SUBMISSION_OUTCOME_UNKNOWN", "runId" => request.run_id,
      "sessionKey" => request.session_key, "retrySafe" => false
    })}
  end

  defp invalid_id do
    {:error, {:invalid_request,
      "runId must be 1-128 ASCII letters, digits, underscores, dots, colons or hyphens, starting with a letter or digit", nil}}
  end
end
