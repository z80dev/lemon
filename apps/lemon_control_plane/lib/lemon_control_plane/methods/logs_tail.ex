defmodule LemonControlPlane.Methods.LogsTail do
  @moduledoc """
  Handler for the logs.tail method.

  Returns recent log entries from the system.
  """

  @behaviour LemonControlPlane.Method

  @impl true
  def name, do: "logs.tail"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    limit = params["limit"] || 100
    level = params["level"]  # Optional: filter by level (debug, info, warn, error)

    # Get logs from the log ring buffer if available
    logs = get_recent_logs(limit, level)

    {:ok, %{"logs" => logs}}
  end

  defp get_recent_logs(limit, level) do
    # Try to get from LemonControlPlane.LogRing if available
    if Code.ensure_loaded?(LemonControlPlane.LogRing) and
       function_exported?(LemonControlPlane.LogRing, :get_logs, 2) do
      LemonControlPlane.LogRing.get_logs(limit, level)
    else
      # Fallback: return empty list
      []
    end
  rescue
    _ -> []
  end
end
