defmodule LemonCore.Config.Agent do
  @moduledoc """
  Agent behavior configuration.

  Inspired by Ironclaw's config/agent.rs, this module handles
  agent-specific configuration like retry behavior, compaction settings,
  and shell configuration.

  ## Configuration

  Preferred configuration is loaded from `[defaults]` + `[runtime]`.
  Legacy `[agent]` remains supported for backward compatibility.

      [defaults]
      provider = "anthropic"
      model = "claude-sonnet-4-20250514"
      thinking_level = "medium"

      [runtime]
      extension_paths = ["./my-extensions"]
      theme = "lemon"

      [runtime.compaction]
      enabled = true
      reserve_tokens = 16384
      keep_recent_tokens = 20000

      [runtime.retry]
      enabled = true
      max_retries = 3
      base_delay_ms = 1000

      [runtime.shell]
      path = "/bin/zsh"
      command_prefix = ""

  Environment variables override file configuration:
  - `LEMON_DEFAULT_PROVIDER`
  - `LEMON_DEFAULT_MODEL`
  - `LEMON_DEFAULT_THINKING_LEVEL`
  - `LEMON_EXTENSION_PATHS` (comma-separated)
  - `LEMON_THEME`
  """

  alias LemonCore.Config.Helpers

  defstruct [
    :default_provider,
    :default_model,
    :default_thinking_level,
    :compaction,
    :retry,
    :shell,
    :extension_paths,
    :theme
  ]

  @type t :: %__MODULE__{
          default_provider: String.t(),
          default_model: String.t(),
          default_thinking_level: String.t(),
          compaction: %{
            enabled: boolean(),
            reserve_tokens: integer(),
            keep_recent_tokens: integer()
          },
          retry: %{
            enabled: boolean(),
            max_retries: integer(),
            base_delay_ms: integer()
          },
          shell: %{
            path: String.t() | nil,
            command_prefix: String.t() | nil
          },
          extension_paths: [String.t()],
          theme: String.t()
        }

  @doc """
  Resolves agent configuration from settings and environment variables.

  Priority: environment variables > TOML config > defaults
  """
  @spec resolve(map()) :: t()
  def resolve(settings) do
    agent_settings = normalize_agent_settings(settings)

    %__MODULE__{
      default_provider: resolve_provider(agent_settings),
      default_model: resolve_model(agent_settings),
      default_thinking_level: resolve_thinking_level(agent_settings),
      compaction: resolve_compaction(agent_settings),
      retry: resolve_retry(agent_settings),
      shell: resolve_shell(agent_settings),
      extension_paths: resolve_extension_paths(agent_settings),
      theme: resolve_theme(agent_settings)
    }
  end

  # Private functions for resolving each config section

  defp normalize_agent_settings(settings) when is_map(settings) do
    legacy_agent = ensure_map(settings["agent"])
    runtime = ensure_map(settings["runtime"])
    defaults = ensure_map(settings["defaults"])

    deep_merge(legacy_agent, runtime)
    |> maybe_put("default_provider", defaults["provider"])
    |> maybe_put("default_model", defaults["model"])
    |> maybe_put("default_thinking_level", defaults["thinking_level"])
  end

  defp normalize_agent_settings(_), do: %{}

  defp resolve_provider(settings) do
    Helpers.get_env("LEMON_DEFAULT_PROVIDER", settings["default_provider"] || "anthropic")
  end

  defp resolve_model(settings) do
    Helpers.get_env(
      "LEMON_DEFAULT_MODEL",
      settings["default_model"] || "claude-sonnet-4-20250514"
    )
  end

  defp resolve_thinking_level(settings) do
    Helpers.get_env(
      "LEMON_DEFAULT_THINKING_LEVEL",
      settings["default_thinking_level"] || "medium"
    )
  end

  defp resolve_compaction(settings) do
    compaction = settings["compaction"] || %{}

    %{
      enabled:
        Helpers.get_env_bool(
          "LEMON_COMPACTION_ENABLED",
          if(is_nil(compaction["enabled"]), do: true, else: compaction["enabled"])
        ),
      reserve_tokens:
        Helpers.get_env_int(
          "LEMON_COMPACTION_RESERVE_TOKENS",
          compaction["reserve_tokens"] || 16_384
        ),
      keep_recent_tokens:
        Helpers.get_env_int(
          "LEMON_COMPACTION_KEEP_RECENT_TOKENS",
          compaction["keep_recent_tokens"] || 20_000
        )
    }
  end

  defp resolve_retry(settings) do
    retry = settings["retry"] || %{}

    %{
      enabled:
        Helpers.get_env_bool(
          "LEMON_RETRY_ENABLED",
          if(is_nil(retry["enabled"]), do: true, else: retry["enabled"])
        ),
      max_retries: Helpers.get_env_int("LEMON_MAX_RETRIES", retry["max_retries"] || 3),
      base_delay_ms: Helpers.get_env_int("LEMON_BASE_DELAY_MS", retry["base_delay_ms"] || 1000)
    }
  end

  defp resolve_shell(settings) do
    shell = settings["shell"] || %{}

    %{
      path: Helpers.get_env("LEMON_SHELL_PATH", shell["path"]),
      command_prefix: Helpers.get_env("LEMON_SHELL_COMMAND_PREFIX", shell["command_prefix"])
    }
  end

  defp resolve_extension_paths(settings) do
    env_paths = Helpers.get_env_list("LEMON_EXTENSION_PATHS")

    if env_paths != [] do
      env_paths
    else
      settings["extension_paths"] || []
    end
  end

  defp resolve_theme(settings) do
    Helpers.get_env("LEMON_THEME", settings["theme"] || "lemon")
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp ensure_map(map) when is_map(map), do: map
  defp ensure_map(_), do: %{}

  defp deep_merge(base, override) when is_map(base) and is_map(override) do
    Map.merge(base, override, fn _key, base_val, override_val ->
      if is_map(base_val) and is_map(override_val) do
        deep_merge(base_val, override_val)
      else
        override_val
      end
    end)
  end

  defp deep_merge(_base, override), do: override

  @doc """
  Returns the default agent configuration as a map.

  This is used as the base configuration that gets overridden by
  user settings.
  """
  @spec defaults() :: map()
  def defaults do
    %{
      "default_provider" => "anthropic",
      "default_model" => "claude-sonnet-4-20250514",
      "default_thinking_level" => "medium",
      "compaction" => %{
        "enabled" => true,
        "reserve_tokens" => 16_384,
        "keep_recent_tokens" => 20_000
      },
      "retry" => %{
        "enabled" => true,
        "max_retries" => 3,
        "base_delay_ms" => 1000
      },
      "shell" => %{
        "path" => nil,
        "command_prefix" => nil
      },
      "extension_paths" => [],
      "theme" => "lemon"
    }
  end
end
