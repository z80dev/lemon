defmodule LemonChannels.Adapters.Xmtp.TransportTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Xmtp.PortServer
  alias LemonChannels.Adapters.Xmtp.Transport
  alias LemonChannels.OutboundPayload
  alias LemonCore.InboundMessage

  defmodule LemonChannels.Adapters.Xmtp.TransportTest.TestRouter do
    def handle_inbound(msg) do
      if pid = :persistent_term.get({__MODULE__, :pid}, nil) do
        send(pid, {:inbound, msg})
      end

      :ok
    end
  end

  setup do
    stop_transport()

    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_gateway_env = Application.get_env(:lemon_channels, :gateway)
    old_xmtp_env = Application.get_env(:lemon_channels, :xmtp)

    :persistent_term.put({LemonChannels.Adapters.Xmtp.TransportTest.TestRouter, :pid}, self())
    LemonCore.RouterBridge.configure(router: LemonChannels.Adapters.Xmtp.TransportTest.TestRouter)

    Application.put_env(:lemon_channels, :gateway, %{
      enable_xmtp: true,
      default_engine: "echo",
      xmtp: %{
        require_live: false,
        poll_interval_ms: 30_000,
        connect_timeout_ms: 5_000
      }
    })

    Application.put_env(:lemon_channels, :xmtp, %{})

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({LemonChannels.Adapters.Xmtp.TransportTest.TestRouter, :pid})
      restore_env(:lemon_core, :router_bridge, old_router_bridge)
      restore_env(:lemon_channels, :gateway, old_gateway_env)
      restore_env(:lemon_channels, :xmtp, old_xmtp_env)
    end)

    :ok
  end

  test "routes inbound bridge message end-to-end through RouterBridge" do
    missing_script =
      Path.join(
        System.tmp_dir!(),
        "xmtp_missing_bridge_#{System.unique_integer([:positive])}.mjs"
      )

    {:ok, pid} =
      Transport.start_link(
        config: %{bridge_script: missing_script, require_live: false, connect_timeout_ms: 5_000}
      )

    send(pid, {:xmtp_bridge_event, %{"type" => "connected", "mode" => "live"}})

    sender = "0x1111111111111111111111111111111111111111"

    send(pid, {
      :xmtp_bridge_event,
      %{
        "type" => "message",
        "conversation_id" => "conv-e2e-1",
        "sender_inbox_id" => "inbox-e2e-1",
        "sender_address" => sender,
        "message_id" => "msg-e2e-1",
        "content" => %{"text" => "/codex do the thing"}
      }
    })

    assert_receive {:inbound, %InboundMessage{} = inbound}, 800

    assert inbound.channel_id == "xmtp"
    assert inbound.peer.id == sender
    assert inbound.peer.thread_id == "conv-e2e-1"
    assert inbound.message.text == "do the thing"
    assert fetch(inbound.meta, :engine_id) == "codex"
    assert LemonCore.SessionKey.valid?(fetch(inbound.meta, :session_key))
  end

  test "deliver returns error when outbound payload is missing conversation id" do
    payload =
      %OutboundPayload{
        channel_id: "xmtp",
        account_id: "default",
        peer: %{kind: :dm, id: "0x1111111111111111111111111111111111111111", thread_id: nil},
        kind: :text,
        content: "hello"
      }

    missing_script =
      Path.join(
        System.tmp_dir!(),
        "xmtp_missing_bridge_#{System.unique_integer([:positive])}.mjs"
      )

    {:ok, pid} =
      Transport.start_link(
        config: %{bridge_script: missing_script, require_live: false, connect_timeout_ms: 5_000}
      )

    send(pid, {:xmtp_bridge_event, %{"type" => "connected", "mode" => "live"}})

    assert {:error, :missing_conversation_id} = Transport.deliver(payload)
  end

  test "deliver maps outbox payload to XMTP bridge send payload" do
    payload =
      %OutboundPayload{
        channel_id: "xmtp",
        account_id: "default",
        peer: %{
          kind: :dm,
          id: "0x1111111111111111111111111111111111111111",
          thread_id: "conv-outbound-1"
        },
        kind: :text,
        content: "hello from outbox",
        meta: %{run_id: "run-123"}
      }

    missing_script =
      Path.join(
        System.tmp_dir!(),
        "xmtp_missing_bridge_#{System.unique_integer([:positive])}.mjs"
      )

    {:ok, pid} =
      Transport.start_link(
        config: %{bridge_script: missing_script, require_live: false, connect_timeout_ms: 5_000}
      )

    send(pid, {:xmtp_bridge_event, %{"type" => "connected", "mode" => "live"}})

    assert {:ok, outbound} = Transport.deliver(payload)
    assert outbound["conversation_id"] == "conv-outbound-1"
    assert outbound["wallet_address"] == "0x1111111111111111111111111111111111111111"
    assert outbound["content"] == "hello from outbox"
    assert outbound["request_id"] == "run-123"
  end

  test "uses stable inbox-derived fallback wallet for session key when sender wallet is missing" do
    event = %{
      "conversation_id" => "conv-fallback-1",
      "sender_inbox_id" => "Inbox-ABC-123",
      "content" => %{"text" => "hello"}
    }

    first = Transport.normalize_inbound_for_test(event)
    second = Transport.normalize_inbound_for_test(Map.put(event, "message_id", "msg-2"))

    assert first.wallet_address == second.wallet_address
    assert first.wallet_address =~ ~r/^0x[0-9a-f]{40}$/
    refute first.wallet_address == "0xunknown"
    assert first.sender_inbox_id == "inbox-abc-123"
    assert first.sender_identity_source == "sender_inbox_id"
    assert first.session_key == "xmtp:#{first.wallet_address}:conv-fallback-1"
  end

  test "builds placeholder prompt and preserves metadata for non-text content" do
    event = %{
      "conversation_id" => "conv-non-text-1",
      "sender_inbox_id" => "inbox-non-text-1",
      "content_type" => "image",
      "content" => %{
        "url" => "ipfs://example-asset",
        "mime_type" => "image/png"
      }
    }

    normalized = Transport.normalize_inbound_for_test(event)

    assert normalized.content_type == "unsupported:image"
    assert normalized.prompt_is_placeholder == true
    assert normalized.prompt =~ "Non-text XMTP message (image)"
    assert normalized.prompt =~ "Please send text."
    assert normalized.raw_content_type == "image"
    assert normalized.raw_content == event["content"]
  end

  test "placeholder helper marks non-text input as non-runtime and sanitizes reply text" do
    noisy_url = "https://example.test/uploaded\n" <> String.duplicate("x", 160)

    event = %{
      "conversation_id" => "conv-placeholder-sanitize",
      "sender_inbox_id" => "inbox-placeholder-sanitize",
      "content_type" => "image",
      "content" => %{"url" => noisy_url}
    }

    assert Transport.inbound_action_for_test(event) == :placeholder_reply

    reply = Transport.placeholder_response_text_for_test(event)

    assert reply =~ "Please send your request as plain text."
    assert reply =~ "(received image:"
    refute String.contains?(reply, "\n")
    assert String.length(reply) <= 220
    assert String.contains?(reply, "...")
  end

  test "normalizes reply content prompt with reference when present" do
    event = %{
      "conversation_id" => "conv-reply-1",
      "sender_inbox_id" => "inbox-reply-1",
      "message_id" => "msg-reply-1",
      "content_type" => "reply",
      "content" => %{
        "text" => "acknowledged",
        "reply_to_message_id" => "msg-reference-1"
      }
    }

    normalized = Transport.normalize_inbound_for_test(event)

    assert normalized.content_type == "reply"
    assert normalized.prompt == "Reply to msg-reference-1: acknowledged"
    assert normalized.prompt_is_placeholder == false
  end

  test "normalizes reaction content prompt" do
    event = %{
      "conversation_id" => "conv-reaction-1",
      "sender_inbox_id" => "inbox-reaction-1",
      "message_id" => "msg-reaction-1",
      "content_type" => "reaction",
      "content" => %{
        "emoji" => "🔥",
        "reference" => "msg-target-1"
      }
    }

    normalized = Transport.normalize_inbound_for_test(event)

    assert normalized.content_type == "reaction"
    assert normalized.prompt == "Reaction 🔥 to message msg-target-1"
    assert normalized.prompt_is_placeholder == false
  end

  test "dedupe key remains stable for same message_id in same conversation" do
    base_event = %{
      "conversation_id" => "conv-dedupe-msg-1",
      "sender_inbox_id" => "inbox-dedupe-msg-1",
      "message_id" => "msg-dedupe-1",
      "content" => %{"text" => "first payload"}
    }

    variant_event = Map.put(base_event, "content", %{"text" => "second payload"})

    assert Transport.inbound_dedupe_key_for_test(base_event) ==
             Transport.inbound_dedupe_key_for_test(variant_event)
  end

  test "fallback dedupe key stays stable for identical payload when message_id is missing" do
    event = %{
      "conversation_id" => "conv-dedupe-fallback-1",
      "sender_inbox_id" => "inbox-dedupe-fallback-1",
      "sent_at_ns" => "1700000000000000000",
      "content_type" => "text",
      "content" => %{"text" => "same payload"}
    }

    first = Transport.inbound_dedupe_key_for_test(event)
    second = Transport.inbound_dedupe_key_for_test(event)

    assert first == second
    assert String.starts_with?(first, "conversation:conv-dedupe-fallback-1:fallback:")
  end

  test "replays connect command after bridge port restart" do
    if System.find_executable("node") == nil do
      assert true
    else
      tmp_dir =
        Path.join(System.tmp_dir!(), "xmtp_port_server_#{System.unique_integer([:positive])}")

      File.rm_rf!(tmp_dir)
      :ok = File.mkdir_p(tmp_dir)

      counter_path = Path.join(tmp_dir, "bridge_start_count.txt")
      script_path = Path.join(tmp_dir, "bridge_restart_fixture.mjs")
      :ok = File.write(script_path, restart_fixture_script(counter_path))

      {:ok, port_server} =
        PortServer.start_link(config: %{bridge_script: script_path}, notify_pid: self())

      on_exit(fn -> if Process.alive?(port_server), do: GenServer.stop(port_server) end)

      PortServer.command(port_server, %{
        "op" => "connect",
        "wallet_address" => "0x1111111111111111111111111111111111111111"
      })

      assert_receive {:xmtp_bridge_event,
                      %{"type" => "bridge_test_connect", "generation" => first_generation}},
                     2_000

      assert_receive {:xmtp_bridge_event,
                      %{"type" => "error", "message" => "xmtp bridge exited"}},
                     4_000

      assert_receive {:xmtp_bridge_event,
                      %{"type" => "bridge_test_connect", "generation" => second_generation}},
                     8_000

      assert second_generation == first_generation + 1
    end
  end

  defp stop_transport do
    case Process.whereis(Transport) do
      pid when is_pid(pid) ->
        GenServer.stop(pid, :normal, 1_000)

      _ ->
        :ok
    end
  catch
    :exit, _ -> :ok
  end

  defp restore_env(app, key, nil), do: Application.delete_env(app, key)
  defp restore_env(app, key, value), do: Application.put_env(app, key, value)

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp restart_fixture_script(counter_path) do
    """
    #!/usr/bin/env node
    import fs from "node:fs";
    import readline from "node:readline";

    const counterPath = #{inspect(counter_path)};
    let generation = 1;

    try {
      const prev = Number.parseInt(fs.readFileSync(counterPath, "utf8"), 10);
      if (!Number.isNaN(prev)) generation = prev + 1;
    } catch (_error) {}

    fs.writeFileSync(counterPath, String(generation));

    const emit = (payload) => process.stdout.write(JSON.stringify(payload) + "\\n");

    const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

    rl.on("line", (line) => {
      let cmd;

      try {
        cmd = JSON.parse(line);
      } catch (_error) {
        return;
      }

      if (cmd?.op === "connect") {
        emit({ type: "bridge_test_connect", generation });
        process.exit(0);
      }
    });
    """
  end
end
