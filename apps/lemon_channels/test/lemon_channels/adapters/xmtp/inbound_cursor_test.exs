defmodule LemonChannels.Adapters.Xmtp.InboundCursorTest do
  @moduledoc """
  XMTP persists a per-conversation `sent_at_ns` high-water mark, so a restart
  (or a key evicted from the bounded seen set) never resubmits history, and
  every submission carries a stable run identity for router-side dedupe.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Xmtp.CursorStore
  alias LemonChannels.Adapters.Xmtp.Transport

  @gateway_config_key :gateway_test_config
  @inbox "inbox-cursor-friend"

  defmodule CursorRouter do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def handle_inbound(_msg), do: :ok

    def submit(%LemonCore.RunRequest{} = request) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:submitted, request.prompt, request.run_id, request.meta || %{}})
      end

      {:ok, request.run_id}
    end
  end

  defmodule RejectingRouter do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def handle_inbound(_msg), do: :ok
    def submit(_request), do: {:error, :unavailable}
  end

  setup do
    stop_transport()
    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_gateway_env = Application.get_env(:lemon_core, @gateway_config_key)
    :persistent_term.put({CursorRouter, :pid}, self())
    :ok = LemonCore.RouterBridge.configure(router: CursorRouter, run_orchestrator: CursorRouter)

    Application.put_env(:lemon_core, @gateway_config_key, %{
      enable_xmtp: true,
      xmtp: %{require_live: false, poll_interval_ms: 30_000, allowed_inboxes: [@inbox]}
    })

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({CursorRouter, :pid})
      restore_env(:lemon_core, :router_bridge, old_router_bridge)
      restore_env(:lemon_core, @gateway_config_key, old_gateway_env)
    end)

    {:ok, account: "cursor-#{System.unique_integer([:positive])}"}
  end

  @tag capture_log: true
  test "a key evicted from the seen set is never resubmitted", %{account: account} do
    pid = start_transport(account)
    # More history than @max_inbound_dedupe_entries (2_000) evicts the oldest keys.
    count = 2_010

    for n <- 1..count, do: send(pid, {:xmtp_bridge_event, message("conv-evict", n)})
    assert submitted_count() == count

    state = :sys.get_state(pid)
    assert state.seen_inbound_count == 2_000

    refute LemonCore.Dedupe.Ets.seen?(
             :lemon_channels_xmtp_dedupe,
             Transport.inbound_dedupe_key_for_test(message("conv-evict", 1)),
             :infinity
           )

    # The bridge re-emits the evicted first message: the cursor stops it.
    send(pid, {:xmtp_bridge_event, message("conv-evict", 1)})
    :sys.get_state(pid)
    refute_received {:submitted, _, _, _}
    assert {:ok, %{"conv-evict" => ^count}} = CursorStore.load(account)
  end

  @tag capture_log: true
  test "a restart resumes after the persisted cursor and polls with it", %{account: account} do
    pid = start_transport(account)
    for n <- 1..3, do: send(pid, {:xmtp_bridge_event, message("conv-restart", n)})
    assert submitted_count() == 3
    stop_transport()

    pid = start_transport(account)
    assert :sys.get_state(pid).cursors == %{"conv-restart" => 3}

    port_server = :sys.get_state(pid).port_server
    :erlang.trace(port_server, true, [:receive])
    send(pid, :poll)

    assert_receive {:trace, ^port_server, :receive,
                    {:"$gen_cast",
                     {:command, %{"op" => "poll", "cursors" => %{"conv-restart" => "3"}}}}},
                   1_000

    for n <- 1..3, do: send(pid, {:xmtp_bridge_event, message("conv-restart", n)})
    send(pid, {:xmtp_bridge_event, message("conv-restart", 4)})
    assert_receive {:submitted, "hello 4", run_id, _meta}, 1_000
    assert "run_xmtp_" <> _ = run_id
    :sys.get_state(pid)
    refute_received {:submitted, _, _, _}
  end

  @tag capture_log: true
  test "a definitely rejected message pins the cursor below it until it succeeds",
       %{account: account} do
    pid = start_transport(account)
    send(pid, {:xmtp_bridge_event, message("conv-floor", 1)})
    assert submitted_count() == 1

    :persistent_term.put({CursorRouter, :pid}, nil)

    :ok =
      LemonCore.RouterBridge.configure(router: RejectingRouter, run_orchestrator: RejectingRouter)

    send(pid, {:xmtp_bridge_event, message("conv-floor", 2)})
    assert %{cursor_floors: %{"conv-floor" => {2, _}}} = :sys.get_state(pid)
    :ok = LemonCore.RouterBridge.configure(router: CursorRouter, run_orchestrator: CursorRouter)
    :persistent_term.put({CursorRouter, :pid}, self())
    send(pid, {:xmtp_bridge_event, message("conv-floor", 3)})
    assert_receive {:submitted, "hello 3", _, _}, 1_000

    assert {:ok, %{"conv-floor" => 1}} = CursorStore.load(account)

    send(pid, {:xmtp_bridge_event, message("conv-floor", 2)})
    assert_receive {:submitted, "hello 2", _, _}, 1_000
    :sys.get_state(pid)
    assert {:ok, %{"conv-floor" => 3}} = CursorStore.load(account)
  end

  @tag :node
  @tag :tmp_dir
  @tag capture_log: true
  test "a fake bridge with 100 historical messages yields no runs after a restart and one for a new message",
       %{account: account, tmp_dir: tmp_dir} do
    sdk = write_fake_sdk(tmp_dir, 100)

    start_live_transport(account, sdk)
    assert submitted_count(100, 30_000) == 100
    stop_transport()

    pid = start_live_transport(account, sdk)
    assert_receive {:xmtp_bridge_event_seen, :connected}, 30_000
    # Several polls of the unchanged history produce nothing.
    refute_receive {:submitted, _, _, _}, 600

    File.write!(Path.join(tmp_dir, "extra.json"), ~s([{"n": 101, "text": "brand new"}]))
    assert_receive {:submitted, "brand new", "run_xmtp_" <> _, _}, 10_000
    refute_receive {:submitted, _, _, _}, 600
    assert Process.alive?(pid)
  end

  defp start_transport(account) do
    script =
      Path.join(System.tmp_dir!(), "xmtp_missing_#{System.unique_integer([:positive])}.mjs")

    {:ok, pid} =
      Transport.start_link(
        config: %{
          bridge_script: script,
          require_live: false,
          connect_timeout_ms: 5_000,
          account_id: account
        }
      )

    send(pid, {:xmtp_bridge_event, %{"type" => "connected", "mode" => "live"}})
    pid
  end

  defp start_live_transport(account, sdk) do
    test_pid = self()

    {:ok, pid} =
      Transport.start_link(
        config: %{
          sdk_module: sdk,
          require_live: true,
          poll_interval_ms: 50,
          connect_timeout_ms: 30_000,
          account_id: account
        }
      )

    spawn_link(fn -> await_connected(pid, test_pid) end)
    pid
  end

  defp await_connected(pid, test_pid) do
    if Process.alive?(pid) and :sys.get_state(pid).connected? do
      send(test_pid, {:xmtp_bridge_event_seen, :connected})
    else
      Process.sleep(20)
      await_connected(pid, test_pid)
    end
  catch
    :exit, _ -> :ok
  end

  defp message(conversation_id, n) do
    %{
      "type" => "message",
      "conversation_id" => conversation_id,
      "sender_inbox_id" => @inbox,
      "sender_address" => "0x2222222222222222222222222222222222222222",
      "message_id" => "#{conversation_id}-#{n}",
      "bridge_dedupe_key" => "#{conversation_id}:#{n}",
      "sent_at_ns" => Integer.to_string(n),
      "content" => %{"text" => "hello #{n}"}
    }
  end

  defp submitted_count(expected \\ nil, timeout \\ 1_000, acc \\ 0) do
    receive do
      {:submitted, _, _, _} ->
        if acc + 1 == expected, do: acc + 1, else: submitted_count(expected, timeout, acc + 1)
    after
      if(is_nil(expected), do: 200, else: timeout) -> acc
    end
  end

  # Conversation history is read live: `extra.json` appends messages between polls.
  defp write_fake_sdk(tmp_dir, history) do
    path = Path.join(tmp_dir, "fake_xmtp_sdk.mjs")

    File.write!(path, """
    import fs from "node:fs";

    const extraPath = new URL("./extra.json", import.meta.url);
    const HISTORY = #{history};

    function message(n, text) {
      return { id: `m-${n}`, senderInboxId: "#{@inbox}", content: text, kind: 0, sentAtNs: BigInt(n) };
    }

    function allMessages() {
      const list = [];
      for (let n = 1; n <= HISTORY; n++) list.push(message(n, `history ${n}`));
      try {
        for (const extra of JSON.parse(fs.readFileSync(extraPath, "utf8"))) {
          list.push(message(extra.n, extra.text));
        }
      } catch (_error) {}
      return list;
    }

    const conversation = {
      id: "conv-history",
      consentState: () => 1,
      // Ignores sentAfterNs on purpose: the bridge's own filter must hold.
      messages: async () => allMessages(),
      sendText: async () => ({ id: "sent" }),
    };

    export const Client = {
      async create() {
        return {
          inboxId: "bot-inbox",
          conversations: {
            async syncAll() {},
            async sync() {},
            async list() { return [conversation]; },
            async getConversationById(id) { return id === conversation.id ? conversation : null; },
          },
        };
      },
    };
    """)

    "file://" <> path
  end

  defp stop_transport do
    case Process.whereis(Transport) do
      pid when is_pid(pid) -> GenServer.stop(pid, :normal, 2_000)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
