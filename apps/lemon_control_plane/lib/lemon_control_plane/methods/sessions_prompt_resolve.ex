defmodule LemonControlPlane.Methods.SessionsPromptResolve do
  @moduledoc "Resolve a question for the exact session/run and bound WebSocket connection."
  @behaviour LemonControlPlane.Method

  @max_fields 64

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

      action not in ["accept", "decline", "cancel"] or not valid_content?(content) or
          not valid_records?(params["answers"], ["name", "question", "answer"]) or
          not valid_records?(params["notes"], ["name", "question", "option", "value", "text"]) ->
        {:error,
         {:invalid_request, "A valid prompt action and bounded answer content are required", nil}}

      not is_pid(connection) ->
        {:error, {:invalid_request, "A WebSocket connection is required", nil}}

      true ->
        response =
          %{"action" => action, "content" => content}
          |> put_present(params, "answers")
          |> put_present(params, "notes")

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

  # Form data (`ask` html) admits numbers; question answers stay text or text lists.
  defp valid_content?(content) when is_map(content) and map_size(content) <= @max_fields do
    Enum.all?(content, fn {key, value} ->
      is_binary(key) and byte_size(key) <= 256 and
        (is_number(value) or text?(value) or
           (is_list(value) and length(value) <= @max_fields and Enum.all?(value, &text?/1)))
    end)
  end

  defp valid_content?(_), do: false

  # Optional readable form summary lines supplied by the rendering client.
  defp valid_records?(nil, _keys), do: true

  defp valid_records?(records, keys) when is_list(records) and length(records) <= @max_fields do
    Enum.all?(records, fn record ->
      is_map(record) and
        Enum.all?(keys, fn key -> is_binary(record[key]) and byte_size(record[key]) <= 16_400 end)
    end)
  end

  defp valid_records?(_records, _keys), do: false

  defp put_present(response, params, key) do
    case params[key] do
      nil -> response
      value -> Map.put(response, key, value)
    end
  end

  defp text?(value), do: is_binary(value) and byte_size(value) <= 4_000 and String.valid?(value)
end
