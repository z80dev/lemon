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
