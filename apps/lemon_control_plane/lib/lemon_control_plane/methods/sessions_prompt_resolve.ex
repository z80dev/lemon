defmodule LemonControlPlane.Methods.SessionsPromptResolve do
  @moduledoc "Resolve a question for the exact session/run and bound WebSocket connection."
  @behaviour LemonControlPlane.Method

  def name, do: "sessions.prompt.resolve"
  def scopes, do: [:write]

  def handle(params, ctx) do
    id = params["promptId"]
    key = params["sessionKey"]
    run_id = params["runId"]
    action = params["action"]
    content = Map.get(params, "content", %{})
    connection = Map.get(ctx, :conn_pid)

    cond do
      not identity?(id) or not identity?(key) or not (is_nil(run_id) or identity?(run_id)) ->
        {:error, {:invalid_request, "Valid promptId, sessionKey and runId are required", nil}}

      action not in ["accept", "decline", "cancel"] or not valid_content?(content) ->
        {:error,
         {:invalid_request, "A valid prompt action and bounded answer content are required", nil}}

      not is_pid(connection) ->
        {:error, {:invalid_request, "A WebSocket connection is required", nil}}

      true ->
        response = %{"action" => action, "content" => content}

        case LemonCore.AgentRuntime.call(
               :user_prompt_resolve,
               [id, key, run_id, response, connection],
               {:error, :unavailable}
             ) do
          :ok ->
            {:ok, %{"resolved" => true, "promptId" => id, "sessionKey" => key, "runId" => run_id}}

          {:error, :not_found} ->
            {:error, {:not_found, "Question is no longer pending", nil}}

          {:error, :mismatch} ->
            {:error, {:conflict, "Question identity or bound connection changed", nil}}

          {:error, :expired} ->
            {:error, {:conflict, "Question expired; no answer was selected", nil}}

          _ ->
            {:error, {:unavailable, "Session user prompts are unavailable", nil}}
        end
    end
  end

  defp identity?(value), do: is_binary(value) and byte_size(value) in 1..1024

  defp valid_content?(content) when is_map(content) and map_size(content) <= 16 do
    Enum.all?(content, fn {key, value} ->
      is_binary(key) and byte_size(key) <= 136 and
        (text?(value) or (is_list(value) and length(value) <= 20 and Enum.all?(value, &text?/1)))
    end)
  end

  defp valid_content?(_), do: false
  defp text?(value), do: is_binary(value) and byte_size(value) <= 4_000 and String.valid?(value)
end
