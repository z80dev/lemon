defmodule LemonControlPlane.Methods.ChatSend do
  @moduledoc """
  Handler for the chat.send method.

  Sends a message to a session.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "chat.send"

  @impl true
  def scopes, do: [:write]

  @impl true
  def handle(params, _ctx) do
    session_key = params["sessionKey"]
    prompt = params["prompt"] || params["message"]
    agent_id = params["agentId"]
    queue_mode = parse_queue_mode(params["queueMode"])

    cond do
      is_nil(session_key) ->
        {:error, {:invalid_request, "sessionKey is required", nil}}

      is_nil(prompt) ->
        {:error, {:invalid_request, "prompt is required", nil}}

      true ->
        submit_params = %{
          origin: :control_plane,
          session_key: session_key,
          agent_id: agent_id,
          prompt: prompt,
          queue_mode: queue_mode,
          meta: %{
            control_plane: true
          }
        }

        case LemonRouter.submit(submit_params) do
          {:ok, run_id} ->
            {:ok, %{
              "runId" => run_id,
              "sessionKey" => session_key
            }}

          {:error, reason} ->
            {:error, {:internal_error, inspect(reason), nil}}
        end
    end
  end

  defp parse_queue_mode(nil), do: :collect
  defp parse_queue_mode("collect"), do: :collect
  defp parse_queue_mode("followup"), do: :followup
  defp parse_queue_mode("steer"), do: :steer
  defp parse_queue_mode("interrupt"), do: :interrupt
  defp parse_queue_mode(_), do: :collect
end
