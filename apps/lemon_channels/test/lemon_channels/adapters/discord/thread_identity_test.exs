defmodule LemonChannels.Adapters.Discord.ThreadIdentityTest do
  @moduledoc """
  Messages and interactions posted in one Discord thread resolve to one
  `{parent channel, thread}` location and so one session key (#649).
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Discord.{Inbound, ModelCatalog, ThreadResolver, Transport}
  alias LemonCore.Dedupe.Ets
  alias Nostrum.Struct.{Message, User}

  @gateway_config_key :"Elixir.LemonGateway.Config"
  @guild_id 1_475_727_416_549_969_980
  @user_id 1_476_753_643_834_183_691

  defmodule FakeRouter do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def submit(run_request) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:submit_run, run_request})
      {:ok, "run_thread_identity_#{System.unique_integer([:positive])}"}
    end
  end

  defmodule FakeDiscordApi do
    def create(_channel_id, _params), do: {:ok, %{id: 4444}}
    def edit(_channel_id, message_id, _params), do: {:ok, %{id: message_id}}
    def delete(_channel_id, _message_id), do: {:ok, %{}}
    def react(_channel_id, _message_id, _emoji), do: {:ok}
    def unreact(_channel_id, _message_id, _emoji), do: {:ok}
    def start_typing(_channel_id), do: {:ok}
  end

  setup do
    parent = self()
    previous_config = Application.get_env(:lemon_gateway, @gateway_config_key)
    previous_mode = Application.get_env(:lemon_core, :config_test_mode)
    previous_bridge = Application.get_env(:lemon_core, :router_bridge)
    previous_fetcher = Application.get_env(:lemon_channels, :discord_channel_fetcher)

    Application.put_env(:lemon_core, :config_test_mode, true)

    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      enable_discord: true,
      discord: %{api_mod: FakeDiscordApi}
    })

    :persistent_term.put({FakeRouter, :test_pid}, parent)
    :ok = LemonCore.RouterBridge.configure(router: FakeRouter, run_orchestrator: FakeRouter)

    Application.put_env(:lemon_channels, :discord_interaction_responder, fn interaction,
                                                                            payload ->
      send(parent, {:interaction_response, interaction, payload})
      :ok
    end)

    :ok = Ets.init(:lemon_channels_discord_dedupe)

    on_exit(fn ->
      :persistent_term.erase({FakeRouter, :test_pid})
      Application.delete_env(:lemon_channels, :discord_interaction_responder)
      restore(:lemon_channels, :discord_channel_fetcher, previous_fetcher)
      restore(:lemon_core, :router_bridge, previous_bridge)
      restore(:lemon_core, :config_test_mode, previous_mode)
      restore(:lemon_gateway, @gateway_config_key, previous_config)
    end)

    parent_id = 1_475_727_417_372_049_419 + System.unique_integer([:positive])
    thread_id = parent_id + 1_000_000

    :ok =
      ThreadResolver.observe_event(:THREAD_CREATE, %{
        id: thread_id,
        parent_id: parent_id,
        guild_id: @guild_id,
        type: 11,
        name: "release"
      })

    %{parent_id: parent_id, thread_id: thread_id}
  end

  test "a thread message and a slash command in that thread share one session key", c do
    request = submit_message(c.thread_id, "hello from the thread")
    assert request.session_key =~ ":#{c.parent_id}:"
    assert request.session_key =~ ":#{c.thread_id}"

    # Discord's partial channel may omit parent_id; the cache answers.
    info = slash(c.thread_id, "session", [%{type: 1, name: "info", options: []}])
    process(info)

    assert_receive {:interaction_response, _, %{data: %{content: content}}}
    assert content =~ "Session: `#{request.session_key}`"
  end

  test "/model set from a thread applies to the next message in that thread", c do
    [%{provider: provider, models: [model | _]} | _] =
      Enum.filter(catalog(), &(&1.models != []))

    click = component(c.thread_id, "lemon:model:set:s:#{provider}:0")
    process(click)
    assert_receive {:interaction_response, _, %{data: %{content: "Model set to" <> _}}}

    request = submit_message(c.thread_id, "which model?")
    model_spec = ModelCatalog.model_spec(model)

    # The run's own session row carries the model; the router resolves it from
    # there, so the channel puts no model in the run meta.
    refute Map.has_key?(request.meta, :model)
    assert {:ok, %{model: ^model_spec}} = LemonCore.PolicyStore.fetch_session(request.session_key)
    on_exit(fn -> LemonCore.PolicyStore.delete_session(request.session_key) end)
  end

  test "an unresolvable channel is not routed under a guessed key", c do
    Application.put_env(:lemon_channels, :discord_channel_fetcher, fn _id ->
      {:error, :timeout}
    end)

    unknown = c.thread_id + 1

    assert {:error, :channel_unresolved} =
             Inbound.normalize(%{message: message(unknown, "hi"), account_id: "default"})

    process(slash(unknown, "session", [%{type: 1, name: "info", options: []}], %{id: unknown}))
    assert_receive {:interaction_response, _, %{data: %{content: refusal}}}
    assert refusal =~ "couldn't look up this channel"
  end

  test "an uncached thread is resolved once through the channel API and then cached", c do
    parent = self()
    thread_id = c.thread_id + 2

    Application.put_env(:lemon_channels, :discord_channel_fetcher, fn id ->
      send(parent, {:fetched, id})
      {:ok, %Nostrum.Struct.Channel{id: id, type: 11, parent_id: c.parent_id}}
    end)

    for _ <- 1..2 do
      assert {:ok, inbound} =
               Inbound.normalize(%{message: message(thread_id, "hi"), account_id: "default"})

      assert {inbound.meta.channel_id, inbound.meta.thread_id} == {c.parent_id, thread_id}
    end

    assert_received {:fetched, ^thread_id}
    refute_received {:fetched, _}
  end

  test "gateway channel events keep the cache current", c do
    Application.put_env(:lemon_channels, :discord_channel_fetcher, fn _id -> {:error, :down} end)
    thread = c.thread_id + 3
    channel = Nostrum.Struct.Channel

    guild = %{
      channels: %{c.parent_id => struct(channel, id: c.parent_id, type: 0, name: "general")},
      threads: %{thread => struct(channel, id: thread, type: 12, parent_id: c.parent_id)}
    }

    :ok = ThreadResolver.observe_event(:GUILD_CREATE, guild)
    assert {:ok, %{channel_id: parent, thread_id: ^thread}} = ThreadResolver.resolve(thread)
    assert parent == c.parent_id
    assert ThreadResolver.name(c.parent_id) == "general"

    :ok = ThreadResolver.observe_event(:THREAD_DELETE, %{id: thread})
    assert {:error, :channel_unresolved} = ThreadResolver.resolve(thread)

    # DMs have no threads and need no lookup.
    assert {:ok, %{channel_id: 42, thread_id: nil}} = ThreadResolver.resolve(42, nil, nil)
  end

  defp submit_message(channel_id, text) do
    {:noreply, routed} =
      Transport.process_event(
        {:discord_event, {:MESSAGE_CREATE, message(channel_id, text), nil}},
        state()
      )

    [{scope_key, buffer}] = Map.to_list(routed.buffers)
    Transport.process_event({:debounce_flush, scope_key, buffer.debounce_ref}, routed)
    assert_receive {:submit_run, request}
    request
  end

  # The shape Nostrum delivers: a %Message{} struct with no channel object.
  defp message(channel_id, text) do
    %Message{
      id: 1_503_803_470_493_300_000 + System.unique_integer([:positive]),
      channel_id: channel_id,
      guild_id: @guild_id,
      content: "<@1476753643834183690> " <> text,
      author: %User{id: @user_id, username: "z", bot: false},
      attachments: [],
      mentions: []
    }
  end

  defp slash(channel_id, name, options, channel \\ nil) do
    %{
      type: 2,
      id: Integer.to_string(1_503_803_470_493_257_000 + System.unique_integer([:positive])),
      channel_id: Integer.to_string(channel_id),
      guild_id: Integer.to_string(@guild_id),
      channel: channel || %{id: Integer.to_string(channel_id), type: 11},
      data: %{name: name, options: options},
      member: %{user: %{id: Integer.to_string(@user_id)}}
    }
  end

  defp component(channel_id, custom_id) do
    %{
      type: 3,
      id: Integer.to_string(1_503_803_470_493_258_000 + System.unique_integer([:positive])),
      channel_id: Integer.to_string(channel_id),
      guild_id: Integer.to_string(@guild_id),
      channel: %{id: Integer.to_string(channel_id), type: 11},
      data: %{custom_id: custom_id, values: []},
      member: %{user: %{id: Integer.to_string(@user_id)}}
    }
  end

  defp process(interaction) do
    Transport.process_event({:discord_event, {:INTERACTION_CREATE, interaction, nil}}, state())
  end

  defp catalog do
    Enum.map(ModelCatalog.available_model_providers(), fn provider ->
      %{provider: provider, models: ModelCatalog.models_for_provider(provider)}
    end)
  end

  defp state do
    %{
      account_id: "default",
      bot_user_id: 1_476_753_643_834_183_690,
      allowed_guild_ids: nil,
      allowed_channel_ids: nil,
      unauthorized_dm_behavior: "ignore",
      deny_unbound_channels: false,
      model_pickers: %{},
      buffers: %{},
      reaction_runs: %{},
      pending_new: %{},
      debounce_ms: 10_000,
      dedupe_ttl_ms: 600_000,
      files: %{}
    }
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
