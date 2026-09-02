defmodule LemonControlPlane.Methods.ChatAbort do
  @moduledoc """
  Handler for the chat.abort method.

  Aborts an active run.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "chat.abort"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, ctx) do
    session_key = params["sessionKey"]
    run_id = params["runId"]
    router_mod = Map.get(ctx, :router_mod, LemonRouter)

    cond do
      is_nil(session_key) and is_nil(run_id) ->
        {:error, {:invalid_request, "sessionKey or runId is required", nil}}

      run_id ->
        # Abort by run_id
        dispatch_status = safe_abort_run(router_mod, run_id)
        aborted = dispatch_status == "sent"

        {:ok,
         %{
           "aborted" => aborted,
           "runId" => run_id,
           "summary" => summary("run", run_id, dispatch_status, aborted)
         }}

      session_key ->
        # Abort by session_key
        dispatch_status = safe_abort_session(router_mod, session_key)
        aborted = dispatch_status == "sent"

        {:ok,
         %{
           "aborted" => aborted,
           "sessionKey" => session_key,
           "summary" => summary("session", session_key, dispatch_status, aborted)
         }}
    end
  end

  defp safe_abort_run(router_mod, run_id) do
    normalize_abort_result(router_mod.abort_run(run_id, :user_requested))
  rescue
    _error -> "outcome_unknown"
  catch
    _kind, _reason -> "outcome_unknown"
  end

  defp safe_abort_session(router_mod, session_key) do
    normalize_abort_result(router_mod.abort(session_key, :user_requested))
  rescue
    _error -> "outcome_unknown"
  catch
    _kind, _reason -> "outcome_unknown"
  end

  defp normalize_abort_result(:ok), do: "sent"
  defp normalize_abort_result({:error, :unavailable}), do: "router_unavailable"
  defp normalize_abort_result({:error, :outcome_unknown}), do: "outcome_unknown"
  defp normalize_abort_result({:error, _reason}), do: "rejected"
  defp normalize_abort_result(_unexpected), do: "outcome_unknown"

  defp summary(target_type, target_id, dispatch_status, aborted) do
    %{
      "aborted" => aborted,
      "targetType" => target_type,
      "targetId" => target_id,
      "reason" => "user_requested",
      "dispatchStatus" => dispatch_status,
      "cleanup" => %{
        "includesPrompt" => false,
        "includesMessages" => false,
        "includesSecretValues" => false
      }
    }
  end
end
