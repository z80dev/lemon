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
      enable_discord = false
      enable_farcaster = false
      enable_email = false
      enable_xmtp = false
      enable_webhook = false
      require_engine_lock = true
      engine_lock_timeout_ms = 60000

      [[gateway.bindings]]
      transport = "telegram"
      chat_id = 123456789
      agent_id = "default"

      [gateway.telegram]
      bot_token_secret = "telegram_bot_token"

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
    :enable_discord,
    :enable_farcaster,
    :enable_email,
    :enable_xmtp,
    :enable_webhook,
    :require_engine_lock,
    :engine_lock_timeout_ms,
    :projects,
    :bindings,
    :sms,
    :queue,
    :telegram,
    :discord,
    :farcaster,
    :email,
    :xmtp,
    :webhook,
    :voice,
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
          bot_token_secret: String.t() | nil,
          compaction: telegram_compaction()
        }

  @type voice_config :: %{
          enabled: boolean() | nil,
          twilio_account_sid: String.t() | nil,
          twilio_account_sid_secret: String.t() | nil,
          twilio_auth_token: String.t() | nil,
          twilio_auth_token_secret: String.t() | nil,
          twilio_phone_number: String.t() | nil,
          deepgram_api_key: String.t() | nil,
          deepgram_api_key_secret: String.t() | nil,
          elevenlabs_api_key: String.t() | nil,
          elevenlabs_api_key_secret: String.t() | nil,
          elevenlabs_voice_id: String.t() | nil,
          elevenlabs_output_format: String.t() | nil,
          websocket_port: integer() | nil,
          public_url: String.t() | nil,
          llm_model: String.t() | nil,
          system_prompt: String.t() | nil,
          max_call_duration_seconds: integer() | nil,
          silence_timeout_ms: integer() | nil
        }

  @type t :: %__MODULE__{
          max_concurrent_runs: integer(),
          default_engine: String.t(),
          default_cwd: String.t() | nil,
          auto_resume: boolean(),
          enable_telegram: boolean(),
          enable_discord: boolean(),
          enable_farcaster: boolean(),
          enable_email: boolean(),
          enable_xmtp: boolean(),
          enable_webhook: boolean(),
          require_engine_lock: boolean(),
          engine_lock_timeout_ms: integer(),
          projects: map(),
          bindings: [binding()],
          sms: map(),
          queue: queue_config(),
          telegram: telegram_config(),
          discord: map(),
          farcaster: map(),
          email: map(),
          xmtp: map(),
          webhook: map(),
          voice: voice_config(),
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
      enable_discord:
        resolve_enable_flag(gateway_settings, "enable_discord", "LEMON_GATEWAY_ENABLE_DISCORD"),
      enable_farcaster:
        resolve_enable_flag(
          gateway_settings,
          "enable_farcaster",
          "LEMON_GATEWAY_ENABLE_FARCASTER"
        ),
      enable_email:
        resolve_enable_flag(gateway_settings, "enable_email", "LEMON_GATEWAY_ENABLE_EMAIL"),
      enable_xmtp:
        resolve_enable_flag(gateway_settings, "enable_xmtp", "LEMON_GATEWAY_ENABLE_XMTP"),
      enable_webhook:
        resolve_enable_flag(gateway_settings, "enable_webhook", "LEMON_GATEWAY_ENABLE_WEBHOOK"),
      require_engine_lock: resolve_require_engine_lock(gateway_settings),
      engine_lock_timeout_ms: resolve_engine_lock_timeout(gateway_settings),
      projects: resolve_projects(gateway_settings),
      bindings: resolve_bindings(gateway_settings),
      sms: resolve_sms(gateway_settings),
      queue: resolve_queue(gateway_settings),
      telegram: resolve_telegram(gateway_settings),
      discord: resolve_discord(gateway_settings),
      farcaster: resolve_passthrough(gateway_settings, "farcaster"),
      email: resolve_passthrough(gateway_settings, "email"),
      xmtp: resolve_xmtp(gateway_settings),
      webhook: resolve_passthrough(gateway_settings, "webhook"),
      voice: resolve_voice(gateway_settings),
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

  defp resolve_enable_flag(settings, key, env_var) do
    Helpers.get_env_bool(
      env_var,
      if(is_nil(settings[key]), do: false, else: settings[key])
    )
  end

  defp resolve_require_engine_lock(settings) do
    Helpers.get_env_bool(
      "LEMON_GATEWAY_REQUIRE_ENGINE_LOCK",
      if(is_nil(settings["require_engine_lock"]),
        do: true,
        else: settings["require_engine_lock"]
      )
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
        transport: if(binding["transport"], do: safe_to_atom(binding["transport"])),
        chat_id: binding["chat_id"],
        topic_id: binding["topic_id"],
        project: binding["project"],
        agent_id: binding["agent_id"],
        default_engine: binding["default_engine"],
        queue_mode: binding["queue_mode"]
      }
    end)
  end

  defp resolve_sms(settings) do
    sms = settings["sms"] || %{}

    auth_token_secret = normalize_optional_string(sms["auth_token_secret"])

    base =
      if auth_token_secret do
        Map.put(sms, "auth_token_secret", auth_token_secret)
      else
        sms
      end

    base
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
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

    # Pass through all telegram config keys (atomized) so the transport sees
    # allowed_chat_ids, poll_interval_ms, debounce_ms, deny_unbound_chats, etc.
    base =
      Enum.reduce(telegram, %{}, fn {k, v}, acc ->
        Map.put(acc, safe_to_atom(k), v)
      end)

    Map.merge(base, %{
      token: resolve_telegram_token(telegram),
      bot_token_secret: normalize_optional_string(telegram["bot_token_secret"]),
      compaction: resolve_telegram_compaction(telegram)
    })
  end

  defp resolve_telegram_token(telegram) do
    token = telegram["bot_token"] || telegram["token"]

    cond do
      is_nil(token) ->
        nil

      is_binary(token) and String.starts_with?(token, "${") and String.ends_with?(token, "}") ->
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

  defp resolve_discord(settings) do
    discord = settings["discord"] || %{}

    base = %{
      bot_token: normalize_optional_string(discord["bot_token"]),
      bot_token_secret: normalize_optional_string(discord["bot_token_secret"]),
      allowed_guild_ids: discord["allowed_guild_ids"],
      allowed_channel_ids: discord["allowed_channel_ids"],
      deny_unbound_channels: resolve_bool_field(discord["deny_unbound_channels"], false)
    }

    reject_nil_values(base)
  end

  defp resolve_xmtp(settings) do
    xmtp = settings["xmtp"] || %{}

    base = %{
      wallet_key_secret: normalize_optional_string(xmtp["wallet_key_secret"])
    }

    xmtp
    |> Enum.reduce(base, fn {k, v}, acc ->
      atom_key = safe_to_atom(k)

      if Map.has_key?(acc, atom_key) do
        acc
      else
        Map.put(acc, atom_key, v)
      end
    end)
    |> reject_nil_values()
  end

  defp resolve_voice(settings) do
    voice = settings["voice"] || %{}

    %{
      enabled: resolve_bool_field(voice["enabled"], false),
      twilio_account_sid: normalize_optional_string(voice["twilio_account_sid"]),
      twilio_account_sid_secret: normalize_optional_string(voice["twilio_account_sid_secret"]),
      twilio_auth_token: normalize_optional_string(voice["twilio_auth_token"]),
      twilio_auth_token_secret: normalize_optional_string(voice["twilio_auth_token_secret"]),
      twilio_phone_number: normalize_optional_string(voice["twilio_phone_number"]),
      deepgram_api_key: normalize_optional_string(voice["deepgram_api_key"]),
      deepgram_api_key_secret: normalize_optional_string(voice["deepgram_api_key_secret"]),
      elevenlabs_api_key: normalize_optional_string(voice["elevenlabs_api_key"]),
      elevenlabs_api_key_secret: normalize_optional_string(voice["elevenlabs_api_key_secret"]),
      elevenlabs_voice_id: normalize_optional_string(voice["elevenlabs_voice_id"]),
      elevenlabs_output_format: normalize_optional_string(voice["elevenlabs_output_format"]),
      websocket_port: voice["websocket_port"],
      public_url: normalize_optional_string(voice["public_url"]),
      llm_model: normalize_optional_string(voice["llm_model"]),
      system_prompt: normalize_optional_string(voice["system_prompt"]),
      max_call_duration_seconds: voice["max_call_duration_seconds"],
      silence_timeout_ms: voice["silence_timeout_ms"]
    }
    |> reject_nil_values()
  end

  defp resolve_passthrough(settings, section) do
    map = settings[section] || %{}

    map
    |> Enum.reduce(%{}, fn {k, v}, acc ->
      Map.put(acc, safe_to_atom(k), v)
    end)
  end

  defp resolve_engines(settings) do
    settings["engines"] || %{}
  end

  defp resolve_bool_field(nil, default), do: default
  defp resolve_bool_field(val, _default) when is_boolean(val), do: val
  defp resolve_bool_field("true", _default), do: true
  defp resolve_bool_field("false", _default), do: false
  defp resolve_bool_field(_, default), do: default

  defp normalize_optional_string(nil), do: nil
  defp normalize_optional_string(""), do: nil
  defp normalize_optional_string(str) when is_binary(str), do: str
  defp normalize_optional_string(_), do: nil

  defp reject_nil_values(map) do
    map
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Enum.into(%{})
  end

  defp safe_to_atom(key) when is_atom(key), do: key

  defp safe_to_atom(key) when is_binary(key) do
    try do
      String.to_existing_atom(key)
    rescue
      ArgumentError -> String.to_atom(key)
    end
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
      "enable_discord" => false,
      "enable_farcaster" => false,
      "enable_email" => false,
      "enable_xmtp" => false,
      "enable_webhook" => false,
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
      "discord" => %{},
      "farcaster" => %{},
      "email" => %{},
      "xmtp" => %{},
      "webhook" => %{},
      "voice" => %{},
      "engines" => %{}
    }
  end
end
