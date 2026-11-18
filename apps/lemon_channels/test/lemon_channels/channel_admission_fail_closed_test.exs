defmodule LemonChannels.ChannelAdmissionFailClosedTest do
  # Swaps the default Store's backend, so it cannot run beside other tests.
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Discord.Transport
  alias LemonChannels.Adapters.Discord.TriggerMode, as: DiscordTriggerMode

  alias LemonChannels.Adapters.Telegram.Transport.{
    ChatPreferences,
    InboundActions,
    ResumeSelection
  }

  alias LemonChannels.Telegram.StateStore
  alias LemonChannels.Telegram.TriggerMode, as: TelegramTriggerMode
  alias LemonCore.{ChatScope, ResumeToken, Store}
  alias LemonCore.Dedupe.Ets
  alias LemonCore.Store.EtsBackend

  @bot_user_id 1_476_753_643_834_183_690
  @channel_id 1_475_727_417_372_049_419
  @gateway_config_key :"Elixir.LemonGateway.Config"

  # Fails selected `{operation, table}` pairs inside the real Store process.
  defmodule FaultBackend do
    @behaviour LemonCore.Store.Backend

    def fail(op, table), do: :persistent_term.put({__MODULE__, op, table}, true)
    def heal(op, table), do: :persistent_term.erase({__MODULE__, op, table})

    defp faulted(op, table, fun) do
      if :persistent_term.get({__MODULE__, op, table}, false),
        do: {:error, :injected_store_failure},
        else: fun.()
    end

    defdelegate init(opts), to: EtsBackend
    defdelegate sync(state), to: EtsBackend
    defdelegate sweep(state, table, predicate), to: EtsBackend
    defdelegate compare_and_delete_many(state, entries), to: EtsBackend

    def get(s, t, k), do: faulted(:get, t, fn -> EtsBackend.get(s, t, k) end)
    def put(s, t, k, v), do: faulted(:put, t, fn -> EtsBackend.put(s, t, k, v) end)
    def put_new(s, t, k, v), do: faulted(:put_new, t, fn -> EtsBackend.put_new(s, t, k, v) end)
    def delete(s, t, k), do: faulted(:delete, t, fn -> EtsBackend.delete(s, t, k) end)
    def list(s, t), do: faulted(:list, t, fn -> EtsBackend.list(s, t) end)
  end

  defmodule FakeRouter do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def submit(run_request) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:submit_run, run_request})
      {:ok, "run_fail_closed_#{System.unique_integer([:positive])}"}
    end

    def abort_run(_run_id, _reason), do: :ok
    def keep_run_alive(_run_id, _decision), do: :ok
  end

  defmodule FakeDiscordApi do
    def create(channel_id, params) do
      send(self(), {:discord_create, channel_id, params})
      {:ok, %{id: 4444}}
    end

    def edit(_channel_id, message_id, _params), do: {:ok, %{id: message_id}}
    def delete(_channel_id, _message_id), do: {:ok, %{}}
    def react(_channel_id, _message_id, _emoji), do: {:ok}
    def unreact(_channel_id, _message_id, _emoji), do: {:ok}
    def start_typing(_channel_id), do: {:ok}
  end

  defmodule FakeTelegramApi do
    def set_message_reaction(_token, _chat_id, _message_id, _emoji, _opts),
      do: {:ok, %{"ok" => true}}

    def send_chat_action(_token, _chat_id, _thread_id, _action), do: {:ok, %{"ok" => true}}
  end

  setup do
    start_supervised!({Task.Supervisor, name: LemonChannels.Adapters.Discord.AsyncSupervisor})

    %{backend: EtsBackend} = :sys.get_state(Store)
    :sys.replace_state(Store, &%{&1 | backend: FaultBackend})

    previous_bridge = Application.get_env(:lemon_core, :router_bridge)
    previous_gateway = Application.get_env(:lemon_gateway, @gateway_config_key)
    previous_test_mode = Application.get_env(:lemon_core, :config_test_mode)

    :persistent_term.put({FakeRouter, :test_pid}, self())
    :ok = LemonCore.RouterBridge.configure(router: FakeRouter, run_orchestrator: FakeRouter)
    Application.put_env(:lemon_core, :config_test_mode, true)

    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      enable_discord: true,
      discord: %{api_mod: FakeDiscordApi}
    })

    :ok = Ets.init(:lemon_channels_discord_dedupe)
    _ = :ets.delete_all_objects(:lemon_channels_discord_dedupe)

    on_exit(fn ->
      for key <- :persistent_term.get() |> Enum.map(&elem(&1, 0)),
          match?({FaultBackend, _, _}, key),
          do: :persistent_term.erase(key)

      :sys.replace_state(Store, &%{&1 | backend: EtsBackend})
      :persistent_term.erase({FakeRouter, :test_pid})
      restore_env(:lemon_core, :router_bridge, previous_bridge)
      restore_env(:lemon_gateway, @gateway_config_key, previous_gateway)
      restore_env(:lemon_core, :config_test_mode, previous_test_mode)
    end)

    :ok
  end

  describe "Discord persistent ingress dedupe" do
    test "a replay whose receipt cannot be read is never submitted or overwritten" do
      before = discord_receipts()
      message = discord_message(unique_id(), "<@#{@bot_user_id}> exactly once")
      state = submit_and_flush(message)
      assert_receive {:submit_run, _run_request}

      receipts = discord_receipts()
      assert map_size(receipts) == map_size(before) + 1

      # The in-memory dedupe state is lost (restart) and the persistent read fails.
      _ = :ets.delete_all_objects(:lemon_channels_discord_dedupe)
      FaultBackend.fail(:get, :idempotency)

      assert {:noreply, replayed} =
               Transport.process_event({:discord_event, {:MESSAGE_CREATE, message, nil}}, state)

      FaultBackend.heal(:get, :idempotency)

      assert replayed.buffers == %{}
      refute_receive {:submit_run, _}, 100
      assert discord_receipts() == receipts
    end
  end

  describe "Discord selected resume" do
    test "an unreadable selection rejects the submission and stays stored" do
      key = {"default", @channel_id, nil}
      selection = %ResumeToken{engine: "lemon", value: "selected-#{unique_id()}"}
      :ok = Store.put(:discord_selected_resume, key, selection)
      on_exit(fn -> Store.delete(:discord_selected_resume, key) end)

      FaultBackend.fail(:get, :discord_selected_resume)
      _state = submit_and_flush(discord_message(unique_id(), "<@#{@bot_user_id}> continue"))
      FaultBackend.heal(:get, :discord_selected_resume)

      refute_receive {:submit_run, _}, 100
      assert Store.fetch(:discord_selected_resume, key) == {:ok, selection}

      # Once readable, the next message resumes the selected session.
      _state = submit_and_flush(discord_message(unique_id(), "<@#{@bot_user_id}> continue"))
      assert_receive {:submit_run, run_request}
      assert run_request.meta.resume == selection
    end
  end

  describe "Discord trigger policy" do
    test "an unreadable thread override never falls through to the channel's all mode" do
      thread_id = 1_505_676_123_466_502_334 + System.unique_integer([:positive])
      channel_scope = %ChatScope{transport: :discord, chat_id: @channel_id, topic_id: nil}
      thread_scope = %ChatScope{transport: :discord, chat_id: @channel_id, topic_id: thread_id}
      :ok = DiscordTriggerMode.set(channel_scope, "default", :all)
      :ok = DiscordTriggerMode.set(thread_scope, "default", :mentions)

      on_exit(fn ->
        Store.delete(:discord_chat_trigger_mode, {"default", @channel_id})
        DiscordTriggerMode.clear_topic("default", @channel_id, thread_id)
      end)

      FaultBackend.fail(:get, :discord_topic_trigger_mode)

      assert %{mode: :mentions} = DiscordTriggerMode.resolve("default", @channel_id, thread_id)

      message =
        discord_message(unique_id(), "unaddressed chatter")
        |> Map.put("thread_id", Integer.to_string(thread_id))

      assert {:noreply, state} =
               Transport.process_event(
                 {:discord_event, {:MESSAGE_CREATE, message, nil}},
                 discord_state()
               )

      assert state.buffers == %{}
    end
  end

  describe "Telegram selected resume" do
    test "an unreadable selection rejects the submission and stays stored" do
      chat_id = 777_000 + System.unique_integer([:positive])
      key = {"default", chat_id, nil}
      selection = %ResumeToken{engine: "lemon", value: "selected-#{chat_id}"}
      :ok = StateStore.put_selected_resume(key, selection)
      on_exit(fn -> StateStore.delete_selected_resume(key) end)

      FaultBackend.fail(:get, :telegram_selected_resume)
      submit_telegram(chat_id, "keep going")
      FaultBackend.heal(:get, :telegram_selected_resume)

      refute_receive {:submit_run, _}, 100
      assert_receive {:telegram_failure, text}
      assert text =~ "couldn't queue"
      assert Store.fetch(:telegram_selected_resume, key) == {:ok, selection}

      submit_telegram(chat_id, "keep going")
      assert_receive {:submit_run, run_request}
      assert run_request.meta.resume == selection
    end
  end

  describe "Telegram trigger policy" do
    test "an unreadable topic override never falls through to the chat's all mode" do
      chat_id = -1_000_000 - System.unique_integer([:positive])
      topic_id = 42

      :ok =
        TelegramTriggerMode.set(
          %ChatScope{transport: :telegram, chat_id: chat_id},
          "default",
          :all
        )

      :ok =
        TelegramTriggerMode.set(
          %ChatScope{transport: :telegram, chat_id: chat_id, topic_id: topic_id},
          "default",
          :mentions
        )

      on_exit(fn ->
        Store.delete(:telegram_chat_trigger_mode, {"default", chat_id})
        TelegramTriggerMode.clear_topic("default", chat_id, topic_id)
      end)

      FaultBackend.fail(:get, :telegram_topic_trigger_mode)

      assert %{mode: :mentions} = TelegramTriggerMode.resolve("default", chat_id, topic_id)

      inbound = %{
        peer: %{
          kind: :group,
          id: Integer.to_string(chat_id),
          thread_id: Integer.to_string(topic_id)
        },
        raw: %{"message" => %{"text" => "unaddressed chatter", "message_thread_id" => topic_id}},
        message: %{text: "unaddressed chatter"},
        meta: %{chat_id: chat_id, topic_id: topic_id}
      }

      state = %{account_id: "default", bot_username: "lemon_bot", bot_id: 99}
      callbacks = %{extract_chat_ids: fn _ -> {chat_id, topic_id} end}

      assert ChatPreferences.should_ignore_for_trigger?(
               state,
               inbound,
               "unaddressed chatter",
               callbacks
             )
    end
  end

  # -- Discord helpers ----------------------------------------------------------

  defp submit_and_flush(message) do
    assert {:noreply, routed} =
             Transport.process_event(
               {:discord_event, {:MESSAGE_CREATE, message, nil}},
               discord_state()
             )

    case Map.to_list(routed.buffers) do
      [{scope_key, buffer}] ->
        assert {:noreply, flushed} =
                 Transport.process_event(
                   {:debounce_flush, scope_key, buffer.debounce_ref},
                   routed
                 )

        flushed

      [] ->
        routed
    end
  end

  defp discord_receipts do
    Store.list(:idempotency)
    |> Enum.filter(fn {key, _value} -> is_binary(key) and String.starts_with?(key, "discord") end)
    |> Map.new()
  end

  defp discord_state do
    %{
      account_id: "default",
      bot_user_id: @bot_user_id,
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
    }
  end

  defp discord_message(id, content) do
    %{
      "id" => id,
      "channel_id" => Integer.to_string(@channel_id),
      "guild_id" => "1475727416549969980",
      "content" => content,
      "author" => %{"id" => "1476753643834183691", "bot" => false}
    }
  end

  defp unique_id,
    do: Integer.to_string(1_503_803_470_493_400_000 + System.unique_integer([:positive]))

  # -- Telegram helpers ---------------------------------------------------------

  defp submit_telegram(chat_id, text) do
    parent = self()
    msg_id = System.unique_integer([:positive])

    inbound = %LemonCore.InboundMessage{
      channel_id: "telegram",
      account_id: "default",
      peer: %{kind: :dm, id: Integer.to_string(chat_id), thread_id: nil},
      sender: %{id: Integer.to_string(chat_id), username: "operator", display_name: "Operator"},
      message: %{id: Integer.to_string(msg_id), text: text, timestamp: nil, reply_to_id: nil},
      raw: %{},
      meta: %{chat_id: chat_id, user_msg_id: msg_id}
    }

    inbound = ResumeSelection.maybe_apply_selected_resume("default", inbound, text)

    callbacks = %{
      extract_explicit_resume_and_strip: &ResumeSelection.extract_explicit_resume_and_strip/1,
      extract_message_ids: fn _ -> {chat_id, nil, msg_id} end,
      current_thread_generation: fn _state, _chat_id, _thread_id -> 0 end,
      maybe_index_telegram_msg_session: fn _state, _scope, _session_key, _ids -> :ok end,
      maybe_subscribe_to_session: fn _session_key -> :ok end,
      resolve_model_hint: fn _state, _session_key, _chat_id, _thread_id -> {nil, nil} end,
      resolve_session_key: fn _state, _inbound, _scope, _meta ->
        {"agent:default:telegram:default:dm:#{chat_id}", false}
      end,
      resolve_thinking_hint: fn _state, _chat_id, _thread_id -> {nil, nil} end,
      send_submission_failure: fn _state, _chat_id, _thread_id, _msg_id, failure ->
        send(parent, {:telegram_failure, failure})
      end,
      send_system_message: fn _state, _chat_id, _thread_id, _msg_id, message ->
        send(parent, {:telegram_system, message})
      end
    }

    state = %{account_id: "default", api_mod: FakeTelegramApi, token: "token", reaction_runs: %{}}
    InboundActions.execute_inbound_message(state, inbound, callbacks)
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
