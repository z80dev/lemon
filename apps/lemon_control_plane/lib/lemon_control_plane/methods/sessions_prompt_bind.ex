defmodule LemonControlPlane.Methods.SessionsPromptBind do
  @moduledoc "Bind the authenticated live connection as a session's question surface."
  @behaviour LemonControlPlane.Method

  def name, do: "sessions.prompt.bind"
  def scopes, do: [:write]

  def handle(params, ctx) do
    key = params["sessionKey"]
    enabled = Map.get(params, "enabled", true)
    connection = Map.get(ctx, :conn_pid)

    cond do
      not is_binary(key) or byte_size(key) not in 1..1024 or not is_boolean(enabled) ->
        {:error, {:invalid_request, "sessionKey and boolean enabled are required", nil}}

      not is_pid(connection) or not Process.alive?(connection) ->
        {:error, {:invalid_request, "A live WebSocket connection is required", nil}}

      true ->
        case LemonCore.AgentRuntime.call(
               :user_prompt_bind,
               [key, connection, enabled],
               {:error, :unavailable}
             ) do
          :ok ->
            {:ok, %{"sessionKey" => key, "bound" => enabled}}

          {:error, :mismatch} ->
            {:error, {:conflict, "Prompt surface belongs to another connection", nil}}

          _ ->
            {:error, {:unavailable, "Session user prompts are unavailable", nil}}
        end
    end
  end
end
