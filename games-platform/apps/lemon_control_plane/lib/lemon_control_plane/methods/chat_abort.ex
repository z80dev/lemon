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
        LemonRouter.Router.abort_run(run_id, :user_requested)
        {:ok, %{"aborted" => true, "runId" => run_id}}

      session_key ->
        # Abort by session_key
        LemonRouter.Router.abort(session_key, :user_requested)
        {:ok, %{"aborted" => true, "sessionKey" => session_key}}
    end
  end
end
