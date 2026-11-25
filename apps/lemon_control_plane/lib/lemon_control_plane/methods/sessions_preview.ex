defmodule LemonControlPlane.Methods.SessionsPreview do
  @moduledoc """
  Handler for the sessions.preview method.

  Returns a preview of session history. Prompt and answer previews are content
  and need `operator.content`; read-only callers get run metadata and sizes.
  """

  import LemonControlPlane.Methods.Params, only: [get_param: 2]

  alias LemonControlPlane.Auth.Authorize
  alias LemonControlPlane.Protocol.Errors

  @behaviour LemonControlPlane.Method

  @default_limit 10
  @max_limit 100

  @impl true
  def name, do: "sessions.preview"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, ctx) do
    params = params || %{}

    case get_param(params, "sessionKey") do
      session_key when is_binary(session_key) and session_key != "" ->
        preview(session_key, normalize_limit(get_param(params, "limit")), Authorize.content?(ctx))

      _ ->
        {:error, {:invalid_request, "sessionKey is required", nil}}
    end
  end

  defp preview(session_key, limit, content?) do
    case LemonCore.RunStore.fetch_history(session_key, limit: limit) do
      {:ok, runs} ->
        history =
          Enum.map(runs, fn {run_id, data} -> format_history_entry(run_id, data, content?) end)

        {:ok,
         %{
           "sessionKey" => session_key,
           "preview" => history,
           "summary" => summary(history, limit, content?),
           "contentWithheld" => not content?
         }}

      {:error, _reason} ->
        {:error, Errors.unavailable("Session history is unavailable")}
    end
  end

  defp format_history_entry(run_id, data, false) do
    summary = data[:summary] || %{}
    completed = summary[:completed] || %{}

    %{
      "runId" => run_id,
      "ok" => completed[:ok],
      "timestampMs" => data[:started_at],
      "promptBytes" => byte_size_or_zero(get_prompt_from_data(data)),
      "answerBytes" => byte_size_or_zero(completed[:answer])
    }
  end

  defp format_history_entry(run_id, data, true) do
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

  defp byte_size_or_zero(text) when is_binary(text), do: byte_size(text)
  defp byte_size_or_zero(_), do: 0

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

  defp preview_text(text, max) when is_binary(text),
    do: text |> LemonCore.Redact.text() |> truncate(max)

  defp preview_text(_, _), do: nil

  defp truncated?(text, max) when is_binary(text), do: byte_size(text) > max
  defp truncated?(_, _), do: false

  defp summary(history, limit, content?) do
    %{
      "count" => length(history),
      "limit" => limit,
      "okCount" => Enum.count(history, &(&1["ok"] == true)),
      "errorCount" => Enum.count(history, &(&1["ok"] == false)),
      "truncatedCount" => Enum.count(history, &(&1["truncated"] == true)),
      "cleanup" => %{
        "includesFullText" => false,
        "includesPreviews" => content?,
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
end
