defmodule LemonChannels.Adapters.Telegram.TransportCommandAuthorityTest do
  @moduledoc """
  Owner authority and target binding for destructive Telegram chat commands,
  exercised through the real transport with a fake Bot API.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Telegram.TriggerMode
  alias LemonCore.{ChatScope, Checkpoint, ResumeToken, RunStore, SessionKey}

  defmodule TestRouter do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def handle_inbound(_msg), do: :ok

    def submit(%LemonCore.RunRequest{} = request) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil),
        do: send(pid, {:submitted, request.prompt})

      {:ok, "run_#{System.unique_integer([:positive])}"}
    end

    def abort(_session_key, _reason), do: :ok
  end

  defmodule MockAPI do
    @updates_key {__MODULE__, :updates}
    @pid_key {__MODULE__, :pid}

    def set_updates(updates), do: :persistent_term.put(@updates_key, updates)
    def register_test(pid), do: :persistent_term.put(@pid_key, pid)

    def get_updates(_token, _offset, _timeout_ms) do
      case :persistent_term.get(@updates_key, []) do
        [next | rest] ->
          :persistent_term.put(@updates_key, rest)
          {:ok, %{"ok" => true, "result" => [next]}}

        [] ->
          {:ok, %{"ok" => true, "result" => []}}
      end
    end

    def send_message(_token, chat_id, text, _reply_to_or_opts \\ nil, _parse_mode \\ nil) do
      notify({:send_message, chat_id, text})
      {:ok, %{"ok" => true, "result" => %{"message_id" => System.unique_integer([:positive])}}}
    end

    # Every sender is a Telegram group admin: authority must come from owner?.
    def get_chat_member(_token, chat_id, user_id) do
      notify({:get_chat_member, chat_id, user_id})
      {:ok, %{"ok" => true, "result" => %{"status" => "administrator"}}}
    end

    defp notify(msg) do
      if pid = :persistent_term.get(@pid_key, nil), do: send(pid, msg)
      :ok
    end
  end

  @gateway_config_key :gateway_test_config
  @owner_id 7_100_001
  @stranger_id 7_100_002

  setup do
    unless Process.whereis(LemonChannels.Adapters.Telegram.AsyncSupervisor) do
      start_supervised!({Task.Supervisor, name: LemonChannels.Adapters.Telegram.AsyncSupervisor})
    end

    stop_transport()
    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_gateway_env = Application.get_env(:lemon_core, @gateway_config_key)

    :persistent_term.put({TestRouter, :pid}, self())
    MockAPI.register_test(self())

    case LemonChannels.Registry.register(LemonChannels.Adapters.Telegram) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
    end

    :ok = LemonCore.RouterBridge.configure(router: TestRouter, run_orchestrator: TestRouter)

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({MockAPI, :updates})
      :persistent_term.erase({MockAPI, :pid})
      :persistent_term.erase({TestRouter, :pid})
      _ = LemonChannels.Registry.unregister("telegram")

      if old_router_bridge,
        do: Application.put_env(:lemon_core, :router_bridge, old_router_bridge),
        else: Application.delete_env(:lemon_core, :router_bridge)

      if old_gateway_env,
        do: Application.put_env(:lemon_core, @gateway_config_key, old_gateway_env),
        else: Application.delete_env(:lemon_core, @gateway_config_key)
    end)

    :ok
  end

  describe "adminOnly commands" do
    test "a non-owner group admin cannot change the trigger mode" do
      chat_id = -System.unique_integer([:positive])

      MockAPI.set_updates([group_update(chat_id, @stranger_id, "/trigger all")])
      start_transport(allowed_chat_ids: [chat_id, @owner_id])

      assert_receive {:send_message, ^chat_id, text}, 2_000
      assert text =~ "Only the bot owner"
      assert TriggerMode.resolve("default", chat_id, nil).chat_mode == nil
    end

    test "the owner keeps changing the trigger mode" do
      chat_id = -System.unique_integer([:positive])

      MockAPI.set_updates([group_update(chat_id, @owner_id, "/trigger all")])
      start_transport(allowed_chat_ids: [chat_id, @owner_id])

      assert_receive {:send_message, ^chat_id, "Trigger mode set to all for this chat."}, 2_000
      assert TriggerMode.resolve("default", chat_id, nil).chat_mode == :all
    end

    test "/reload is not a chat command and never recompiles" do
      MockAPI.set_updates([dm_update(@owner_id, "/reload")])
      start_transport(allowed_chat_ids: [@owner_id])

      refute_receive {:send_message, _, "Recompiling..."}, 600
      refute "reload" in Enum.map(LemonChannels.CommandCatalog.catalog("telegram"), & &1["name"])
    end
  end

  describe "/checkpoint restore" do
    @tag :tmp_dir
    test "binds to the chat's own native session and needs the preview token", %{
      tmp_dir: tmp_dir
    } do
      native = "native-#{System.unique_integer([:positive])}"
      foreign = "native-foreign-#{System.unique_integer([:positive])}"
      seed_native_session(dm_session_key(@owner_id), native)

      path = Path.join(tmp_dir, "chat-owned.txt")
      foreign_path = Path.join(tmp_dir, "foreign.txt")
      File.write!(path, "before\n")
      File.write!(foreign_path, "foreign-before\n")

      on_exit(fn ->
        Checkpoint.delete_all(native)
        Checkpoint.delete_all(foreign)
      end)

      {:ok, own} = Checkpoint.create_filesystem(native, [path], cwd: tmp_dir)
      {:ok, other} = Checkpoint.create_filesystem(foreign, [foreign_path], cwd: tmp_dir)
      File.write!(path, "after\n")
      File.write!(foreign_path, "foreign-after\n")

      MockAPI.set_updates([
        dm_update(@owner_id, "/checkpoint restore #{other.id}"),
        dm_update(@owner_id, "/checkpoint restore #{own.id} confirm"),
        dm_update(@owner_id, "/checkpoint restore #{own.id}")
      ])

      start_transport(allowed_chat_ids: [@owner_id])

      assert_receive {:send_message, @owner_id, foreign_text}, 2_000
      assert foreign_text == "Checkpoint not found in this chat's session: #{other.id}"

      assert_receive {:send_message, @owner_id, word_text}, 2_000
      assert word_text =~ "nothing was restored"
      assert File.read!(path) == "after\n"

      assert_receive {:send_message, @owner_id, preview}, 2_000
      assert [_, token] = Regex.run(~r/restore #{own.id} ([A-Za-z0-9_-]{32,})/, preview)

      MockAPI.set_updates([dm_update(@owner_id, "/checkpoint restore #{own.id} #{token}")])
      assert_receive {:send_message, @owner_id, restored}, 2_000
      assert restored =~ "Checkpoint Restored"
      assert File.read!(path) == "before\n"
      assert File.read!(foreign_path) == "foreign-after\n"
    end
  end

  # The router binds a native session to the chat that created it; history
  # alone never makes a session the chat's checkpoint owner.
  defp seed_native_session(session_key, native_id) do
    run_id = "run_#{System.unique_integer([:positive])}"
    resume = %ResumeToken{engine: "lemon", value: native_id}
    assert :ok = LemonCore.NativeSessionOwner.bind(resume, session_key)

    assert :ok =
             RunStore.finalize(run_id, %{
               session_key: session_key,
               completed: %{ok: true, resume: resume}
             })

    deadline = System.monotonic_time(:millisecond) + 2_000
    wait_for_history(session_key, deadline)
  end

  defp wait_for_history(session_key, deadline) do
    cond do
      RunStore.history(session_key, limit: 1) != [] ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("run history was not recorded")

      true ->
        Process.sleep(20)
        wait_for_history(session_key, deadline)
    end
  end

  defp dm_session_key(user_id) do
    SessionKey.channel_peer(%{
      agent_id:
        LemonChannels.BindingResolver.resolve_agent_id(%ChatScope{
          transport: :telegram,
          chat_id: user_id,
          topic_id: nil
        }),
      channel_id: "telegram",
      account_id: "default",
      peer_kind: :dm,
      peer_id: to_string(user_id),
      thread_id: nil
    })
  end

  defp start_transport(overrides) do
    token = "authority-test-#{System.unique_integer([:positive])}"

    config =
      %{
        account_id: "default",
        bot_token: token,
        api_mod: MockAPI,
        poll_interval_ms: 10,
        debounce_ms: 10,
        deny_unbound_chats: false
      }
      |> Map.merge(Map.new(overrides))

    existing = Application.get_env(:lemon_core, @gateway_config_key, %{})

    Application.put_env(
      :lemon_core,
      @gateway_config_key,
      Map.merge(existing, %{telegram: %{bot_token: token, api_mod: MockAPI}, bindings: []})
    )

    {:ok, pid} = LemonChannels.Adapters.Telegram.Transport.start_link(config: config)
    pid
  end

  defp group_update(chat_id, user_id, text) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "date" => 1,
        "chat" => %{"id" => chat_id, "type" => "supergroup"},
        "from" => %{"id" => user_id, "username" => "u#{user_id}", "first_name" => "U"},
        "text" => text
      }
    }
  end

  defp dm_update(user_id, text) do
    %{
      "update_id" => System.unique_integer([:positive]),
      "message" => %{
        "message_id" => System.unique_integer([:positive]),
        "date" => 1,
        "chat" => %{"id" => user_id, "type" => "private"},
        "from" => %{"id" => user_id, "username" => "u#{user_id}", "first_name" => "U"},
        "text" => text
      }
    }
  end

  defp stop_transport do
    if pid = Process.whereis(LemonChannels.Adapters.Telegram.Transport) do
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end
  catch
    :exit, _ -> :ok
  end
end
