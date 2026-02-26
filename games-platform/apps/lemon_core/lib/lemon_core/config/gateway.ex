defmodule LemonCore.Config.Gateway do
  @moduledoc """
  Gateway configuration for Telegram, SMS, and engine management.

  Inspired by Ironclaw's modular config pattern, this module handles
  gateway-specific configuration including Telegram bot settings,
  SMS configuration, engine bindings, and queue management.

  ## Configuration

  Configuration is loaded from the TOML config file under `[gateway]`:

      [gateway]
      max_concurrent_runs = 2
      default_engine = "lemon"
      default_cwd = "~/workspace"
      auto_resume = false
      enable_telegram = true
      require_engine_lock = true
      engine_lock_timeout_ms = 60000

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 123456789
      agent_id = "default"

      [gateway.telegram]
      token = "${TELEGRAM_BOT_TOKEN}"

      [gateway.telegram.compaction]
      enabled = true
      context_window_tokens = 400000
      reserve_tokens = 16384
      trigger_ratio = 0.9

  Environment variables override file configuration:
  - `LEMON_GATEWAY_MAX_CONCURRENT_RUNS`
  - `LEMON_GATEWAY_DEFAULT_ENGINE`
  - `LEMON_GATEWAY_DEFAULT_CWD`
  - `LEMON_GATEWAY_ENABLE_TELEGRAM`
  - `LEMON_GATEWAY_REQUIRE_ENGINE_LOCK`
  - `LEMON_GATEWAY_ENGINE_LOCK_TIMEOUT_MS`
  """

  alias LemonCore.Config.Helpers

  defstruct [
    :max_concurrent_runs,
    :default_engine,
    :default_cwd,
    :auto_resume,
    :enable_telegram,
    :require_engine_lock,
    :engine_lock_timeout_ms,
    :projects,
    :bindings,
    :sms,
    :queue,
    :telegram,
    :engines
  ]

  @type binding :: %{
          transport: String.t(),
          chat_id: integer() | nil,
          agent_id: String.t() | nil
        }

  @type queue_config :: %{
          mode: String.t() | nil,
          cap: integer() | nil,
          drop: String.t() | nil
        }

  @type telegram_compaction :: %{
          enabled: boolean(),
          context_window_tokens: integer(),
          reserve_tokens: integer(),
          trigger_ratio: float()
        }

  @type telegram_config :: %{
          token: String.t() | nil,
          compaction: telegram_compaction()
        }

  @type t :: %__MODULE__{
          max_concurrent_runs: integer(),
          default_engine: String.t(),
          default_cwd: String.t() | nil,
          auto_resume: boolean(),
          enable_telegram: boolean(),
          require_engine_lock: boolean(),
          engine_lock_timeout_ms: integer(),
          projects: map(),
          bindings: [binding()],
          sms: map(),
          queue: queue_config(),
          telegram: telegram_config(),
          engines: map()
        }

  @doc """
  Resolves gateway configuration from settings and environment variables.

  Priority: environment variables > TOML config > defaults
  """
  @spec resolve(map()) :: t()
  def resolve(settings) do
    gateway_settings = settings["gateway"] || %{}

    %__MODULE__{
      max_concurrent_runs: resolve_max_concurrent_runs(gateway_settings),
      default_engine: resolve_default_engine(gateway_settings),
      default_cwd: resolve_default_cwd(gateway_settings),
      auto_resume: resolve_auto_resume(gateway_settings),
      enable_telegram: resolve_enable_telegram(gateway_settings),
      require_engine_lock: resolve_require_engine_lock(gateway_settings),
      engine_lock_timeout_ms: resolve_engine_lock_timeout(gateway_settings),
      projects: resolve_projects(gateway_settings),
      bindings: resolve_bindings(gateway_settings),
      sms: resolve_sms(gateway_settings),
      queue: resolve_queue(gateway_settings),
      telegram: resolve_telegram(gateway_settings),
      engines: resolve_engines(gateway_settings)
    }
  end

  # Private functions for resolving each config section

  defp resolve_max_concurrent_runs(settings) do
    Helpers.get_env_int(
      "LEMON_GATEWAY_MAX_CONCURRENT_RUNS",
      settings["max_concurrent_runs"] || 2
    )
  end

  defp resolve_default_engine(settings) do
    Helpers.get_env("LEMON_GATEWAY_DEFAULT_ENGINE", settings["default_engine"] || "lemon")
  end

  defp resolve_default_cwd(settings) do
    cwd = Helpers.get_env("LEMON_GATEWAY_DEFAULT_CWD", settings["default_cwd"])

    if cwd do
      String.trim(cwd)
    else
      nil
    end
  end

  defp resolve_auto_resume(settings) do
    Helpers.get_env_bool(
      "LEMON_GATEWAY_AUTO_RESUME",
      if(is_nil(settings["auto_resume"]), do: false, else: settings["auto_resume"])
    )
  end

  defp resolve_enable_telegram(settings) do
    Helpers.get_env_bool(
      "LEMON_GATEWAY_ENABLE_TELEGRAM",
      if(is_nil(settings["enable_telegram"]), do: false, else: settings["enable_telegram"])
    )
  end

  defp resolve_require_engine_lock(settings) do
    Helpers.get_env_bool(
      "LEMON_GATEWAY_REQUIRE_ENGINE_LOCK",
      if(is_nil(settings["require_engine_lock"]), do: true, else: settings["require_engine_lock"])
    )
  end

  defp resolve_engine_lock_timeout(settings) do
    Helpers.get_env_int(
      "LEMON_GATEWAY_ENGINE_LOCK_TIMEOUT_MS",
      settings["engine_lock_timeout_ms"] || 60_000
    )
  end

  defp resolve_projects(settings) do
    settings["projects"] || %{}
  end

  defp resolve_bindings(settings) do
    bindings = settings["bindings"] || []

    Enum.map(bindings, fn binding ->
      %{
        transport: binding["transport"],
        chat_id: binding["chat_id"],
        agent_id: binding["agent_id"]
      }
    end)
  end

  defp resolve_sms(settings) do
    settings["sms"] || %{}
  end

  defp resolve_queue(settings) do
    queue = settings["queue"] || %{}

    %{
      mode: queue["mode"],
      cap: queue["cap"],
      drop: queue["drop"]
    }
  end

  defp resolve_telegram(settings) do
    telegram = settings["telegram"] || %{}

    %{
      token: resolve_telegram_token(telegram),
      compaction: resolve_telegram_compaction(telegram)
    }
  end

  defp resolve_telegram_token(telegram) do
    token = telegram["token"]

    cond do
      is_nil(token) ->
        nil

      String.starts_with?(token, "${") and String.ends_with?(token, "}") ->
        # Extract env var name from ${VAR_NAME}
        env_var = token |> String.slice(2..-2//1)
        Helpers.get_env(env_var)

      true ->
        token
    end
  end

  defp resolve_telegram_compaction(telegram) do
    compaction = telegram["compaction"] || %{}

    %{
      enabled:
        Helpers.get_env_bool(
          "LEMON_TELEGRAM_COMPACTION_ENABLED",
          if(is_nil(compaction["enabled"]), do: true, else: compaction["enabled"])
        ),
      context_window_tokens:
        Helpers.get_env_int(
          "LEMON_TELEGRAM_COMPACTION_CONTEXT_WINDOW",
          compaction["context_window_tokens"] || 400_000
        ),
      reserve_tokens:
        Helpers.get_env_int(
          "LEMON_TELEGRAM_COMPACTION_RESERVE_TOKENS",
          compaction["reserve_tokens"] || 16_384
        ),
      trigger_ratio:
        Helpers.get_env_float(
          "LEMON_TELEGRAM_COMPACTION_TRIGGER_RATIO",
          compaction["trigger_ratio"] || 0.9
        )
    }
  end

  defp resolve_engines(settings) do
    settings["engines"] || %{}
  end

  @doc """
  Returns the default gateway configuration as a map.

  This is used as the base configuration that gets overridden by
  user settings.
  """
  @spec defaults() :: map()
  def defaults do
    %{
      "max_concurrent_runs" => 2,
      "default_engine" => "lemon",
      "default_cwd" => nil,
      "auto_resume" => false,
      "enable_telegram" => false,
      "require_engine_lock" => true,
      "engine_lock_timeout_ms" => 60_000,
      "projects" => %{},
      "bindings" => [],
      "sms" => %{},
      "queue" => %{
        "mode" => nil,
        "cap" => nil,
        "drop" => nil
      },
      "telegram" => %{},
      "engines" => %{}
    }
  end
end
