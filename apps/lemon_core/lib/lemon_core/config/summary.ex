defmodule LemonCore.Config.Summary do
  @moduledoc "Redacted configuration summary shared by the runtime CLI and Mix task."

  alias LemonCore.Env

  @spec lines(LemonCore.Config.Modular.t()) :: [String.t()]
  def lines(config) do
    [
      "",
      "Agent:",
      field("Default model", config.agent.default_model, :lemon_default_model),
      field("Default provider", config.agent.default_provider, :lemon_default_provider),
      field("Thinking level", config.agent.default_thinking_level, :lemon_default_thinking_level),
      "",
      "Gateway:",
      field(
        "Max concurrent runs",
        config.gateway.max_concurrent_runs,
        :lemon_gateway_max_concurrent_runs
      ),
      field("Auto resume", config.gateway.auto_resume, :lemon_gateway_auto_resume),
      "  Channels enabled: #{enabled_channels(config.gateway)}",
      "",
      "Logging:",
      field("Level", config.logging.level, :lemon_log_level),
      field("File", config.logging.file, :lemon_log_file),
      "",
      "TUI:",
      field("Theme", config.tui.theme, :lemon_tui_theme),
      field("Debug", config.tui.debug, :lemon_tui_debug),
      "",
      "Providers:"
    ] ++ provider_lines(config.providers.providers)
  end

  defp field(label, value, name) do
    declaration = Env.describe(name)

    source =
      Enum.find([declaration.env_var | declaration.aliases], fn variable ->
        System.get_env(variable) not in [nil, ""]
      end)

    suffix = if source, do: " (from #{source})", else: ""
    "  #{label}: #{format(value)}#{suffix}"
  end

  defp format(nil), do: "(not set)"
  defp format(value), do: to_string(value)

  defp enabled_channels(gateway) do
    gateway
    |> Map.get(:enabled_channels, %{})
    |> Enum.filter(fn {_id, enabled?} -> enabled? end)
    |> Enum.map(fn {id, _enabled?} -> to_string(id) end)
    |> Enum.sort()
    |> case do
      [] -> "(none)"
      ids -> Enum.join(ids, ", ")
    end
  end

  defp provider_lines(providers) when map_size(providers) == 0, do: ["  (none configured)"]

  defp provider_lines(providers) do
    providers
    |> Enum.sort_by(fn {name, _config} -> name end)
    |> Enum.map(fn {name, config} ->
      has_key = if config[:api_key], do: "✓", else: "✗"
      "  #{name}: API key #{has_key}"
    end)
  end
end
