defmodule LemonChannels.Adapters.Discord.ComponentAuthorityTest do
  @moduledoc """
  Discord message components (cancel, keep-alive, model) pass the same
  location gate as slash commands and only control the clicker's own run;
  `/resume` selections belong to the selecting user's session.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Discord.{Transport, TriggerMode}
  alias LemonCore.{ResumeToken, SessionKey, Store}

  @guild_id 1_475_727_417_372_049_000
  @owner 1_476_753_643_834_183_691
  @stranger 1_476_753_643_834_183_692
  @gateway_config_key :gateway_test_config

  defmodule Router do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def submit(request) do
      notify({:submit_run, request})
      {:ok, "run_#{System.unique_integer([:positive])}"}
    end

    # The run belongs only to the configured owner session.
    def active_run(session_key) do
      case :persistent_term.get({__MODULE__, :owner}, nil) do
        {^session_key, run_id} -> {:ok, run_id}
        _ -> :none
      end
    end

    def abort_run(run_id, reason) do
      notify({:abort_run, run_id, reason})
      :ok
    end

    def keep_run_alive(run_id, decision) do
      notify({:keep_run_alive, run_id, decision})
      :ok
    end

    defp notify(msg), do: send(:persistent_term.get({__MODULE__, :pid}), msg)
  end

  defmodule Api do
    def create(_channel_id, _params), do: {:ok, %{id: 1}}
    def react(_channel_id, _message_id, _emoji), do: {:ok}
    def unreact(_channel_id, _message_id, _emoji), do: {:ok}
    def start_typing(_channel_id), do: {:ok}
  end

  setup do
    start_supervised!({Task.Supervisor, name: LemonChannels.Adapters.Discord.AsyncSupervisor})
    parent = self()
    :ok = LemonCore.Dedupe.Ets.init(:lemon_channels_discord_dedupe)

    previous_bridge = Application.get_env(:lemon_core, :router_bridge)
    previous_gateway = Application.get_env(:lemon_core, @gateway_config_key)
    previous_test_mode = Application.get_env(:lemon_core, :config_test_mode)
    :persistent_term.put({Router, :pid}, parent)
    :ok = LemonCore.RouterBridge.configure(router: Router, run_orchestrator: Router)
    Application.put_env(:lemon_core, :config_test_mode, true)

    Application.put_env(:lemon_core, @gateway_config_key, %{
      enable_discord: true,
      discord: %{api_mod: Api}
    })

    Application.put_env(:lemon_channels, :discord_interaction_responder, fn interaction,
                                                                            payload ->
      send(parent, {:interaction_response, interaction, payload})
      :ok
    end)

    channel_id = 1_475_727_417_372_049_419 + System.unique_integer([:positive])

    on_exit(fn ->
      Application.delete_env(:lemon_channels, :discord_interaction_responder)
      :persistent_term.erase({Router, :pid})
      :persistent_term.erase({Router, :owner})
      restore(:lemon_core, :router_bridge, previous_bridge)
      restore(:lemon_core, @gateway_config_key, previous_gateway)
      restore(:lemon_core, :config_test_mode, previous_test_mode)
    end)

    %{channel_id: channel_id}
  end

  describe "run control components" do
    test "clicks from a denied location are refused and change nothing", %{channel_id: channel} do
      :persistent_term.put({Router, :owner}, {session_key(channel, @owner), "run_owned"})
      denied = %{allowed_guild_ids: MapSet.new([1])}

      for custom_id <- [
            "lemon:cancel:run_owned",
            "lemon:idle:c:run_owned",
            "lemon:idle:k:run_owned"
          ] do
        click = component(channel, @owner, custom_id)
        process(click, denied)
        assert_receive {:interaction_response, ^click, %{data: %{content: text}}}
        assert text =~ "not available"
      end

      refute_receive {:abort_run, _, _}, 100
      refute_receive {:keep_run_alive, _, _}, 50
    end

    test "another member cannot cancel or keep alive the owner's run", %{channel_id: channel} do
      :persistent_term.put({Router, :owner}, {session_key(channel, @owner), "run_owned"})

      for custom_id <- [
            "lemon:cancel:run_owned",
            "lemon:idle:c:run_owned",
            "lemon:idle:k:run_owned"
          ] do
        click = component(channel, @stranger, custom_id)
        process(click, %{})
        assert_receive {:interaction_response, ^click, %{data: %{content: text}}}
        assert text =~ "Only the user who started this run"
      end

      refute_receive {:abort_run, _, _}, 100
      refute_receive {:keep_run_alive, _, _}, 50
    end

    test "the owner's clicks still control the run", %{channel_id: channel} do
      :persistent_term.put({Router, :owner}, {session_key(channel, @owner), "run_owned"})

      process(component(channel, @owner, "lemon:idle:c:run_owned"), %{})
      assert_receive {:keep_run_alive, "run_owned", :continue}

      process(component(channel, @owner, "lemon:cancel:run_owned"), %{})
      assert_receive {:abort_run, "run_owned", :user_requested}
    end
  end

  test "model clicks from a denied location are refused", %{channel_id: channel} do
    click = component(channel, @owner, "lemon:model:providers:0")
    process(click, %{allowed_channel_ids: MapSet.new([1])})
    assert_receive {:interaction_response, ^click, %{data: %{content: text}}}
    assert text =~ "not available"
  end

  describe "/resume selection" do
    test "one user's selection never resumes another user's prompt", %{channel_id: channel} do
      :ok =
        TriggerMode.set(
          %LemonCore.ChatScope{transport: :discord, chat_id: channel},
          "default",
          :all
        )

      process(resume(channel, @owner, "lemon resume owner-native-session"), %{})
      assert_receive {:interaction_response, _, %{data: %{content: "Switched to session" <> _}}}

      assert %{meta: meta} = submit_message(channel, @stranger, "stranger prompt")
      refute meta[:resume]

      assert %{meta: meta} = submit_message(channel, @owner, "owner prompt")
      assert %ResumeToken{engine: "lemon", value: "owner-native-session"} = meta[:resume]
    end

    test "/reset clears the user's selection", %{channel_id: channel} do
      process(resume(channel, @owner, "lemon resume owner-native-session"), %{})
      assert_receive {:interaction_response, _, _}
      assert %ResumeToken{} = Store.get(:discord_selected_resume, session_key(channel, @owner))

      process(slash(channel, @owner, "reset", []), %{})
      assert_receive {:interaction_response, _, %{data: %{content: "Started a new session" <> _}}}
      assert Store.get(:discord_selected_resume, session_key(channel, @owner)) == nil
    end
  end

  defp submit_message(channel, user, text) do
    :ok = LemonChannels.Adapters.Discord.ThreadResolver.observe(%{id: channel, type: 0})

    message = %{
      "id" => Integer.to_string(1_503_803_470_493_300_000 + System.unique_integer([:positive])),
      "channel_id" => Integer.to_string(channel),
      "guild_id" => Integer.to_string(@guild_id),
      "content" => text,
      "author" => %{"id" => Integer.to_string(user), "bot" => false}
    }

    {:noreply, routed} =
      Transport.process_event({:discord_event, {:MESSAGE_CREATE, message, nil}}, state(%{}))

    [{scope_key, buffer}] = Map.to_list(routed.buffers)
    Transport.process_event({:debounce_flush, scope_key, buffer.debounce_ref}, routed)
    assert_receive {:submit_run, request}
    request
  end

  defp session_key(channel, user) do
    SessionKey.channel_peer(%{
      agent_id: "default",
      channel_id: "discord",
      account_id: "default",
      peer_kind: :group,
      peer_id: Integer.to_string(channel),
      thread_id: nil,
      sub_id: Integer.to_string(user)
    })
  end

  defp process(interaction, overrides) do
    assert {:noreply, _} =
             Transport.process_event(
               {:discord_event, {:INTERACTION_CREATE, interaction, nil}},
               state(overrides)
             )
  end

  defp state(overrides) do
    Map.merge(
      %{
        account_id: "default",
        bot_user_id: 1,
        allowed_guild_ids: nil,
        allowed_channel_ids: nil,
        deny_unbound_channels: false,
        model_pickers: %{},
        buffers: %{},
        reaction_runs: %{},
        pending_new: %{},
        debounce_ms: 10_000,
        dedupe_ttl_ms: 600_000,
        files: %{}
      },
      overrides
    )
  end

  defp component(channel, user, custom_id) do
    %{
      type: 3,
      id: Integer.to_string(1_503_803_470_493_258_000 + System.unique_integer([:positive])),
      channel_id: Integer.to_string(channel),
      guild_id: Integer.to_string(@guild_id),
      channel: %{id: Integer.to_string(channel), type: 0},
      data: %{custom_id: custom_id, values: []},
      member: %{user: %{id: Integer.to_string(user)}}
    }
  end

  defp resume(channel, user, selector),
    do: slash(channel, user, "resume", [%{name: "selector", value: selector}])

  defp slash(channel, user, name, options) do
    %{
      type: 2,
      id: Integer.to_string(1_503_803_470_493_257_000 + System.unique_integer([:positive])),
      channel_id: Integer.to_string(channel),
      guild_id: Integer.to_string(@guild_id),
      channel: %{id: Integer.to_string(channel), type: 0},
      data: %{name: name, options: options},
      member: %{user: %{id: Integer.to_string(user)}}
    }
  end

  defp restore(app, key, nil), do: Application.delete_env(app, key)
  defp restore(app, key, value), do: Application.put_env(app, key, value)
end
