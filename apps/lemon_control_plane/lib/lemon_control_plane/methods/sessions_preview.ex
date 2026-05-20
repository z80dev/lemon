defmodule LemonControlPlane.Methods.SessionsPreview do
  @moduledoc """
  Handler for the sessions.preview method.

  Returns a preview of session history.
  """

  @behaviour LemonControlPlane.Method

  @default_limit 10
  @max_limit 100

  @impl true
  def name, do: "sessions.preview"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    session_key = get_param(params, "sessionKey")

    if is_nil(session_key) or session_key == "" do
      {:error, {:invalid_request, "sessionKey is required", nil}}
    else
      limit = normalize_limit(get_param(params, "limit"))
      history = get_session_history(session_key, limit)

      {:ok,
       %{
         "sessionKey" => session_key,
         "preview" => history,
         "summary" => summary(history, limit)
       }}
    end
  end

  defp get_session_history(session_key, limit) do
    LemonCore.RunStore.history(session_key, limit: limit)
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
      "prompt" => preview_text(prompt, 100),
      "answer" => preview_text(completed[:answer], 200),
      "ok" => completed[:ok],
      "timestampMs" => data[:started_at],
      "truncated" => truncated?(prompt, 100) or truncated?(completed[:answer], 200)
    }
  end

  defp get_prompt_from_data(data) do
    summary = data[:summary] || %{}

    cond do
      is_binary(summary[:prompt]) ->
        summary[:prompt]

      is_list(data[:events]) ->
        data[:events]
        |> Enum.find(fn e -> is_map(e) and (e[:type] == :prompt or e["type"] == "prompt") end)
        |> case do
          %{text: text} -> text
          %{"text" => text} -> text
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp truncate(nil, _), do: nil
  defp truncate(text, max) when is_binary(text) and byte_size(text) <= max, do: text
  defp truncate(text, max) when is_binary(text), do: String.slice(text, 0, max) <> "..."
  defp truncate(_, _), do: nil

  defp preview_text(text, max) when is_binary(text), do: text |> redact_text() |> truncate(max)
  defp preview_text(_, _), do: nil

  defp redact_text(text) do
    text
    |> then(fn value ->
      Regex.replace(
        ~r/(?i)\b(api[_-]?key|token|secret|password|private[_-]?key|credential)\s*=\s*([^\s,;]+)/,
        value,
        "\\1=[REDACTED]"
      )
    end)
    |> then(fn value ->
      Regex.replace(~r/(?i)\bbearer\s+[A-Za-z0-9._~+\/=-]+/, value, "Bearer [REDACTED]")
    end)
  end

  defp truncated?(text, max) when is_binary(text), do: byte_size(text) > max
  defp truncated?(_, _), do: false

  defp summary(history, limit) do
    %{
      "count" => length(history),
      "limit" => limit,
      "okCount" => Enum.count(history, &(&1["ok"] == true)),
      "errorCount" => Enum.count(history, &(&1["ok"] == false)),
      "truncatedCount" => Enum.count(history, &(&1["truncated"] == true)),
      "cleanup" => %{
        "includesFullText" => false,
        "includesRawEvents" => false,
        "includesRunRecords" => false,
        "redactsSensitivePreviews" => true,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _} when parsed > 0 -> min(parsed, @max_limit)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit

  defp get_param(params, key) when is_map(params) and is_binary(key) do
    underscored = Macro.underscore(key)

    cond do
      Map.has_key?(params, key) -> Map.get(params, key)
      Map.has_key?(params, underscored) -> Map.get(params, underscored)
      true -> nil
    end
  end

  defp get_param(_params, _key), do: nil
end
