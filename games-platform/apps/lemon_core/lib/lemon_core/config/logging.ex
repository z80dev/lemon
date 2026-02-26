defmodule LemonCore.Config.Logging do
  @moduledoc """
  Logging configuration for file output and log levels.

  Inspired by Ironclaw's modular config pattern, this module handles
  logging-specific configuration including log file paths, levels,
  rotation settings, and compression options.

  ## Configuration

  Configuration is loaded from the TOML config file under `[logging]`:

      [logging]
      file = "./logs/lemon.log"
      level = "debug"
      max_no_bytes = 10485760
      max_no_files = 5
      compress_on_rotate = true
      filesync_repeat_interval = 5000

  Environment variables override file configuration:
  - `LEMON_LOG_FILE`
  - `LEMON_LOG_LEVEL`
  """

  alias LemonCore.Config.Helpers

  defstruct [
    :file,
    :level,
    :max_no_bytes,
    :max_no_files,
    :compress_on_rotate,
    :filesync_repeat_interval
  ]

  @type log_level :: :debug | :info | :warning | :error | nil

  @type t :: %__MODULE__{
          file: String.t() | nil,
          level: log_level(),
          max_no_bytes: integer() | nil,
          max_no_files: integer() | nil,
          compress_on_rotate: boolean() | nil,
          filesync_repeat_interval: integer() | nil
        }

  @doc """
  Resolves logging configuration from settings and environment variables.

  Priority: environment variables > TOML config > defaults
  """
  @spec resolve(map()) :: t()
  def resolve(settings) do
    logging_settings = settings["logging"] || %{}

    %__MODULE__{
      file: resolve_file(logging_settings),
      level: resolve_level(logging_settings),
      max_no_bytes: resolve_max_no_bytes(logging_settings),
      max_no_files: resolve_max_no_files(logging_settings),
      compress_on_rotate: resolve_compress_on_rotate(logging_settings),
      filesync_repeat_interval: resolve_filesync_repeat_interval(logging_settings)
    }
  end

  # Private functions for resolving each config section

  defp resolve_file(settings) do
    Helpers.get_env("LEMON_LOG_FILE", settings["file"])
  end

  defp resolve_level(settings) do
    level = Helpers.get_env("LEMON_LOG_LEVEL", settings["level"])

    if level do
      parse_log_level(level)
    else
      nil
    end
  end

  defp parse_log_level(level) when is_binary(level) do
    case String.downcase(level) do
      "debug" -> :debug
      "info" -> :info
      "warning" -> :warning
      "warn" -> :warning
      "error" -> :error
      _ -> nil
    end
  end

  defp parse_log_level(level) when is_atom(level) do
    level
  end

  defp parse_log_level(_), do: nil

  defp resolve_max_no_bytes(settings),
    do: resolve_env_integer("LEMON_LOG_MAX_NO_BYTES", settings["max_no_bytes"])

  defp resolve_max_no_files(settings),
    do: resolve_env_integer("LEMON_LOG_MAX_NO_FILES", settings["max_no_files"])

  defp resolve_compress_on_rotate(settings) do
    if Helpers.get_env("LEMON_LOG_COMPRESS_ON_ROTATE") do
      Helpers.get_env_bool("LEMON_LOG_COMPRESS_ON_ROTATE", false)
    else
      settings["compress_on_rotate"]
    end
  end

  defp resolve_filesync_repeat_interval(settings),
    do: resolve_env_integer("LEMON_LOG_FILESYNC_REPEAT_INTERVAL", settings["filesync_repeat_interval"])

  defp resolve_env_integer(env_var, fallback) do
    case Helpers.get_env(env_var) do
      nil -> fallback
      val ->
        case Integer.parse(val) do
          {int, ""} -> int
          _ -> fallback
        end
    end
  end

  @doc """
  Returns the default logging configuration as a map.

  This is used as the base configuration that gets overridden by
  user settings.
  """
  @spec defaults() :: map()
  def defaults do
    %{
      "file" => nil,
      "level" => nil,
      "max_no_bytes" => nil,
      "max_no_files" => nil,
      "compress_on_rotate" => nil,
      "filesync_repeat_interval" => nil
    }
  end
end
