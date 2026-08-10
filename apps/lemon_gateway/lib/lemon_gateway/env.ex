defmodule LemonGateway.Env do
  @moduledoc """
  Environment variables read by `lemon_gateway` — engine execution: concurrency, transports, and node identity.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :anthropic_api_key,
      env_var: "ANTHROPIC_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Anthropic API key.",
      secret?: true,
      required?: false,
      area: :provider_secrets,
      apps: [:ai]
    },
    %{
      name: :lemon_gateway_health_port,
      env_var: "LEMON_GATEWAY_HEALTH_PORT",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Port the gateway health-check endpoint listens on.",
      secret?: false,
      required?: false,
      area: :endpoints,
      apps: [:lemon_gateway]
    },
    %{
      name: :farcaster_account_id,
      env_var: "FARCASTER_ACCOUNT_ID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Farcaster account id used by the Farcaster transport.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_gateway]
    },
    %{
      name: :farcaster_api_key,
      env_var: "FARCASTER_API_KEY",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Farcaster (Neynar) API key.",
      secret?: true,
      required?: false,
      area: :gateway,
      apps: [:lemon_gateway]
    },
    %{
      name: :farcaster_hub_validate_url,
      env_var: "FARCASTER_HUB_VALIDATE_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Farcaster hub URL used to validate cast/frame messages.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_gateway]
    },
    %{
      name: :farcaster_signer_uuid,
      env_var: "FARCASTER_SIGNER_UUID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Farcaster signer UUID used to post casts.",
      secret?: true,
      required?: false,
      area: :gateway,
      apps: [:lemon_gateway]
    },
    %{
      name: :farcaster_state_secret,
      env_var: "FARCASTER_STATE_SECRET",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Secret used to sign Farcaster frame state tokens.",
      secret?: true,
      required?: false,
      area: :gateway,
      apps: [:lemon_gateway]
    },
    %{
      name: :lemon_sms_inbox_ttl_ms,
      env_var: "LEMON_SMS_INBOX_TTL_MS",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "TTL (ms) for deduplicated inbound SMS message tracking.",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :lemon_sms_webhook_bind,
      env_var: "LEMON_SMS_WEBHOOK_BIND",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Bind address for the SMS webhook server.",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :lemon_sms_webhook_enabled,
      env_var: "LEMON_SMS_WEBHOOK_ENABLED",
      aliases: [],
      type: :boolean,
      default: nil,
      doc: "Whether the inbound SMS webhook server is enabled.",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :lemon_sms_webhook_port,
      env_var: "LEMON_SMS_WEBHOOK_PORT",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Port the SMS webhook server listens on.",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :twilio_account_sid,
      env_var: "TWILIO_ACCOUNT_SID",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Twilio account SID (ecosystem-standard name, grandfathered).",
      secret?: true,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :twilio_auth_token,
      env_var: "TWILIO_AUTH_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Twilio auth token (ecosystem-standard name, grandfathered).",
      secret?: true,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :twilio_inbox_number,
      env_var: "TWILIO_INBOX_NUMBER",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Twilio inbox phone number used for inbound SMS routing.",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :twilio_phone_number,
      env_var: "TWILIO_PHONE_NUMBER",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Twilio sending phone number (ecosystem-standard name, grandfathered).",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :twilio_validate_webhook,
      env_var: "TWILIO_VALIDATE_WEBHOOK",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether inbound Twilio webhook signatures are validated.",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :twilio_webhook_url,
      env_var: "TWILIO_WEBHOOK_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Public URL Twilio uses to reach the SMS webhook.",
      secret?: false,
      required?: false,
      area: :gateway_sms,
      apps: [:lemon_gateway]
    },
    %{
      name: :voice_public_url,
      env_var: "VOICE_PUBLIC_URL",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Public URL for the voice websocket endpoint (grandfathered, no LEMON_ prefix).",
      secret?: false,
      required?: false,
      area: :gateway_voice,
      apps: [:lemon_gateway]
    },
    %{
      name: :voice_recordings_dir,
      env_var: "VOICE_RECORDINGS_DIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Directory where downloaded call recordings are stored.",
      secret?: false,
      required?: false,
      area: :gateway_voice,
      apps: [:lemon_gateway]
    }
  ]
end
