defmodule LemonChannels.Adapters.Xmtp.BridgeConsentTest do
  @moduledoc """
  Runs the shipped `priv/xmtp_bridge.mjs` under Node against a fake XMTP SDK
  module (loaded through the bridge's `sdk_module` setting) and asserts on the
  consent states the bridge passes to the SDK and on the conversations it
  streams back to Elixir.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Xmtp.Transport
  alias LemonChannels.PortBridge

  @moduletag :node
  @moduletag :tmp_dir

  @consent_allowed 1
  @consent_denied 2

  @bridge %{label: "xmtp", event_tag: :xmtp_bridge_event, script_filename: "xmtp_bridge.mjs"}
  @gateway_config_key :gateway_test_config

  defmodule ConsentRouter do
    use LemonCore.RouterBridge.Router
    use LemonCore.RouterBridge.RunOrchestrator

    def handle_inbound(_msg), do: :ok

    def submit(%LemonCore.RunRequest{} = request) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:submitted, request.prompt, request.meta || %{}})
      end

      {:ok, "run_#{System.unique_integer([:positive])}"}
    end
  end

  test "the bridge never lists or syncs DENIED conversations and never streams their messages",
       %{tmp_dir: tmp_dir} do
    sdk = write_fake_sdk(tmp_dir)
    {:ok, pid} = PortBridge.start_link({@bridge, [config: %{}, notify_pid: self()]})

    try do
      PortBridge.command(pid, %{"op" => "connect", "sdk_module" => sdk})

      assert_receive {:xmtp_bridge_event, %{"type" => "connected", "mode" => "live"}}, 30_000

      PortBridge.command(pid, %{"op" => "poll"})

      assert_receive {:xmtp_bridge_event, %{"type" => "message", "message_id" => "m-allowed"}},
                     10_000

      assert_receive {:xmtp_bridge_event, %{"type" => "message", "message_id" => "m-unknown"}},
                     2_000

      refute_receive {:xmtp_bridge_event, %{"type" => "message", "message_id" => "m-denied"}},
                     300

      calls = drain_sdk_calls([])
      assert calls != []

      for %{"method" => method, "consent_states" => states} <- calls do
        assert is_list(states), "#{method} was called without an explicit consent filter"
        assert @consent_allowed in states, "#{method} omitted ALLOWED: #{inspect(states)}"
        refute @consent_denied in states, "#{method} requested DENIED: #{inspect(states)}"
      end

      assert Enum.any?(calls, &(&1["method"] == "syncAll"))
      assert Enum.any?(calls, &(&1["method"] == "list"))
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  test "end to end through the transport, only allowlisted senders in non-denied conversations submit",
       %{tmp_dir: tmp_dir} do
    sdk = write_fake_sdk(tmp_dir)
    stop_transport()
    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_gateway_env = Application.get_env(:lemon_core, @gateway_config_key)
    :persistent_term.put({ConsentRouter, :pid}, self())
    :ok = LemonCore.RouterBridge.configure(router: ConsentRouter, run_orchestrator: ConsentRouter)

    Application.put_env(:lemon_core, @gateway_config_key, %{enable_xmtp: true, xmtp: %{}})

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({ConsentRouter, :pid})
      restore_env(:lemon_core, :router_bridge, old_router_bridge)
      restore_env(:lemon_core, @gateway_config_key, old_gateway_env)
    end)

    {:ok, _pid} =
      Transport.start_link(
        config: %{
          sdk_module: sdk,
          require_live: true,
          poll_interval_ms: 50,
          connect_timeout_ms: 30_000,
          allowed_inboxes: ["inbox-friend"]
        }
      )

    assert_receive {:submitted, "allowed hello", meta}, 30_000
    assert meta[:xmtp].sender_inbox_id == "inbox-friend"

    refute_receive {:submitted, "denied hello", _}, 500
    refute_receive {:submitted, "stranger hello", _}, 100
  end

  test "the bridge refuses to send into DENIED or unreadable conversations, including after a consent change",
       %{tmp_dir: tmp_dir} do
    sdk = write_fake_sdk(tmp_dir)
    {:ok, pid} = PortBridge.start_link({@bridge, [config: %{}, notify_pid: self()]})

    try do
      PortBridge.command(pid, %{"op" => "connect", "sdk_module" => sdk})
      assert_receive {:xmtp_bridge_event, %{"type" => "connected", "mode" => "live"}}, 30_000

      # Direct SDK lookups (never listed or cached by a poll) are checked too.
      for conversation_id <- ["conv-direct-denied", "conv-direct-unreadable"] do
        send_text(pid, conversation_id)
        assert_refused(conversation_id)
      end

      PortBridge.command(pid, %{"op" => "poll"})

      assert_receive {:xmtp_bridge_event, %{"type" => "message", "message_id" => "m-allowed"}},
                     10_000

      send_text(pid, "conv-allowed")

      assert_receive {:xmtp_bridge_event,
                      %{"type" => "fake_sdk_send", "conversation_id" => "conv-allowed"}},
                     5_000

      assert_receive {:xmtp_bridge_event,
                      %{"type" => "sent", "conversation_id" => "conv-allowed"}},
                     5_000

      # The operator denies the cached conversation before the next delivery.
      File.write!(Path.join(tmp_dir, "consent_overrides.json"), ~s({"conv-allowed": 2}))
      send_text(pid, "conv-allowed")
      assert_refused("conv-allowed")
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp send_text(pid, conversation_id) do
    PortBridge.command(pid, %{
      "op" => "send",
      "conversation_id" => conversation_id,
      "content" => "reply"
    })
  end

  defp assert_refused(conversation_id) do
    assert_receive {:xmtp_bridge_event,
                    %{
                      "type" => "error",
                      "code" => "conversation_not_allowed",
                      "conversation_id" => ^conversation_id
                    }},
                   5_000

    refute_received {:xmtp_bridge_event,
                     %{"type" => "fake_sdk_send", "conversation_id" => ^conversation_id}}

    refute_received {:xmtp_bridge_event,
                     %{"type" => "sent", "conversation_id" => ^conversation_id}}
  end

  defp drain_sdk_calls(acc) do
    receive do
      {:xmtp_bridge_event, %{"type" => "fake_sdk_call"} = call} -> drain_sdk_calls([call | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Conversations come back regardless of the requested filter so the test also
  # proves the bridge filters per conversation instead of trusting the SDK.
  defp write_fake_sdk(tmp_dir) do
    path = Path.join(tmp_dir, "fake_xmtp_sdk.mjs")

    File.write!(path, ~S"""
    import fs from "node:fs";

    const overridesPath = new URL("./consent_overrides.json", import.meta.url);

    function record(method, consentStates) {
      const states = Array.isArray(consentStates) ? consentStates : null;
      process.stdout.write(
        JSON.stringify({ type: "fake_sdk_call", method, consent_states: states }) + "\n",
      );
    }

    // Consent is read live so a test can flip it between bridge commands.
    function consentOf(id, fallback) {
      try {
        const overrides = JSON.parse(fs.readFileSync(overridesPath, "utf8"));
        if (id in overrides) return overrides[id];
      } catch (_error) {}
      return fallback;
    }

    function conversation(id, consent, messageId, inboxId, text) {
      return {
        id,
        consentState: () => {
          if (consent === "throw") throw new Error("consent store unavailable");
          return consentOf(id, consent);
        },
        messages: async () => [{ id: messageId, senderInboxId: inboxId, content: text, kind: 0 }],
        sendText: async (text) => {
          process.stdout.write(
            JSON.stringify({ type: "fake_sdk_send", conversation_id: id, text }) + "\n",
          );
          return { id: `sent-${id}` };
        },
      };
    }

    const conversations = [
      conversation("conv-allowed", 1, "m-allowed", "inbox-friend", "allowed hello"),
      conversation("conv-unknown", 0, "m-unknown", "inbox-stranger", "stranger hello"),
      conversation("conv-denied", 2, "m-denied", "inbox-friend", "denied hello"),
    ];

    // Reachable only through a direct lookup, never through list().
    const directOnly = [
      conversation("conv-direct-denied", 2, "m-direct-denied", "inbox-friend", "x"),
      conversation("conv-direct-unreadable", "throw", "m-direct-unreadable", "inbox-friend", "x"),
    ];

    export const Client = {
      async create() {
        return {
          inboxId: "bot-inbox",
          conversations: {
            async syncAll(consentStates) {
              record("syncAll", consentStates);
            },
            async sync() {},
            async list(options) {
              record("list", options?.consentStates);
              return conversations;
            },
            async getConversationById(id) {
              return [...conversations, ...directOnly].find((c) => c.id === id) || null;
            },
          },
        };
      },
    };
    """)

    "file://" <> path
  end

  defp stop_transport do
    case Process.whereis(Transport) do
      pid when is_pid(pid) -> GenServer.stop(pid, :normal, 1_000)
      _ -> :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)
end
