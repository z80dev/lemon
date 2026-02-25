defmodule LemonChannels.Adapters.Discord.Transport do
  @moduledoc """
  Discord transport that routes inbound events to LemonRouter through RouterBridge.
  """

  use GenServer

  require Logger

  alias LemonChannels.Adapters.Discord.Inbound
  alias LemonChannels.BindingResolver
  alias LemonCore.ChatScope
  alias LemonCore.{InboundMessage, RouterBridge, SessionKey}
  alias Nostrum.Api.ApplicationCommand
  alias Nostrum.Api.Interaction

  @lemon_command %{
    name: "lemon",
    description: "Run a Lemon prompt",
    type: 1,
    options: [
      %{
        type: 3,
        name: "prompt",
        description: "Prompt text",
        required: true
      },
      %{
        type: 3,
        name: "engine",
        description: "Optional engine override",
        required: false
      }
    ]
  }

  @session_command %{
    name: "session",
    description: "Session controls",
    type: 1,
    options: [
      %{
        type: 1,
        name: "new",
        description: "Start a new session"
      },
      %{
        type: 1,
        name: "info",
        description: "Show session key"
      }
    ]
  }

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    base = LemonChannels.GatewayConfig.get(:discord, %{}) || %{}

    config =
      base
      |> merge_config(Application.get_env(:lemon_channels, :discord))
      |> merge_config(Keyword.get(opts, :config))
      |> merge_config(Keyword.drop(opts, [:config]))

    token = cfg_get(config, :bot_token) || System.get_env("DISCORD_BOT_TOKEN")

    if is_binary(token) and String.trim(token) != "" do
      case ensure_nostrum_started(token) do
        :ok ->
          consumer_pid = start_consumer()

          {:ok,
           %{
             consumer_pid: consumer_pid,
             account_id: cfg_get(config, :account_id, "default"),
             allowed_guild_ids: parse_allowed_ids(cfg_get(config, :allowed_guild_ids)),
             allowed_channel_ids: parse_allowed_ids(cfg_get(config, :allowed_channel_ids)),
             deny_unbound_channels: cfg_get(config, :deny_unbound_channels, false),
             bot_user_id: nil
           }}

        {:error, reason} ->
          Logger.warning("discord adapter disabled: #{inspect(reason)}")
          :ignore
      end
    else
      :ignore
    end
  end

  @impl true
  def handle_info({:discord_event, {:READY, payload, _ws_state}}, state) do
    _ = register_slash_commands()

    bot_user_id =
      payload
      |> map_get(:user)
      |> map_get(:id)
      |> parse_id()

    {:noreply, %{state | bot_user_id: bot_user_id}}
  end

  def handle_info({:discord_event, {:MESSAGE_CREATE, message, _ws_state}}, state) do
    maybe_handle_message(message, state)
    {:noreply, state}
  end

  def handle_info({:discord_event, {:INTERACTION_CREATE, interaction, _ws_state}}, state) do
    maybe_handle_interaction(interaction, state)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_handle_message(message, state) do
    with true <- user_message?(message),
         {:ok, inbound} <- normalize_message_inbound(message, state),
         true <- allowed_inbound?(inbound, state),
         true <- binding_allowed?(inbound, state),
         :ok <- route_to_router(inbound) do
      :ok
    else
      _ -> :ok
    end
  rescue
    error -> Logger.warning("discord inbound message handling failed: #{inspect(error)}")
  end

  defp maybe_handle_interaction(interaction, state) do
    name = interaction |> map_get(:data) |> map_get(:name)

    case name do
      "lemon" -> handle_lemon_interaction(interaction, state)
      "session" -> handle_session_interaction(interaction, state)
      _ -> respond(interaction, "Unknown command", ephemeral: true)
    end
  rescue
    error -> Logger.warning("discord interaction handling failed: #{inspect(error)}")
  end

  defp handle_lemon_interaction(interaction, state) do
    prompt = option_value(interaction, "prompt")
    engine = option_value(interaction, "engine")

    if is_binary(prompt) and String.trim(prompt) != "" do
      respond(interaction, "Queued", ephemeral: true)

      inbound = interaction_to_inbound(interaction, prompt, engine, state)

      if allowed_inbound?(inbound, state) and binding_allowed?(inbound, state) do
        _ = route_to_router(inbound)
      end
    else
      respond(interaction, "Prompt cannot be empty.", ephemeral: true)
    end
  end

  defp handle_session_interaction(interaction, state) do
    sub = session_subcommand(interaction)

    case sub do
      "new" ->
        session_key = interaction_session_key(interaction, state)
        LemonCore.Store.delete_chat_state(session_key)
        respond(interaction, "Started a fresh session.", ephemeral: true)

      "info" ->
        session_key = interaction_session_key(interaction, state)
        respond(interaction, "Session: `#{session_key}`", ephemeral: true)

      _ ->
        respond(interaction, "Unknown /session subcommand", ephemeral: true)
    end
  end

  defp interaction_to_inbound(interaction, prompt, engine, state) do
    channel_id = interaction |> map_get(:channel_id) |> parse_id()
    guild_id = interaction |> map_get(:guild_id) |> parse_id()
    interaction_id = interaction |> map_get(:id) |> parse_id()
    user_id = interaction_user_id(interaction)

    thread_id =
      interaction
      |> map_get(:channel)
      |> map_get(:thread_metadata)
      |> case do
        %{} -> channel_id
        _ -> nil
      end

    peer_kind = if is_integer(guild_id), do: :group, else: :dm

    scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}
    agent_id = BindingResolver.resolve_agent_id(scope)

    session_key =
      session_key_for(
        agent_id,
        state.account_id,
        peer_kind,
        channel_id,
        user_id,
        thread_id,
        guild_id
      )

    %InboundMessage{
      channel_id: "discord",
      account_id: state.account_id,
      peer: %{
        kind: peer_kind,
        id: Integer.to_string(channel_id),
        thread_id: maybe_to_string(thread_id)
      },
      sender: %{
        id: maybe_to_string(user_id),
        username: nil,
        display_name: nil
      },
      message: %{
        id: maybe_to_string(interaction_id),
        text: prompt,
        timestamp: System.system_time(:second),
        reply_to_id: nil
      },
      raw: interaction,
      meta: %{
        session_key: session_key,
        agent_id: agent_id,
        engine_id: normalize_blank(engine),
        user_msg_id: interaction_id,
        channel_id: channel_id,
        guild_id: guild_id,
        thread_id: thread_id,
        user_id: user_id,
        source: :slash
      }
    }
  end

  defp normalize_message_inbound(message, state) do
    with {:ok, inbound} <- Inbound.normalize(%{message: message, account_id: state.account_id}) do
      channel_id = inbound.meta[:channel_id]
      guild_id = inbound.meta[:guild_id]
      thread_id = inbound.meta[:thread_id]
      user_id = inbound.meta[:user_id] |> parse_id()
      peer_kind = inbound.peer.kind

      scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: thread_id}
      agent_id = BindingResolver.resolve_agent_id(scope)

      session_key =
        session_key_for(
          agent_id,
          state.account_id,
          peer_kind,
          channel_id,
          user_id,
          thread_id,
          guild_id
        )

      meta =
        inbound.meta
        |> Map.put(:session_key, session_key)
        |> Map.put(:agent_id, agent_id)

      {:ok, %{inbound | meta: meta}}
    end
  end

  defp session_key_for(agent_id, account_id, peer_kind, channel_id, user_id, thread_id, guild_id) do
    opts = %{
      agent_id: agent_id || "default",
      channel_id: "discord",
      account_id: account_id || "default",
      peer_kind: peer_kind,
      peer_id: Integer.to_string(channel_id),
      thread_id: maybe_to_string(thread_id)
    }

    opts =
      if is_integer(guild_id) and is_integer(user_id) do
        Map.put(opts, :sub_id, Integer.to_string(user_id))
      else
        opts
      end

    SessionKey.channel_peer(opts)
  end

  defp route_to_router(%InboundMessage{} = inbound) do
    case RouterBridge.handle_inbound(inbound) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("discord inbound routing failed: #{inspect(reason)}")
        :ok
    end
  end

  defp allowed_inbound?(%InboundMessage{} = inbound, state) do
    guild_id = inbound.meta[:guild_id] |> parse_id()
    channel_id = inbound.meta[:channel_id] |> parse_id()

    guild_allowed? =
      case state.allowed_guild_ids do
        nil -> true
        set -> is_integer(guild_id) and MapSet.member?(set, guild_id)
      end

    channel_allowed? =
      case state.allowed_channel_ids do
        nil -> true
        set -> is_integer(channel_id) and MapSet.member?(set, channel_id)
      end

    guild_allowed? and channel_allowed?
  end

  defp binding_allowed?(%InboundMessage{} = inbound, state) do
    if state.deny_unbound_channels == true and inbound.peer.kind != :dm do
      scope = %ChatScope{
        transport: :discord,
        chat_id: inbound.meta[:channel_id],
        topic_id: inbound.meta[:thread_id]
      }

      not is_nil(BindingResolver.resolve_binding(scope))
    else
      true
    end
  rescue
    _ -> false
  end

  defp interaction_session_key(interaction, state) do
    channel_id = interaction |> map_get(:channel_id) |> parse_id()
    guild_id = interaction |> map_get(:guild_id) |> parse_id()
    user_id = interaction_user_id(interaction)

    peer_kind = if is_integer(guild_id), do: :group, else: :dm
    scope = %ChatScope{transport: :discord, chat_id: channel_id, topic_id: nil}
    agent_id = BindingResolver.resolve_agent_id(scope)

    session_key_for(agent_id, state.account_id, peer_kind, channel_id, user_id, nil, guild_id)
  end

  defp interaction_user_id(interaction) do
    member_user_id =
      interaction
      |> map_get(:member)
      |> map_get(:user)
      |> map_get(:id)
      |> parse_id()

    member_user_id ||
      interaction
      |> map_get(:user)
      |> map_get(:id)
      |> parse_id()
  end

  defp user_message?(message) do
    author = map_get(message, :author)
    bot? = map_get(author, :bot) == true
    webhook? = not is_nil(map_get(message, :webhook_id))

    not bot? and not webhook?
  end

  defp register_slash_commands do
    for cmd <- [@lemon_command, @session_command] do
      _ =
        try do
          ApplicationCommand.create_global_command(cmd)
        rescue
          _ -> :ok
        end
    end

    :ok
  end

  defp respond(interaction, content, opts) do
    payload = %{
      type: 4,
      data: %{
        content: content,
        flags: if(Keyword.get(opts, :ephemeral, false), do: 64, else: 0)
      }
    }

    _ =
      try do
        Interaction.create_response(interaction, payload)
      rescue
        _ -> :ok
      end

    :ok
  end

  defp option_value(interaction, option_name) do
    options =
      interaction
      |> map_get(:data)
      |> map_get(:options)

    options
    |> List.wrap()
    |> Enum.find_value(fn option ->
      if map_get(option, :name) == option_name, do: map_get(option, :value), else: nil
    end)
    |> normalize_blank()
  end

  defp session_subcommand(interaction) do
    interaction
    |> map_get(:data)
    |> map_get(:options)
    |> List.wrap()
    |> List.first()
    |> map_get(:name)
  end

  defp start_consumer do
    case safe_start_consumer() do
      {:ok, pid} ->
        pid

      :ok ->
        nil

      {:error, reason} ->
        Logger.warning("discord consumer failed to start: #{inspect(reason)}")
        nil
    end
  end

  defp safe_start_consumer do
    __MODULE__.Consumer.start_link([])
  rescue
    error -> {:error, error}
  end

  defp ensure_nostrum_started(token) do
    Application.put_env(:nostrum, :token, token)

    case Application.ensure_all_started(:nostrum) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_allowed_ids(value) when is_list(value) do
    ids =
      value
      |> Enum.map(&parse_id/1)
      |> Enum.filter(&is_integer/1)

    if ids == [], do: nil, else: MapSet.new(ids)
  end

  defp parse_allowed_ids(_), do: nil

  defp parse_id(value) when is_integer(value), do: value

  defp parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, _} -> id
      :error -> nil
    end
  end

  defp parse_id(_), do: nil

  defp merge_config(config, nil), do: config
  defp merge_config(config, opts) when is_map(opts), do: Map.merge(config, opts)

  defp merge_config(config, opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: Map.merge(config, Enum.into(opts, %{})), else: config
  end

  defp merge_config(config, _), do: config

  defp cfg_get(config, key, default \\ nil) when is_map(config) do
    Map.get(config, key, Map.get(config, Atom.to_string(key), default))
  end

  defp normalize_blank(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp normalize_blank(_), do: nil

  defp maybe_to_string(value) when is_integer(value), do: Integer.to_string(value)
  defp maybe_to_string(value) when is_binary(value), do: value
  defp maybe_to_string(_), do: nil

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_, _), do: nil

  defmodule Consumer do
    @moduledoc false
    use Nostrum.Consumer

    @transport LemonChannels.Adapters.Discord.Transport

    def handle_event(event) do
      if pid = Process.whereis(@transport) do
        send(pid, {:discord_event, event})
      end
    end
  end
end
