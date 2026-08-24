defmodule LemonChannels.Env do
  @moduledoc """
  Environment variables read by `lemon_channels` — channel adapters and their limits.

  Aggregated by `LemonCore.Env` through the `:env_registries` list; see
  `LemonCore.Env.Registry`.
  """

  use LemonCore.Env.Registry

  @declarations [
    %{
      name: :discord_bot_token,
      env_var: "DISCORD_BOT_TOKEN",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Discord bot token (ecosystem-standard name).",
      secret?: true,
      required?: false,
      area: :gateway,
      apps: [:lemon_channels]
    },
    %{
      name: :lemon_lock_dir,
      env_var: "LEMON_LOCK_DIR",
      aliases: [],
      type: :string,
      default: nil,
      doc: "Directory used for gateway/channel file locks.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_channels]
    },
    %{
      name: :lemon_gateway_enable_discord,
      env_var: "LEMON_GATEWAY_ENABLE_DISCORD",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the Discord transport is enabled.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_channels]
    },
    %{
      name: :lemon_gateway_enable_telegram,
      env_var: "LEMON_GATEWAY_ENABLE_TELEGRAM",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the Telegram transport is enabled.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_channels]
    },
    %{
      name: :lemon_gateway_enable_xmtp,
      env_var: "LEMON_GATEWAY_ENABLE_XMTP",
      aliases: [],
      type: :boolean,
      default: false,
      doc: "Whether the XMTP transport is enabled.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_channels]
    },
    %{
      name: :lemon_telegram_compaction_context_window,
      env_var: "LEMON_TELEGRAM_COMPACTION_CONTEXT_WINDOW",
      aliases: [],
      type: :integer,
      default: 400_000,
      doc: "Context window size (tokens) used for Telegram compaction triggers.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_channels]
    },
    %{
      name: :lemon_telegram_compaction_enabled,
      env_var: "LEMON_TELEGRAM_COMPACTION_ENABLED",
      aliases: [],
      type: :boolean,
      default: true,
      doc: "Whether Telegram session transcripts are auto-compacted.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_channels]
    },
    %{
      name: :lemon_telegram_compaction_reserve_tokens,
      env_var: "LEMON_TELEGRAM_COMPACTION_RESERVE_TOKENS",
      aliases: [],
      type: :integer,
      default: 16_384,
      doc: "Token budget reserved during Telegram session compaction.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_channels]
    },
    %{
      name: :lemon_telegram_compaction_trigger_ratio,
      env_var: "LEMON_TELEGRAM_COMPACTION_TRIGGER_RATIO",
      aliases: [],
      type: :float,
      default: 0.9,
      doc: "Context-window fill ratio that triggers Telegram compaction.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_channels]
    },
    %{
      name: :lemon_telegram_poller_lock_stale_ms,
      env_var: "LEMON_TELEGRAM_POLLER_LOCK_STALE_MS",
      aliases: [],
      type: :integer,
      default: nil,
      doc: "Age (ms) after which a Telegram poller lock is considered stale and reclaimed.",
      secret?: false,
      required?: false,
      area: :gateway,
      apps: [:lemon_channels]
    }
  ]
end
