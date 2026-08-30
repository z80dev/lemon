defmodule LemonControlPlane.Methods.SessionsExport do
  @moduledoc "Returns a bounded, redacted, integrity-digested session export."

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "sessions.export"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    session_key = params["sessionKey"]
    format = params["format"] || "json"

    cond do
      not is_binary(session_key) or session_key == "" ->
        {:error, {:invalid_request, "sessionKey is required", nil}}

      true ->
        case LemonCore.SessionLifecycle.export(session_key, format: format) do
          {:ok, export} ->
            {:ok, format_export(session_key, export)}

          {:error, :not_found} ->
            {:error, {:not_found, "Session not found", nil}}

          {:error, :unsupported_format} ->
            {:error, {:invalid_params, "format must be json or markdown", nil}}

          {:error, _reason} ->
            {:error, {:internal_error, "Failed to export session", nil}}
        end
    end
  end

  defp format_export(session_key, export) do
    %{
      "sessionKey" => session_key,
      "format" => Atom.to_string(export.format),
      "filename" => export.filename,
      "content" => export.content,
      "sha256" => export.sha256,
      "bytes" => export.bytes,
      "redacted" => true,
      "summary" => %{
        "runCount" => export.run_count,
        "availableRunCount" => export.available_run_count,
        "omittedRunCount" => export.omitted_run_count,
        "exportedAtMs" => export.exported_at_ms,
        "cleanup" => export.cleanup
      }
    }
  end
end
