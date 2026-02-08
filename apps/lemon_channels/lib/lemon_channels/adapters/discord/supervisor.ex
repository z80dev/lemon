defmodule LemonChannels.Adapters.Discord.Supervisor do
  @moduledoc """
  Supervisor for Discord adapter processes.

  Starts the Nostrum consumer which handles gateway events from Discord.
  Nostrum itself is started separately via application config.
  """

  use Supervisor

  require Logger

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    base = LemonChannels.GatewayConfig.get(:discord, %{}) || %{}

    config =
      base
      |> merge_config(Application.get_env(:lemon_gateway, :discord))
      |> merge_config(Keyword.get(opts, :config))

    token = config[:bot_token] || config["bot_token"]

    children =
      if is_binary(token) and token != "" do
        # Configure Nostrum at runtime if not already configured
        configure_nostrum(token, config)

        [
          # Our consumer handles Discord gateway events
          {LemonChannels.Adapters.Discord.Consumer, config}
        ]
      else
        Logger.warning("Discord adapter: No bot_token configured, adapter disabled")
        []
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp configure_nostrum(token, config) do
    # Set Nostrum config if not already set
    unless Application.get_env(:nostrum, :token) do
      Application.put_env(:nostrum, :token, token)
    end

    # Configure gateway intents - we need message content intent for reading messages
    intents = config[:gateway_intents] || [
      :guilds,
      :guild_messages,
      :guild_message_reactions,
      :guild_voice_states,
      :direct_messages,
      :direct_message_reactions,
      :message_content
    ]

    unless Application.get_env(:nostrum, :gateway_intents) do
      Application.put_env(:nostrum, :gateway_intents, intents)
    end

    # Set number of shards (auto by default)
    unless Application.get_env(:nostrum, :num_shards) do
      Application.put_env(:nostrum, :num_shards, :auto)
    end
  end

  defp merge_config(config, nil), do: config

  defp merge_config(config, opts) when is_map(opts) do
    Map.merge(config, opts)
  end

  defp merge_config(config, opts) when is_list(opts) do
    if Keyword.keyword?(opts) do
      Map.merge(config, Enum.into(opts, %{}))
    else
      config
    end
  end

  defp merge_config(config, _opts), do: config
end
