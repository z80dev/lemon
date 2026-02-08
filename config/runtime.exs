import Config

# Discord Bot Configuration
if config_env() != :test do
  if discord_token = System.get_env("DISCORD_BOT_TOKEN") do
    config :nostrum,
      token: discord_token,
      gateway_intents: [
        :guilds,
        :guild_messages,
        :guild_message_reactions,
        :direct_messages,
        :direct_message_reactions,
        :message_content,
        :guild_voice_states
      ]

    config :lemon_gateway, :discord,
      bot_token: discord_token,
      account_id: "default",
      trigger_mode: :always,
      allowed_guild_ids: [],
      allowed_channel_ids: []

    # Enable Discord adapter
    config :lemon_gateway, :enable_discord, true
  end
end
