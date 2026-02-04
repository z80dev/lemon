defmodule LemonControlPlane.Methods.ChatHistory do
  @moduledoc """
  Handler for the chat.history method.

  Returns the conversation history for a session.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "chat.history"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    session_key = params["sessionKey"]
    limit = params["limit"] || 50
    before_id = params["beforeId"]

    if is_nil(session_key) do
      {:error, {:invalid_request, "sessionKey is required", nil}}
    else
      history = get_chat_history(session_key, limit, before_id)
      {:ok, %{"sessionKey" => session_key, "messages" => history}}
    end
  end

  defp get_chat_history(session_key, limit, before_id) do
    # Get run history and extract messages
    if Code.ensure_loaded?(LemonGateway.Store) do
      runs = LemonGateway.Store.get_run_history(session_key, limit: limit * 2)

      runs
      |> Enum.flat_map(fn {run_id, data} ->
        extract_messages(run_id, data, before_id)
      end)
      |> Enum.take(limit)
    else
      []
    end
  rescue
    _ -> []
  end

  defp extract_messages(run_id, data, _before_id) do
    summary = data[:summary] || %{}
    completed = summary[:completed] || %{}
    timestamp = data[:started_at]

    messages = []

    # Add user prompt if available
    prompt = get_in(summary, [:prompt]) || get_prompt_from_events(data[:events])
    messages = if prompt do
      [%{
        "id" => "#{run_id}_user",
        "role" => "user",
        "content" => prompt,
        "timestampMs" => timestamp
      } | messages]
    else
      messages
    end

    # Add assistant response
    answer = completed[:answer]
    messages = if answer && answer != "" do
      [%{
        "id" => "#{run_id}_assistant",
        "role" => "assistant",
        "content" => answer,
        "timestampMs" => timestamp,
        "ok" => completed[:ok]
      } | messages]
    else
      messages
    end

    Enum.reverse(messages)
  end

  defp get_prompt_from_events(nil), do: nil
  defp get_prompt_from_events(events) when is_list(events) do
    events
    |> Enum.find(fn e -> is_map(e) and (e[:type] == :prompt or e["type"] == "prompt") end)
    |> case do
      %{text: text} -> text
      %{"text" => text} -> text
      _ -> nil
    end
  end
  defp get_prompt_from_events(_), do: nil
end
