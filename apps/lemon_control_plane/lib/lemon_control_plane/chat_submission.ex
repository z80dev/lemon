defmodule LemonControlPlane.ChatSubmission do
  @moduledoc false

  alias LemonControlPlane.Protocol.Errors

  @modes [
    :new_run,
    :queued,
    :merged,
    :steer_pending,
    :steer,
    :steer_backlog_pending,
    :steer_backlog,
    :redirect_pending,
    :redirect,
    :interrupt
  ]

  def run_id(params) do
    case Map.fetch(params, "runId") do
      :error ->
        {:ok, LemonCore.Id.run_id()}

      {:ok, id} when is_binary(id) ->
        if byte_size(id) <= 128 and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.:-]*\z/, id),
          do: {:ok, id},
          else: invalid_id()

      _ ->
        invalid_id()
    end
  end

  def invocation_context_key(params) do
    case Map.fetch(params, "invocationContextKey") do
      :error ->
        {:ok, nil}

      {:ok, key} ->
        validate_context_key(key, "invocationContextKey")
    end
  end

  def memory_context_key(params, invocation_key) do
    case Map.fetch(params, "memoryContextKey") do
      :error ->
        {:ok, nil}

      {:ok, _key} when is_nil(invocation_key) ->
        {:error, {:invalid_request, "memoryContextKey requires invocationContextKey", nil}}

      {:ok, key} ->
        validate_context_key(key, "memoryContextKey")
    end
  end

  defp validate_context_key(key, field) do
    case LemonCore.RunRequest.validate_invocation_context_key(key) do
      :ok ->
        {:ok, key}

      {:error, _} ->
        {:error,
         {:invalid_request,
          "#{field} must be a nonempty opaque ASCII digest of at most 128 bytes", nil}}
    end
  end

  def shared_memory_grant(params, ctx, invocation_key, memory_key) do
    case Map.get(params, "sharedMemoryGrant", false) do
      false ->
        {:ok, false}

      true when is_nil(invocation_key) or is_nil(memory_key) ->
        {:error,
         {:invalid_request,
          "sharedMemoryGrant requires invocationContextKey and memoryContextKey", nil}}

      true ->
        case Map.get(ctx, :auth) do
          %{role: :operator} = auth ->
            case LemonControlPlane.Auth.Authorize.authorize(auth, "chat.send", [:admin]) do
              :ok -> {:ok, true}
              error -> error
            end

          _ ->
            {:error,
             {:forbidden, "sharedMemoryGrant requires an authenticated operator with admin scope"}}
        end

      _ ->
        {:error, {:invalid_request, "sharedMemoryGrant must be a boolean", nil}}
    end
  end

  def attach_execution_context(request, params, ctx) do
    with {:ok, invocation_key} <- invocation_context_key(params),
         {:ok, memory_key} <- memory_context_key(params, invocation_key),
         {:ok, _shared_grant} <- shared_memory_grant(params, ctx, invocation_key, memory_key),
         :ok <- authorize_invocation_proof(params, ctx, invocation_key, memory_key) do
      case LemonCore.InvocationProof.attach_execution_context(request, params) do
        {:ok, _} = result ->
          result

        {:error, :invalid_invocation_proof} ->
          {:error,
           {:invalid_request, "invocationProof does not match the admitted execution", nil}}

        {:error, _} ->
          {:error, {:invalid_request, "Invocation execution context is invalid", nil}}
      end
    end
  end

  defp authorize_invocation_proof(params, ctx, invocation_key, memory_key) do
    if Map.has_key?(params, "invocationProof") do
      with true <-
             Map.has_key?(params, "runId") and
               not is_nil(invocation_key) and not is_nil(memory_key),
           %{role: :operator} = auth <- Map.get(ctx, :auth),
           :ok <- LemonControlPlane.Auth.Authorize.authorize(auth, "chat.send", [:admin]) do
        :ok
      else
        false ->
          {:error,
           {:invalid_request,
            "invocationProof requires fixed runId and verified invocationContextKey and memoryContextKey",
            nil}}

        {:error, _} = error ->
          error

        _ ->
          {:error,
           {:forbidden, "invocationProof requires an authenticated operator with admin scope"}}
      end
    else
      :ok
    end
  end

  def submit(request, callback) do
    case callback.(request) do
      {:ok,
       %{
         run_id: id,
         session_key: session_key,
         state: :accepted,
         effective_mode: mode,
         target_run_id: target
       } = receipt}
      when id == request.run_id and session_key == request.session_key and mode in @modes and
             is_binary(target) and target != "" ->
        {:ok, project(receipt)}

      {:error, :outcome_unknown} ->
        unknown(request)

      {:error, :run_id_conflict} ->
        {:error,
         Errors.error(:conflict, "Run ID belongs to a different request", %{
           "code" => "RUN_ID_CONFLICT",
           "runId" => request.run_id,
           "retrySafe" => false
         })}

      {:error, _} ->
        {:error, {:internal_error, "Chat submission failed", nil}}

      _ ->
        unknown(request)
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
    {:error,
     Errors.error(:unavailable, "Chat submission outcome is unknown", %{
       "code" => "SUBMISSION_OUTCOME_UNKNOWN",
       "runId" => request.run_id,
       "sessionKey" => request.session_key,
       "retrySafe" => false
     })}
  end

  defp invalid_id do
    {:error,
     {:invalid_request,
      "runId must be 1-128 ASCII letters, digits, underscores, dots, colons or hyphens, starting with a letter or digit",
      nil}}
  end
end
