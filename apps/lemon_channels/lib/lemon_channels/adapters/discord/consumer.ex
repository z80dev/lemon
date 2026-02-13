defmodule LemonChannels.Adapters.Discord.Consumer do
  @moduledoc """
  Nostrum consumer for handling Discord gateway events.

  Handles:
  - MESSAGE_CREATE, MESSAGE_UPDATE, MESSAGE_DELETE
  - MESSAGE_REACTION_ADD, MESSAGE_REACTION_REMOVE
  - INTERACTION_CREATE (buttons, slash commands)
  - VOICE_STATE_UPDATE
  """

  use GenServer

  @behaviour Nostrum.Consumer

  alias LemonChannels.Adapters.Discord.Inbound
  alias LemonCore.RouterBridge
  alias Nostrum.ConsumerGroup

  require Logger

  @default_debounce_ms 1_000
  @default_dedupe_ttl_ms 600_000

  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  def start_link(config) when is_map(config) or is_list(config) do
    # Store config in persistent_term for access in event handlers
    normalized = normalize_config(config)
    :persistent_term.put({__MODULE__, :config}, normalized)

    # Initialize deduplication ETS table
    ensure_dedupe_table()

    GenServer.start_link(__MODULE__, normalized, name: __MODULE__)
  end

  @impl GenServer
  def init(config) do
    # Join the Nostrum ConsumerGroup to receive events
    ConsumerGroup.join(self())
    {:ok, config}
  end

  @impl GenServer
  def handle_info({:event, event}, state) do
    Logger.debug("Discord Consumer received event: #{inspect(elem(event, 0))}")
    # Handle events synchronously - gateway is already async
    try do
      handle_event(event)
    rescue
      e ->
        Logger.error("Error in Discord event handler: #{Exception.format(:error, e, __STACKTRACE__)}")
    end
    {:noreply, state}
  end

  def handle_info({:forward_inbound, inbound, _msg_id}, state) do
    # Trigger typing indicator
    channel_id = parse_channel_id(inbound.peer.id)
    spawn(fn -> Nostrum.Api.Channel.start_typing(channel_id) end)
    
    # Forward to router
    RouterBridge.handle_inbound(inbound)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp parse_channel_id(id) when is_integer(id), do: id
  defp parse_channel_id(id) when is_binary(id), do: String.to_integer(id)

  # ============================================================================
  # Gateway Event Handlers
  # ============================================================================

  @impl Nostrum.Consumer
  def handle_event({:READY, ready, _ws_state}) do
    bot_id = ready.user.id
    bot_username = ready.user.username

    Logger.info("Discord adapter connected as #{bot_username} (#{bot_id})")

    # Store bot identity for mention detection
    :persistent_term.put({__MODULE__, :bot_id}, bot_id)
    :persistent_term.put({__MODULE__, :bot_username}, bot_username)

    :ok
  end

  @impl Nostrum.Consumer
  def handle_event({:MESSAGE_CREATE, msg, _ws_state}) do
    config = get_config()

    # Skip bot's own messages
    if msg.author.bot do
      :noop
    else
      handle_message(msg, config, :create)
    end
  end

  @impl Nostrum.Consumer
  def handle_event({:MESSAGE_UPDATE, msg, _ws_state}) do
    config = get_config()

    # MESSAGE_UPDATE may be partial (only contains changed fields)
    # Only process if we have author and content
    if msg.author && msg.content && !msg.author.bot do
      handle_message(msg, config, :update)
    else
      :noop
    end
  end

  @impl Nostrum.Consumer
  def handle_event({:MESSAGE_DELETE, payload, _ws_state}) do
    # Payload contains: id, channel_id, guild_id (optional)
    # We could notify the router about deletions if needed
    Logger.debug("Discord message deleted: #{payload.id} in channel #{payload.channel_id}")
    :noop
  end

  @impl Nostrum.Consumer
  def handle_event({:MESSAGE_REACTION_ADD, reaction, _ws_state}) do
    handle_reaction(reaction, :add)
  end

  @impl Nostrum.Consumer
  def handle_event({:MESSAGE_REACTION_REMOVE, reaction, _ws_state}) do
    handle_reaction(reaction, :remove)
  end

  @impl Nostrum.Consumer
  def handle_event({:INTERACTION_CREATE, interaction, _ws_state}) do
    handle_interaction(interaction)
  end

  @impl Nostrum.Consumer
  def handle_event({:VOICE_STATE_UPDATE, voice_state, _ws_state}) do
    # Could be used for voice channel tracking
    Logger.debug("Voice state update: user=#{voice_state.user_id} channel=#{voice_state.channel_id}")
    :noop
  end

  # Catch-all for other events
  @impl Nostrum.Consumer
  def handle_event(_event), do: :noop

  # ============================================================================
  # Message Handling
  # ============================================================================

  defp handle_message(msg, config, _event_type) do
    # Check authorization (guild/channel allowlists)
    unless authorized?(msg, config) do
      :noop
    else
      # Check trigger mode
      if should_trigger?(msg, config) do
        # Check deduplication
        message_key = "#{msg.channel_id}:#{msg.id}"

        unless dedupe_check?(message_key, config) do
          :noop
        else
          handle_debounced(msg, config)
        end
      else
        :noop
      end
    end
  end

  defp handle_debounced(msg, config) do
    debounce_ms = config[:debounce_ms] || @default_debounce_ms

    case Inbound.normalize(msg, config) do
      {:ok, inbound} ->
        # Schedule forwarding after debounce period
        Process.send_after(self(), {:forward_inbound, inbound, msg.id}, debounce_ms)

      {:error, reason} ->
        Logger.warning("Discord: Failed to normalize message: #{inspect(reason)}")
    end
  end

  # ============================================================================
  # Trigger Mode Detection
  # ============================================================================

  defp should_trigger?(msg, config) do
    trigger_mode = config[:trigger_mode] || :always

    case trigger_mode do
      :always ->
        true

      :mention ->
        # Check if bot is mentioned
        bot_id = :persistent_term.get({__MODULE__, :bot_id}, nil)
        mentioned?(msg, bot_id)

      :reply ->
        # Check if message is a reply to the bot
        bot_id = :persistent_term.get({__MODULE__, :bot_id}, nil)
        is_reply_to_bot?(msg, bot_id)

      :command ->
        # Check if message starts with command prefix
        prefix = config[:command_prefix] || "!"
        String.starts_with?(msg.content || "", prefix)

      _ ->
        true
    end
  end

  defp mentioned?(_msg, nil), do: false
  defp mentioned?(msg, bot_id) do
    Enum.any?(msg.mentions || [], fn user -> user.id == bot_id end)
  end

  defp is_reply_to_bot?(_msg, nil), do: false
  defp is_reply_to_bot?(msg, bot_id) do
    case msg.referenced_message do
      %{author: %{id: ^bot_id}} -> true
      _ -> false
    end
  end

  # ============================================================================
  # Authorization
  # ============================================================================

  defp authorized?(msg, config) do
    allowed_guilds = config[:allowed_guild_ids] || []
    allowed_channels = config[:allowed_channel_ids] || []

    guild_ok =
      if allowed_guilds == [] do
        true
      else
        guild_id = msg.guild_id && to_string(msg.guild_id)
        guild_id in allowed_guilds or msg.guild_id in allowed_guilds
      end

    channel_ok =
      if allowed_channels == [] do
        true
      else
        channel_id = to_string(msg.channel_id)
        channel_id in allowed_channels or msg.channel_id in allowed_channels
      end

    guild_ok and channel_ok
  end

  # ============================================================================
  # Reaction Handling
  # ============================================================================

  defp handle_reaction(reaction, action) do
    # Could be used for approval flows
    Logger.debug("Discord reaction #{action}: #{inspect(reaction.emoji)} on message #{reaction.message_id}")

    # TODO: Publish reaction events for approval system
    # LemonChannels.Events.publish({:reaction, action, reaction})
    :noop
  end

  # ============================================================================
  # Interaction Handling (Buttons, Slash Commands)
  # ============================================================================

  defp handle_interaction(interaction) do
    Logger.debug("Discord interaction: type=#{interaction.type} custom_id=#{interaction.data[:custom_id]}")

    case interaction.type do
      # Component interaction (buttons, selects)
      3 ->
        handle_component_interaction(interaction)

      # Slash command
      2 ->
        handle_slash_command(interaction)

      _ ->
        :noop
    end
  end

  defp handle_component_interaction(interaction) do
    custom_id = interaction.data[:custom_id]

    # Parse custom_id for approval system
    # Format: "approve:run_id" or "reject:run_id"
    case String.split(custom_id || "", ":", parts: 2) do
      ["approve", run_id] ->
        handle_approval(interaction, run_id, :approve)

      ["reject", run_id] ->
        handle_approval(interaction, run_id, :reject)

      _ ->
        # Unknown component, acknowledge
        acknowledge_interaction(interaction)
    end
  end

  defp handle_approval(interaction, run_id, action) do
    Logger.info("Discord approval: #{action} for run #{run_id}")

    # Acknowledge the interaction
    acknowledge_interaction(interaction, "#{action} received for run #{run_id}")

    # TODO: Publish approval event
    # LemonChannels.Events.publish({:approval, action, run_id, interaction.user})
    :noop
  end

  defp handle_slash_command(interaction) do
    command_name = interaction.data[:name]
    Logger.debug("Discord slash command: #{command_name}")

    # TODO: Handle registered slash commands
    acknowledge_interaction(interaction)
  end

  defp acknowledge_interaction(interaction, content \\ nil) do
    # Send interaction response
    response =
      if content do
        %{type: 4, data: %{content: content, flags: 64}}  # Ephemeral message
      else
        %{type: 6}  # Deferred update
      end

    Nostrum.Api.Interaction.create_response(interaction, response)
  end

  # ============================================================================
  # Deduplication
  # ============================================================================

  @dedupe_table :discord_dedupe

  defp ensure_dedupe_table do
    if :ets.whereis(@dedupe_table) == :undefined do
      :ets.new(@dedupe_table, [:set, :public, :named_table])
    end
  end

  defp dedupe_check?(key, config) do
    ttl_ms = config[:dedupe_ttl_ms] || @default_dedupe_ttl_ms
    now = System.monotonic_time(:millisecond)

    case :ets.lookup(@dedupe_table, key) do
      [{^key, timestamp}] when now - timestamp < ttl_ms ->
        # Already seen within TTL
        false

      _ ->
        # Record this message
        :ets.insert(@dedupe_table, {key, now})
        # Cleanup old entries periodically
        maybe_cleanup_dedupe(now)
        true
    end
  end

  defp maybe_cleanup_dedupe(now) do
    # Cleanup every ~100 messages
    if :rand.uniform(100) == 1 do
      spawn(fn ->
        ttl_ms = @default_dedupe_ttl_ms
        cutoff = now - ttl_ms

        :ets.foldl(
          fn {key, timestamp}, _acc ->
            if timestamp < cutoff do
              :ets.delete(@dedupe_table, key)
            end
            nil
          end,
          nil,
          @dedupe_table
        )
      end)
    end
  end

  # ============================================================================
  # Config Helpers
  # ============================================================================

  defp get_config do
    :persistent_term.get({__MODULE__, :config}, %{})
  end

  defp normalize_config(config) when is_map(config), do: config

  defp normalize_config(config) when is_list(config) do
    if Keyword.keyword?(config) do
      Enum.into(config, %{})
    else
      %{}
    end
  end

  defp normalize_config(_), do: %{}
end
