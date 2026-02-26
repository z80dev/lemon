defmodule LemonCore.Config.TUI do
  @moduledoc """
  TUI (Terminal User Interface) configuration for themes and debug mode.

  Inspired by Ironclaw's modular config pattern, this module handles
  TUI-specific configuration including theme selection and debug settings.

  ## Configuration

  Configuration is loaded from the TOML config file under `[tui]`:

      [tui]
      theme = "lemon"
      debug = false

  Environment variables override file configuration:
  - `LEMON_TUI_THEME`
  - `LEMON_TUI_DEBUG`

  Note: The agent theme setting (under `[agent]`) is separate from the TUI theme.
  The TUI theme controls the terminal interface appearance, while the agent theme
  may affect agent behavior or output formatting.
  """

  alias LemonCore.Config.Helpers

  defstruct [
    :theme,
    :debug
  ]

  @type t :: %__MODULE__{
          theme: String.t(),
          debug: boolean()
        }

  @doc """
  Resolves TUI configuration from settings and environment variables.

  Priority: environment variables > TOML config > defaults
  """
  @spec resolve(map()) :: t()
  def resolve(settings) do
    tui_settings = settings["tui"] || %{}

    %__MODULE__{
      theme: resolve_theme(tui_settings),
      debug: resolve_debug(tui_settings)
    }
  end

  # Private functions for resolving each config section

  defp resolve_theme(settings) do
    Helpers.get_env("LEMON_TUI_THEME", settings["theme"] || "lemon")
  end

  defp resolve_debug(settings) do
    Helpers.get_env_bool(
      "LEMON_TUI_DEBUG",
      if(is_nil(settings["debug"]), do: false, else: settings["debug"])
    )
  end

  @doc """
  Returns the default TUI configuration as a map.

  This is used as the base configuration that gets overridden by
  user settings.
  """
  @spec defaults() :: map()
  def defaults do
    %{
      "theme" => "lemon",
      "debug" => false
    }
  end
end
