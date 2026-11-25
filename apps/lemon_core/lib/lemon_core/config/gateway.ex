defmodule LemonCore.Config.Gateway do
  @moduledoc """
  Gateway configuration: bindings, projects, and per-platform channel sections.

  Inspired by Ironclaw's modular config pattern, this module handles
  gateway-specific configuration including bindings, SMS and voice settings.

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
      default_cwd = "~/workspace"
      auto_resume = false
      enable_webhook = false

      [[gateway.bindings]]
      transport = "foo"
      chat_id = 123456789
      agent_id = "default"

  Environment variables override file configuration:
  - `LEMON_GATEWAY_MAX_CONCURRENT_RUNS`
  - `LEMON_GATEWAY_DEFAULT_CWD`

  A registered channel declares and reads its own `LEMON_GATEWAY_ENABLE_<ID>`
  variable; the library never names one.
  """

  alias LemonCore.Config.Gateway.Channel
  alias LemonCore.Env

  defstruct [
    :max_concurrent_runs,
    :default_cwd,
    :auto_resume,
    :enable_webhook,
    :projects,
    :bindings,
    :sms,
    :enabled_channels,
    :channels,
    :email,
    :webhook,
    :voice
  ]

  @type binding :: %{
          transport: String.t(),
          chat_id: integer() | nil,
          topic_id: integer() | nil,
          project: String.t() | nil,
          agent_id: String.t() | nil,
          queue_mode: String.t() | nil
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
          default_cwd: String.t() | nil,
          auto_resume: boolean(),
          enable_webhook: boolean(),
          projects: map(),
          bindings: [binding()],
          sms: map(),
          enabled_channels: %{optional(atom()) => boolean()},
          channels: %{optional(atom()) => map()},
          email: map(),
          webhook: map(),
          voice: voice_config()
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
      default_cwd: resolve_default_cwd(gateway_settings),
      auto_resume: resolve_auto_resume(gateway_settings),
      enable_webhook:
        resolve_enable_flag(gateway_settings, "enable_webhook", :lemon_gateway_enable_webhook),
      projects: resolve_projects(gateway_settings),
      bindings: resolve_bindings(gateway_settings),
      sms: resolve_sms(gateway_settings),
      enabled_channels: resolve_enabled_channels(gateway_settings, channels),
      channels: resolve_channels(gateway_settings, channels),
      email: resolve_passthrough(gateway_settings, "email"),
      webhook: resolve_passthrough(gateway_settings, "webhook"),
      voice: resolve_voice(gateway_settings)
    }
  end

  # Private functions for resolving each config section

  defp resolve_max_concurrent_runs(settings) do
    Env.get(:lemon_gateway_max_concurrent_runs, default: settings["max_concurrent_runs"] || 2)
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
      {id, module.enabled?(configured)}
    end)
  end

  defp resolve_channels(settings, modules) do
    Map.new(modules, fn module ->
      id = module.id()
      section = settings[Atom.to_string(id)] || %{}

      resolved = module.resolve(section)

      resolved =
        if Map.has_key?(section, "voice_replies") do
          Map.put(resolved, :voice_replies, resolve_voice_replies(section["voice_replies"]))
        else
          resolved
        end

      {id, resolved}
    end)
  end

  defp resolve_voice_replies(nil), do: %{enabled: false}

  defp resolve_voice_replies(settings) when is_map(settings) do
    %{
      enabled: resolve_bool_field(settings["enabled"], false),
      provider: normalize_optional_string(settings["provider"]),
      model: normalize_optional_string(settings["model"]),
      base_url: normalize_optional_string(settings["base_url"]),
      api_key: normalize_optional_string(settings["api_key"]),
      api_key_secret: normalize_optional_string(settings["api_key_secret"]),
      voice: normalize_optional_string(settings["voice"]),
      price_per_million_characters: settings["price_per_million_characters"]
    }
    |> reject_nil_values()
  end

  defp resolve_voice_replies(value), do: value

  defp resolve_projects(settings) do
    settings["projects"] || %{}
  end

  defp resolve_bindings(settings) do
    bindings = settings["bindings"] || []
    transports = Map.new(Channel.ids(), &{Atom.to_string(&1), &1})

    Enum.map(bindings, fn binding ->
      %{
        transport: resolve_transport(binding["transport"], transports),
        chat_id: binding["chat_id"],
        topic_id: binding["topic_id"],
        project: binding["project"],
        agent_id: binding["agent_id"],
        queue_mode: binding["queue_mode"]
      }
    end)
  end

  # Registered channel ids map to their atoms; any other transport stays a
  # string (matched by name in `LemonCore.BindingResolver`), so config input
  # never creates atoms.
  defp resolve_transport(transport, transports) when is_binary(transport),
    do: Map.get(transports, transport, transport)

  defp resolve_transport(transport, _transports), do: transport

  defp resolve_sms(settings) do
    case settings["sms"] || %{} do
      sms when is_map(sms) ->
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

      other ->
        other
    end
  end

  # Wrongly typed values are kept (only blank strings become nil) so
  # `Validator.validate_voice_config/2` reports them instead of the field
  # silently falling back to its default.
  defp resolve_voice(settings) do
    case settings["voice"] || %{} do
      voice when is_map(voice) ->
        %{
          enabled: resolve_bool_field(voice["enabled"], false),
          twilio_account_sid: blank_to_nil(voice["twilio_account_sid"]),
          twilio_account_sid_secret: blank_to_nil(voice["twilio_account_sid_secret"]),
          twilio_auth_token: blank_to_nil(voice["twilio_auth_token"]),
          twilio_auth_token_secret: blank_to_nil(voice["twilio_auth_token_secret"]),
          twilio_phone_number: blank_to_nil(voice["twilio_phone_number"]),
          deepgram_api_key: blank_to_nil(voice["deepgram_api_key"]),
          deepgram_api_key_secret: blank_to_nil(voice["deepgram_api_key_secret"]),
          elevenlabs_api_key: blank_to_nil(voice["elevenlabs_api_key"]),
          elevenlabs_api_key_secret: blank_to_nil(voice["elevenlabs_api_key_secret"]),
          elevenlabs_voice_id: blank_to_nil(voice["elevenlabs_voice_id"]),
          elevenlabs_output_format: blank_to_nil(voice["elevenlabs_output_format"]),
          websocket_port: voice["websocket_port"],
          public_url: blank_to_nil(voice["public_url"]),
          llm_model: blank_to_nil(voice["llm_model"]),
          system_prompt: blank_to_nil(voice["system_prompt"]),
          max_call_duration_seconds: voice["max_call_duration_seconds"],
          silence_timeout_ms: voice["silence_timeout_ms"]
        }
        |> reject_nil_values()

      other ->
        other
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # Only the top level is atomized; nested tables keep TOML's string keys, so
  # validators and consumers read both forms. A non-table value is kept as is
  # for the validator to reject instead of crashing resolution.
  defp resolve_passthrough(settings, section) do
    case settings[section] do
      nil -> %{}
      map when is_map(map) -> Map.new(map, fn {k, v} -> {safe_to_atom(k), v} end)
      other -> other
    end
  end

  defp resolve_bool_field(nil, default), do: default
  defp resolve_bool_field(val, _default) when is_boolean(val), do: val
  defp resolve_bool_field("true", _default), do: true
  defp resolve_bool_field("false", _default), do: false
  defp resolve_bool_field(value, _default), do: value

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
    String.to_existing_atom(key)
  rescue
    ArgumentError -> String.to_atom(key)
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
      "default_cwd" => nil,
      "auto_resume" => false,
      "enable_webhook" => false,
      "projects" => %{},
      "bindings" => [],
      "sms" => %{},
      "email" => %{},
      "webhook" => %{},
      "voice" => %{}
    }

    Enum.reduce(Channel.ids(), base, fn id, acc ->
      section = Atom.to_string(id)

      acc
      |> Map.put("enable_#{section}", false)
      |> Map.put(section, %{})
    end)
  end
end
