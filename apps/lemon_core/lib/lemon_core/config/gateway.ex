defmodule LemonCore.Config.Gateway do
  @moduledoc """
  Gateway configuration: engine management, bindings, queueing and the
  per-platform channel sections.

  Inspired by Ironclaw's modular config pattern, this module handles
  gateway-specific configuration including engine bindings, SMS and voice
  settings, and queue management.

  Anything named after a specific chat platform is resolved by the application
  that implements it: the modules registered under
  `config :lemon_core, :gateway_channels` own their `[gateway.<id>]` sub-table,
  their `enable_<id>` flag and their own environment variables. See
  `LemonCore.Config.Gateway.Channel`. Their results are exposed as
  `channels` and `enabled_channels`, which `LemonCore.Config` flattens back
  onto the legacy gateway map as `gateway[<id>]` and `gateway[:enable_<id>]`.

  ## Configuration

  Configuration is loaded from the TOML config file under `[gateway]`:

      [gateway]
      max_concurrent_runs = 2
      default_engine = "lemon"
      default_cwd = "~/workspace"
      auto_resume = false
      enable_webhook = false
      require_engine_lock = true
      engine_lock_timeout_ms = 60000

      [[gateway.bindings]]
      transport = "foo"
      chat_id = 123456789
      agent_id = "default"

  Environment variables override file configuration:
  - `LEMON_GATEWAY_MAX_CONCURRENT_RUNS`
  - `LEMON_GATEWAY_DEFAULT_ENGINE`
  - `LEMON_GATEWAY_DEFAULT_CWD`
  - `LEMON_GATEWAY_REQUIRE_ENGINE_LOCK`
  - `LEMON_GATEWAY_ENGINE_LOCK_TIMEOUT_MS`

  A registered channel declares and reads its own `LEMON_GATEWAY_ENABLE_<ID>`
  variable; the library never names one.
  """

  alias LemonCore.Config.Gateway.Channel
  alias LemonCore.Env

  defstruct [
    :max_concurrent_runs,
    :default_engine,
    :default_cwd,
    :auto_resume,
    :enable_webhook,
    :require_engine_lock,
    :engine_lock_timeout_ms,
    :projects,
    :bindings,
    :sms,
    :queue,
    :enabled_channels,
    :channels,
    :email,
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
          enable_webhook: boolean(),
          require_engine_lock: boolean(),
          engine_lock_timeout_ms: integer(),
          projects: map(),
          bindings: [binding()],
          sms: map(),
          queue: queue_config(),
          enabled_channels: %{optional(atom()) => boolean()},
          channels: %{optional(atom()) => map()},
          email: map(),
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
    channels = Channel.registered()

    %__MODULE__{
      max_concurrent_runs: resolve_max_concurrent_runs(gateway_settings),
      default_engine: resolve_default_engine(gateway_settings),
      default_cwd: resolve_default_cwd(gateway_settings),
      auto_resume: resolve_auto_resume(gateway_settings),
      enable_webhook:
        resolve_enable_flag(gateway_settings, "enable_webhook", :lemon_gateway_enable_webhook),
      require_engine_lock: resolve_require_engine_lock(gateway_settings),
      engine_lock_timeout_ms: resolve_engine_lock_timeout(gateway_settings),
      projects: resolve_projects(gateway_settings),
      bindings: resolve_bindings(gateway_settings),
      sms: resolve_sms(gateway_settings),
      queue: resolve_queue(gateway_settings),
      enabled_channels: resolve_enabled_channels(gateway_settings, channels),
      channels: resolve_channels(gateway_settings, channels),
      email: resolve_passthrough(gateway_settings, "email"),
      webhook: resolve_passthrough(gateway_settings, "webhook"),
      voice: resolve_voice(gateway_settings),
      engines: resolve_engines(gateway_settings)
    }
  end

  # Private functions for resolving each config section

  defp resolve_max_concurrent_runs(settings) do
    Env.get(:lemon_gateway_max_concurrent_runs, default: settings["max_concurrent_runs"] || 2)
  end

  defp resolve_default_engine(settings) do
    Env.get(:lemon_gateway_default_engine, default: settings["default_engine"] || "lemon")
  end

  defp resolve_default_cwd(settings) do
    cwd = Env.get(:lemon_gateway_default_cwd, default: settings["default_cwd"])

    if cwd do
      String.trim(cwd)
    else
      nil
    end
  end

  defp resolve_auto_resume(settings) do
    Env.get(:lemon_gateway_auto_resume,
      default: if(is_nil(settings["auto_resume"]), do: false, else: settings["auto_resume"])
    )
  end

  defp resolve_enable_flag(settings, key, name) do
    Env.get(name, default: if(is_nil(settings[key]), do: false, else: settings[key]))
  end

  defp resolve_enabled_channels(settings, modules) do
    Map.new(modules, fn module ->
      id = module.id()
      configured = resolve_bool_field(settings["enable_#{id}"], false)
      {id, module.enabled?(configured) == true}
    end)
  end

  defp resolve_channels(settings, modules) do
    Map.new(modules, fn module ->
      id = module.id()
      {id, module.resolve(settings[Atom.to_string(id)] || %{})}
    end)
  end

  defp resolve_require_engine_lock(settings) do
    Env.get(:lemon_gateway_require_engine_lock,
      default:
        if(is_nil(settings["require_engine_lock"]),
          do: true,
          else: settings["require_engine_lock"]
        )
    )
  end

  defp resolve_engine_lock_timeout(settings) do
    Env.get(:lemon_gateway_engine_lock_timeout_ms,
      default: settings["engine_lock_timeout_ms"] || 60_000
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
  user settings. Every registered channel contributes its own disabled flag
  and empty section, so the shape follows the build rather than a hardcoded
  list of platforms.
  """
  @spec defaults() :: map()
  def defaults do
    base = %{
      "max_concurrent_runs" => 2,
      "default_engine" => "lemon",
      "default_cwd" => nil,
      "auto_resume" => false,
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
      "email" => %{},
      "webhook" => %{},
      "voice" => %{},
      "engines" => %{}
    }

    Enum.reduce(Channel.ids(), base, fn id, acc ->
      section = Atom.to_string(id)

      acc
      |> Map.put("enable_#{section}", false)
      |> Map.put(section, %{})
    end)
  end
end
