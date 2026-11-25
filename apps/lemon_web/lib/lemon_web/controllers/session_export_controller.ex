defmodule LemonWeb.SessionExportController do
  @moduledoc "Downloads a bounded, always-redacted session export."

  use LemonWeb, :controller

  alias LemonControlPlane.SessionLifecycle

  def show(conn, %{"session_key" => session_key, "format" => format})
      when format in ["json", "markdown"] do
    case SessionLifecycle.export(session_key, format: format) do
      {:ok, export} ->
        send_download(conn, {:binary, export.content},
          filename: export.filename,
          content_type: content_type(export.format)
        )

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> text("Session not found")

      {:error, _reason} ->
        conn |> put_status(:service_unavailable) |> text("Session export is unavailable")
    end
  rescue
    _ -> conn |> put_status(:service_unavailable) |> text("Session export is unavailable")
  end

  def show(conn, _params) do
    conn |> put_status(:bad_request) |> text("Unsupported export format")
  end

  defp content_type(:json), do: "application/json"
  defp content_type(:markdown), do: "text/markdown"
end
