defmodule LemonControlPlane.Methods.ChatHistory do
  @moduledoc """
  Handler for the chat.history method.

  Returns the conversation history for a session.
  """

  @behaviour LemonControlPlane.Method

  @default_limit 50
  @max_limit 200
  @preview_bytes 500

  @impl true
  def name, do: "chat.history"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    session_key = get_param(params, "sessionKey")
    limit = normalize_limit(get_param(params, "limit"))
    before_id = get_param(params, "beforeId")
    include_full_text = truthy?(get_param(params, "includeFullText"), true)

    if is_nil(session_key) or session_key == "" do
      {:error, {:invalid_request, "sessionKey is required", nil}}
    else
      history = get_chat_history(session_key, limit, before_id, include_full_text)

      {:ok,
       %{
         "sessionKey" => session_key,
         "messages" => history,
         "summary" => summary(history, limit, before_id, include_full_text)
       }}
    end
  end

  defp get_chat_history(session_key, limit, before_id, include_full_text) do
    runs = LemonCore.RunStore.history(session_key, limit: limit * 2)

    runs
    |> Enum.flat_map(fn {run_id, data} ->
      extract_messages(run_id, data, include_full_text)
    end)
    |> apply_before_id(before_id)
    |> Enum.take(limit)
  rescue
    _ -> []
  end

  defp extract_messages(run_id, data, include_full_text) do
    summary = data[:summary] || %{}
    completed = summary[:completed] || %{}
    timestamp = data[:started_at]

    messages = []

    # Add user prompt if available
    prompt = get_in(summary, [:prompt]) || get_prompt_from_events(data[:events])

    messages =
      if prompt do
        [
          %{
            "id" => "#{run_id}_user",
            "role" => "user",
            "content" => maybe_preview(prompt, include_full_text),
            "timestampMs" => timestamp,
            "truncated" => truncated?(prompt, include_full_text)
          }
          | messages
        ]
      else
        messages
      end

    # Add assistant response
    answer = completed[:answer]

    messages =
      if answer && answer != "" do
        [
          %{
            "id" => "#{run_id}_assistant",
            "role" => "assistant",
            "content" => maybe_preview(answer, include_full_text),
            "timestampMs" => timestamp,
            "ok" => completed[:ok],
            "truncated" => truncated?(answer, include_full_text)
          }
          | messages
        ]
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

  defp apply_before_id(messages, nil), do: messages
  defp apply_before_id(messages, ""), do: messages

  defp apply_before_id(messages, before_id) do
    messages
    |> Enum.drop_while(&(&1["id"] != before_id))
    |> case do
      [] -> []
      [_matched | rest] -> rest
    end
  end

  defp summary(messages, limit, before_id, include_full_text) do
    %{
      "count" => length(messages),
      "limit" => limit,
      "beforeId" => before_id,
      "roleCounts" => count_by(messages, "role"),
      "okCount" => Enum.count(messages, &(&1["ok"] == true)),
      "errorCount" => Enum.count(messages, &(&1["ok"] == false)),
      "truncatedCount" => Enum.count(messages, &(&1["truncated"] == true)),
      "cleanup" => %{
        "includesMessageBodies" => true,
        "includesFullText" => include_full_text == true,
        "includesRawEvents" => false,
        "includesRunRecords" => false,
        "redactsSensitivePreviews" => include_full_text != true,
        "includesCredentials" => false,
        "includesSecretValues" => include_full_text == true
      }
    }
  end

  defp count_by(rows, key) do
    rows
    |> Enum.map(& &1[key])
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.frequencies()
  end

  defp maybe_preview(text, true), do: text

  defp maybe_preview(text, false) when is_binary(text) do
    text = redact_text(text)

    if byte_size(text) > @preview_bytes do
      String.slice(text, 0, @preview_bytes) <> "..."
    else
      text
    end
  end

  defp maybe_preview(text, false), do: text

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

  defp truncated?(text, true) when is_binary(text), do: false
  defp truncated?(text, false) when is_binary(text), do: byte_size(text) > @preview_bytes
  defp truncated?(_, _), do: false

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _} when parsed > 0 -> min(parsed, @max_limit)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit

  defp truthy?(value, _default) when is_boolean(value), do: value
  defp truthy?(value, _default) when value in [1, "1", "true", "TRUE", "yes", "on"], do: true
  defp truthy?(value, _default) when value in [0, "0", "false", "FALSE", "no", "off"], do: false
  defp truthy?(_value, default), do: default

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
