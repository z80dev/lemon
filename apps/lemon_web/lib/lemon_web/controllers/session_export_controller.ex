defmodule LemonWeb.SessionExportController do
  @moduledoc "Downloads a bounded, always-redacted session export."

  use LemonWeb, :controller

  alias LemonCore.SessionLifecycle

  def show(conn, %{"session_key" => session_key, "format" => format}) do
    case SessionLifecycle.export(session_key, format: format) do
      {:ok, export} ->
        send_download(conn, {:binary, export.content},
          filename: export.filename,
          content_type: content_type(export.format)
        )

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> text("Session not found")

      {:error, :unsupported_format} ->
        conn |> put_status(:bad_request) |> text("Unsupported export format")
    end
  end

  defp content_type(:json), do: "application/json"
  defp content_type(:markdown), do: "text/markdown"
end
