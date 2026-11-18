defmodule LemonControlPlane.Methods.LogsTail do
  @moduledoc """
  Handler for the logs.tail method.

  Returns recent log entries from the system through the shared redacting
  projector. Free-form log messages are content and need `operator.content`;
  read-only callers get each entry's level, timestamp and module only.
  """

  import LemonControlPlane.Methods.Params, only: [get_param: 2]

  @behaviour LemonControlPlane.Method

  alias LemonControlPlane.Auth.Authorize

  @default_limit 100
  @max_limit 1_000
  @metadata_keys [
    "level",
    :level,
    "severity",
    :severity,
    "timestampMs",
    "timestamp_ms",
    :timestamp_ms,
    "module",
    :module
  ]

  @impl true
  def name, do: "logs.tail"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, ctx) do
    params = params || %{}
    content? = Authorize.content?(ctx)
    limit = normalize_limit(get_param(params, "limit") || get_param(params, "lines"))
    level = normalize_level(get_param(params, "level") || get_param(params, "filter"))

    logs = limit |> get_recent_logs(level) |> project_logs(content?)

    {:ok,
     %{
       "logs" => logs,
       "total" => length(logs),
       "filters" => %{"limit" => limit, "level" => level},
       "contentWithheld" => not content?,
       "summary" => summary(logs, limit, level, content?)
     }}
  end

  defp get_recent_logs(limit, level) do
    mod = Application.get_env(:lemon_control_plane, :log_ring_module, LemonControlPlane.LogRing)

    if Code.ensure_loaded?(mod) and function_exported?(mod, :get_logs, 2) do
      apply(mod, :get_logs, [limit, level])
    else
      # Fallback: return empty list
      []
    end
  rescue
    _ -> []
  end

  defp project_logs(logs, content?) when is_list(logs),
    do: Enum.map(logs, &project_entry(&1, content?))

  defp project_logs(_logs, _content?), do: []

  defp project_entry(entry, true), do: LemonCore.Redact.project(entry)

  defp project_entry(entry, false) when is_map(entry),
    do: entry |> Map.take(@metadata_keys) |> LemonCore.Redact.project()

  defp project_entry(_entry, false), do: %{}

  defp summary(logs, limit, level, content?) do
    %{
      "count" => length(logs),
      "limit" => limit,
      "level" => level,
      "levelCounts" => count_by_level(logs),
      "cleanup" => %{
        "includesLogMessages" => content?,
        "redactsSensitiveLogValues" => true,
        "includesRawProcessState" => false,
        "includesCredentials" => false,
        "includesSecretValues" => false
      }
    }
  end

  defp count_by_level(logs) do
    logs
    |> Enum.map(&log_level/1)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.frequencies()
  end

  defp log_level(entry) when is_map(entry), do: entry["level"] || entry["severity"]
  defp log_level(_), do: nil

  defp normalize_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)

  defp normalize_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, _} when parsed > 0 -> min(parsed, @max_limit)
      _ -> @default_limit
    end
  end

  defp normalize_limit(_), do: @default_limit

  defp normalize_level(nil), do: nil
  defp normalize_level(""), do: nil
  defp normalize_level(level) when is_binary(level), do: String.downcase(level)

  defp normalize_level(level) when is_atom(level),
    do: level |> Atom.to_string() |> String.downcase()

  defp normalize_level(_), do: nil
end
