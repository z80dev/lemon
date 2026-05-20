defmodule LemonControlPlane.Methods.LogsTail do
  @moduledoc """
  Handler for the logs.tail method.

  Returns recent log entries from the system.
  """

  @behaviour LemonControlPlane.Method

  @default_limit 100
  @max_limit 1_000

  @impl true
  def name, do: "logs.tail"

  @impl true
  def scopes, do: [:read]

  @impl true
  def handle(params, _ctx) do
    params = params || %{}
    limit = normalize_limit(get_param(params, "limit") || get_param(params, "lines"))
    level = normalize_level(get_param(params, "level") || get_param(params, "filter"))

    logs = get_recent_logs(limit, level) |> redact_logs()

    {:ok,
     %{
       "logs" => logs,
       "total" => length(logs),
       "filters" => %{"limit" => limit, "level" => level},
       "summary" => summary(logs, limit, level)
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

  defp summary(logs, limit, level) do
    %{
      "count" => length(logs),
      "limit" => limit,
      "level" => level,
      "levelCounts" => count_by_level(logs),
      "cleanup" => %{
        "includesLogMessages" => true,
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

  defp log_level(entry) when is_map(entry) do
    entry[:level] || entry["level"] || entry[:severity] || entry["severity"]
  end

  defp log_level(_), do: nil

  defp redact_logs(logs) when is_list(logs), do: Enum.map(logs, &redact_value/1)
  defp redact_logs(logs), do: redact_value(logs)

  defp redact_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} ->
      if sensitive_key?(key) do
        {key, %{"redacted" => true, "kind" => "secret"}}
      else
        {key, redact_value(nested)}
      end
    end)
  end

  defp redact_value(value) when is_list(value), do: Enum.map(value, &redact_value/1)
  defp redact_value(value) when is_binary(value), do: redact_text(value)
  defp redact_value(value), do: value

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

  defp sensitive_key?(key) do
    normalized = key |> to_string() |> String.downcase()

    Enum.any?(
      ["api_key", "apikey", "secret", "token", "password", "private_key", "credential"],
      &String.contains?(normalized, &1)
    )
  end

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
