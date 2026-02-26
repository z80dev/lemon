defmodule LemonControlPlane.Methods.SessionsPreview do
  @moduledoc """
  Handler for the sessions.preview method.

  Returns a preview of session history.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "sessions.preview"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    session_key = params["sessionKey"]

    if is_nil(session_key) do
      {:error, {:invalid_request, "sessionKey is required", nil}}
    else
      # Get recent history for this session via LemonCore.Store
      limit = params["limit"] || 10
      history = get_session_history(session_key, limit)

      {:ok, %{
        "sessionKey" => session_key,
        "preview" => history
      }}
    end
  end

  defp get_session_history(session_key, limit) do
    LemonCore.Store.get_run_history(session_key, limit: limit)
    |> Enum.map(fn {run_id, data} -> format_history_entry(run_id, data) end)
  rescue
    _ -> []
  end

  defp format_history_entry(run_id, data) do
    summary = data[:summary] || %{}
    completed = summary[:completed] || %{}
    prompt = get_prompt_from_data(data)

    %{
      "runId" => run_id,
      "prompt" => truncate(prompt, 100),
      "answer" => truncate(completed[:answer], 200),
      "ok" => completed[:ok],
      "timestampMs" => data[:started_at]
    }
  end

  defp get_prompt_from_data(data) do
    # Try to extract prompt from the first event or summary
    summary = data[:summary] || %{}
    cond do
      is_binary(summary[:prompt]) -> summary[:prompt]
      is_list(data[:events]) ->
        data[:events]
        |> Enum.find(fn e -> is_map(e) and (e[:type] == :prompt or e["type"] == "prompt") end)
        |> case do
          %{text: text} -> text
          %{"text" => text} -> text
          _ -> nil
        end
      true -> nil
    end
  end

  defp truncate(nil, _), do: nil
  defp truncate(text, max) when is_binary(text) and byte_size(text) <= max, do: text
  defp truncate(text, max) when is_binary(text), do: String.slice(text, 0, max) <> "..."
  defp truncate(_, _), do: nil
end
