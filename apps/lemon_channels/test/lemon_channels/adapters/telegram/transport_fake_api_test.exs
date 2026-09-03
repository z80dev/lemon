defmodule LemonChannels.Adapters.Telegram.TransportFakeApiTest do
  @moduledoc """
  Hermetic transport round trips through `LemonChannels.Telegram.FakeAPI`:
  the real transport boots against the fake, consumes fabricated updates
  with real getUpdates offset semantics, and its outbound API calls are
  captured and awaited — no network, no real Telegram.
  """

  use ExUnit.Case, async: false

  alias LemonChannels.Telegram.FakeAPI
  alias LemonChannels.Adapters.Telegram

  defmodule FakeApiTestRouter do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def handle_inbound(msg) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:inbound, msg})
      end

      :ok
    end

    def submit(%LemonCore.RunRequest{} = request) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:inbound, inbound_from_request(request)})
      end

      {:ok, "run_#{System.unique_integer([:positive])}"}
    end

    defp inbound_from_request(%LemonCore.RunRequest{} = request) do
      meta = request.meta || %{}

      %LemonCore.InboundMessage{
        channel_id: meta[:channel_id],
        account_id: meta[:account_id],
        peer: meta[:peer],
        sender: meta[:sender],
        message: %{
          id: meta[:user_msg_id] && to_string(meta[:user_msg_id]),
          text: request.prompt,
          timestamp: nil,
          reply_to_id: nil
        },
        raw: meta[:raw],
        meta: meta
      }
    end
  end

  defmodule FakeBackgroundRuntime do
    def background_start("index the repository", opts) do
      :persistent_term.put({__MODULE__, :owner_session}, opts[:session_key])
      {:ok, %{id: "bg_telegram_full_identifier", status: :queued}}
    end

    def background_list_scoped(session_key, []) do
      if owner?(session_key) do
        [%{id: "bg_telegram_full_identifier", status: :completed, result_available: true}]
      else
        []
      end
    end

    def background_status_scoped("bg_telegram_full_identifier", session_key) do
      if owner?(session_key),
        do:
          {:ok, %{id: "bg_telegram_full_identifier", status: :completed, result_available: true}},
        else: {:error, :not_found}
    end

    def background_result_scoped("bg_telegram_full_identifier", session_key) do
      if owner?(session_key),
        do: {:ok, "Telegram checks passed."},
        else: {:error, :not_found}
    end

    def background_cancel_scoped("bg_telegram_full_identifier", session_key) do
      if owner?(session_key) do
        if pid = :persistent_term.get({__MODULE__, :test_pid}, nil),
          do: send(pid, :telegram_background_cancelled)

        :ok
      else
        {:error, :not_found}
      end
    end

    defp owner?(session_key),
      do: session_key == :persistent_term.get({__MODULE__, :owner_session}, nil)
  end

  setup do
    stop_transport()
    FakeAPI.reset()

    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    :persistent_term.put({FakeApiTestRouter, :pid}, self())

    :ok =
      LemonCore.RouterBridge.configure(
        router: FakeApiTestRouter,
        run_orchestrator: FakeApiTestRouter
      )

    on_exit(fn ->
      stop_transport()
      FakeAPI.reset()
      :persistent_term.erase({FakeApiTestRouter, :pid})
      :persistent_term.erase({FakeBackgroundRuntime, :owner_session})
      :persistent_term.erase({FakeBackgroundRuntime, :test_pid})
      restore_router_bridge(old_router_bridge)
    end)

    :ok
  end

  describe "getUpdates offset semantics (FakeAPI direct)" do
    test "returns queued updates at or above the offset, and confirms below it" do
      u1 = FakeAPI.simulate_message(1_001, "first")
      u2 = FakeAPI.simulate_message(1_001, "second")
      u3 = FakeAPI.simulate_message(1_001, "third")

      assert {:ok, %{"ok" => true, "result" => all}} = FakeAPI.get_updates("t", 0, 0)

      assert Enum.map(all, & &1["update_id"]) == [
               u1["update_id"],
               u2["update_id"],
               u3["update_id"]
             ]

      # Re-delivered until confirmed by a higher offset (real Telegram behavior).
      assert {:ok, %{"result" => again}} = FakeAPI.get_updates("t", u1["update_id"], 0)
      assert length(again) == 3

      # Offset confirms everything below it.
      assert {:ok, %{"result" => tail}} = FakeAPI.get_updates("t", u2["update_id"], 0)
      assert Enum.map(tail, & &1["update_id"]) == [u2["update_id"], u3["update_id"]]

      assert {:ok, %{"result" => []}} = FakeAPI.get_updates("t", u3["update_id"] + 1, 0)
    end

    test "long-poll delivers a pushed update before the timeout, and times out empty" do
      assert {:ok, %{"result" => []}} = FakeAPI.get_updates("t", 0, 30)

      task = Task.async(fn -> FakeAPI.get_updates("t", 0, 1_000) end)
      Process.sleep(20)
      update = FakeAPI.simulate_message(2_002, "late arrival")

      assert {:ok, %{"ok" => true, "result" => [delivered]}} = Task.await(task, 2_000)
      assert delivered["update_id"] == update["update_id"]
      assert delivered["message"]["text"] == "late arrival"
    end
  end

  describe "transport round trip" do
    test "portable /commands is handled by the running transport and delivered through Telegram" do
      chat_id = 310_000
      gateway_config_key = :"Elixir.LemonGateway.Config"
      previous_gateway_config = Application.get_env(:lemon_gateway, gateway_config_key)

      Application.put_env(:lemon_gateway, gateway_config_key, %{
        telegram: %{bot_token: "fake-token", api_mod: FakeAPI}
      })

      on_exit(fn ->
        if previous_gateway_config do
          Application.put_env(:lemon_gateway, gateway_config_key, previous_gateway_config)
        else
          Application.delete_env(:lemon_gateway, gateway_config_key)
        end
      end)

      assert {:ok, _pid} = start_transport(%{allowed_chat_ids: [chat_id]})

      _update = FakeAPI.simulate_message(chat_id, "/commands")

      assert {:ok, %{fun: :send_message, args: [^chat_id, text, _opts, _parse_mode]}} =
               FakeAPI.await_send(
                 fn
                   %{fun: :send_message, args: [^chat_id, text, _, _]} ->
                     String.contains?(text, "/queue <prompt>") and
                       String.contains?(text, "/bg <prompt>") and
                       String.contains?(text, "/btw <question>")

                   _ ->
                     false
                 end,
                 2_000
               )

      assert text =~ "Information"
      refute_received {:inbound, _msg}
    end

    test "portable /bg returns a full id and retrieves its result through Telegram" do
      chat_id = 310_010
      foreign_chat_id = 310_011
      gateway_config_key = :"Elixir.LemonGateway.Config"
      previous_gateway_config = Application.get_env(:lemon_gateway, gateway_config_key)
      previous_runtime = Application.get_env(:lemon_control_plane, :agent_runtime_provider)

      Application.put_env(:lemon_gateway, gateway_config_key, %{
        telegram: %{bot_token: "fake-token", api_mod: FakeAPI}
      })

      Application.put_env(
        :lemon_control_plane,
        :agent_runtime_provider,
        FakeBackgroundRuntime
      )

      :persistent_term.put({FakeBackgroundRuntime, :test_pid}, self())

      on_exit(fn ->
        if previous_gateway_config do
          Application.put_env(:lemon_gateway, gateway_config_key, previous_gateway_config)
        else
          Application.delete_env(:lemon_gateway, gateway_config_key)
        end

        if previous_runtime do
          Application.put_env(:lemon_control_plane, :agent_runtime_provider, previous_runtime)
        else
          Application.delete_env(:lemon_control_plane, :agent_runtime_provider)
        end
      end)

      assert {:ok, _pid} = start_transport(%{allowed_chat_ids: [chat_id, foreign_chat_id]})

      _update = FakeAPI.simulate_message(chat_id, "/bg index the repository")

      assert {:ok, %{fun: :send_message, args: [^chat_id, receipt, _, _]}} =
               FakeAPI.await_send(
                 fn
                   %{fun: :send_message, args: [^chat_id, text, _, _]} ->
                     String.contains?(text, "Background run started: bg_telegram_full_identifier")

                   _ ->
                     false
                 end,
                 2_000
               )

      assert receipt =~ "/bg result bg_telegram_full_identifier"

      _update = FakeAPI.simulate_message(chat_id, "/bg result bg_telegram_full_identifier")

      assert {:ok, %{fun: :send_message, args: [^chat_id, result, _, _]}} =
               FakeAPI.await_send(
                 fn
                   %{fun: :send_message, args: [^chat_id, text, _, _]} ->
                     String.contains?(text, "Background result bg_telegram_full_identifier")

                   _ ->
                     false
                 end,
                 2_000
               )

      assert result =~ "Telegram checks passed."

      _update = FakeAPI.simulate_message(foreign_chat_id, "/bg list")

      assert {:ok, %{args: [^foreign_chat_id, "No background runs are recorded.", _, _]}} =
               FakeAPI.await_send(
                 fn
                   %{fun: :send_message, args: [^foreign_chat_id, text, _, _]} ->
                     text == "No background runs are recorded."

                   _ ->
                     false
                 end,
                 2_000
               )

      for action <- ["status", "result", "cancel"] do
        _update =
          FakeAPI.simulate_message(
            foreign_chat_id,
            "/bg #{action} bg_telegram_full_identifier"
          )

        assert {:ok, %{args: [^foreign_chat_id, "Background run not found.", _, _]}} =
                 FakeAPI.await_send(
                   fn
                     %{fun: :send_message, args: [^foreign_chat_id, text, _, _]} ->
                       text == "Background run not found."

                     _ ->
                       false
                   end,
                   2_000
                 )
      end

      refute_received :telegram_background_cancelled
      refute_received {:inbound, _msg}
    end

    test "inbound private message flows through the pipeline to router and captured outbound" do
      chat_id = 310_001
      assert {:ok, _pid} = start_transport(%{allowed_chat_ids: [chat_id]})

      update = FakeAPI.simulate_message(chat_id, "hello hermetic world")

      assert_receive {:inbound, msg}, 2_000
      assert msg.meta[:chat_id] == chat_id
      assert msg.message.text == "hello hermetic world"

      # The transport reacts to accepted messages with a progress reaction —
      # an outbound API call the fake captured.
      user_msg_id = update["message"]["message_id"]

      assert {:ok, %{fun: :set_message_reaction, args: [^chat_id, ^user_msg_id, "👀", _]}} =
               FakeAPI.await_send(:set_message_reaction, 2_000)

      # The poller confirms the consumed update with an advanced offset.
      expected_offset = update["update_id"] + 1

      assert {:ok, %{fun: :get_updates}} =
               FakeAPI.await_send(
                 fn
                   %{fun: :get_updates, args: [offset, _]} -> offset == expected_offset
                   _ -> false
                 end,
                 2_000
               )
    end

    test "inbound supergroup forum-topic message carries the thread id" do
      chat_id = -100_320_002
      thread_id = 777

      assert {:ok, _pid} = start_transport(%{allowed_chat_ids: [chat_id]})

      _update =
        FakeAPI.simulate_message(chat_id, "topic message",
          chat_type: "supergroup",
          message_thread_id: thread_id
        )

      assert_receive {:inbound, msg}, 2_000
      assert msg.meta[:chat_id] == chat_id
      assert msg.meta[:topic_id] == thread_id
      assert msg.message.text == "topic message"
    end

    test "callback query flows through the pipeline and is answered" do
      chat_id = 330_003
      assert {:ok, _pid} = start_transport(%{allowed_chat_ids: [chat_id]})

      update = FakeAPI.simulate_callback_query(chat_id, "unknown|decision")
      cb_id = update["callback_query"]["id"]

      assert {:ok, %{fun: :answer_callback_query, args: [^cb_id, %{"text" => "Unknown"}]}} =
               FakeAPI.await_send(:answer_callback_query, 2_000)
    end
  end

  describe "capture introspection" do
    test "sent/1 filters, await_send matches history, clear/0 drops captures" do
      {:ok, _} = FakeAPI.send_message("t", 42, "already sent", nil, nil)

      assert [%{fun: :send_message, args: [42, "already sent", nil, nil]}] =
               FakeAPI.sent(:send_message)

      # Already-captured calls satisfy await_send immediately.
      assert {:ok, %{fun: :send_message}} = FakeAPI.await_send(:send_message, 10)

      :ok = FakeAPI.clear()
      assert FakeAPI.sent() == []
      assert {:error, :timeout} = FakeAPI.await_send(:send_message, 20)
    end

    test "file stubs round-trip through get_file/download_file" do
      :ok = FakeAPI.put_file("photo-1", <<1, 2, 3, 4>>)

      assert {:ok, %{"ok" => true, "result" => %{"file_path" => path}}} =
               FakeAPI.get_file("t", "photo-1")

      assert {:ok, <<1, 2, 3, 4>>} = FakeAPI.download_file("t", path)
    end
  end

  defp start_transport(overrides) when is_map(overrides) do
    token = "fake-token-" <> Integer.to_string(System.unique_integer([:positive]))

    config =
      %{
        bot_token: token,
        api_mod: FakeAPI,
        poll_interval_ms: 10,
        debounce_ms: 10
      }
      |> Map.merge(overrides)

    case LemonChannels.Registry.register(Telegram) do
      :ok -> :ok
      {:error, :already_registered} -> :ok
    end

    Telegram.Transport.start_link(config: config)
  end

  defp restore_router_bridge(nil), do: Application.delete_env(:lemon_core, :router_bridge)
  defp restore_router_bridge(config), do: Application.put_env(:lemon_core, :router_bridge, config)

  defp stop_transport do
    if pid = Process.whereis(LemonChannels.Adapters.Telegram.Transport) do
      if Process.alive?(pid) do
        GenServer.stop(pid, :normal)
      end
    end

    if Process.whereis(LemonChannels.Registry) do
      LemonChannels.Registry.unregister("telegram")
    end
  catch
    :exit, _ -> :ok
  end
end
