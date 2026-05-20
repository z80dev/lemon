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
  def handle(params, _ctx) do
    session_key = params["sessionKey"]
    run_id = params["runId"]

    cond do
      is_nil(session_key) and is_nil(run_id) ->
        {:error, {:invalid_request, "sessionKey or runId is required", nil}}

      run_id ->
        # Abort by run_id
        dispatch_status = safe_abort_run(run_id)

        {:ok,
         %{
           "aborted" => true,
           "runId" => run_id,
           "summary" => summary("run", run_id, dispatch_status)
         }}

      session_key ->
        # Abort by session_key
        dispatch_status = safe_abort_session(session_key)

        {:ok,
         %{
           "aborted" => true,
           "sessionKey" => session_key,
           "summary" => summary("session", session_key, dispatch_status)
         }}
    end
  end

  defp safe_abort_run(run_id) do
    LemonRouter.Router.abort_run(run_id, :user_requested)
    "sent"
  rescue
    ArgumentError -> "router_unavailable"
    UndefinedFunctionError -> "router_unavailable"
  catch
    :exit, _ -> "router_unavailable"
  end

  defp safe_abort_session(session_key) do
    LemonRouter.Router.abort(session_key, :user_requested)
    "sent"
  rescue
    ArgumentError -> "router_unavailable"
    UndefinedFunctionError -> "router_unavailable"
  catch
    :exit, _ -> "router_unavailable"
  end

  defp summary(target_type, target_id, dispatch_status) do
    %{
      "aborted" => true,
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
