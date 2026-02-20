defmodule LemonGateway.Transports.XmtpTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Transports.Xmtp
  alias LemonGateway.Transports.Xmtp.PortServer

  test "uses stable inbox-derived fallback wallet for session key when sender wallet is missing" do
    event = %{
      "conversation_id" => "conv-fallback-1",
      "sender_inbox_id" => "Inbox-ABC-123",
      "content" => %{"text" => "hello"}
    }

    first = Xmtp.normalize_inbound_for_test(event)
    second = Xmtp.normalize_inbound_for_test(Map.put(event, "message_id", "msg-2"))

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

    normalized = Xmtp.normalize_inbound_for_test(event)

    assert normalized.content_type == "unsupported:image"
    assert normalized.prompt_is_placeholder == true
    assert normalized.prompt =~ "Non-text XMTP message (image)"
    assert normalized.prompt =~ "Please send text."
    assert normalized.raw_content_type == "image"
    assert normalized.raw_content == event["content"]
  end

  test "uses message/content fingerprint fallback when conversation and sender IDs are missing" do
    first_event = %{
      "message_id" => "msg-unknown-1",
      "content" => %{"text" => "first"}
    }

    second_event = %{
      "message_id" => "msg-unknown-2",
      "content" => %{"text" => "second"}
    }

    first = Xmtp.normalize_inbound_for_test(first_event)
    first_repeat = Xmtp.normalize_inbound_for_test(first_event)
    second = Xmtp.normalize_inbound_for_test(second_event)

    assert first.sender_identity_source == "message_content_fingerprint"
    assert first.wallet_address == first_repeat.wallet_address
    assert first.session_key == first_repeat.session_key
    refute first.wallet_address == second.wallet_address
    refute first.session_key == second.session_key
  end

  test "placeholder helper marks non-text input as non-runtime and sanitizes reply text" do
    noisy_url = "https://example.test/uploaded\n" <> String.duplicate("x", 160)

    event = %{
      "conversation_id" => "conv-placeholder-sanitize",
      "sender_inbox_id" => "inbox-placeholder-sanitize",
      "content_type" => "image",
      "content" => %{"url" => noisy_url}
    }

    assert Xmtp.inbound_action_for_test(event) == :placeholder_reply

    reply = Xmtp.placeholder_response_text_for_test(event)

    assert reply =~ "Please send your request as plain text."
    assert reply =~ "(received image:"
    refute String.contains?(reply, "\n")
    assert String.length(reply) <= 220
    assert String.contains?(reply, "...")
  end

  test "replays connect command after bridge port restart" do
    if System.find_executable("node") == nil do
      assert true
    else
      tmp_dir =
        Path.join(System.tmp_dir!(), "xmtp_port_server_#{System.unique_integer([:positive])}")

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

      assert_receive {:xmtp_bridge_event, %{"type" => "bridge_test_connect", "generation" => 1}},
                     2_000

      assert_receive {:xmtp_bridge_event,
                      %{"type" => "error", "message" => "xmtp bridge exited"}},
                     4_000

      assert_receive {:xmtp_bridge_event, %{"type" => "bridge_test_connect", "generation" => 2}},
                     8_000
    end
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

    const rl = readline.createInterface({
      input: process.stdin,
      crlfDelay: Infinity,
      terminal: false,
    });

    rl.on("line", (line) => {
      let command = null;

      try {
        command = JSON.parse(line);
      } catch (_error) {
        return;
      }

      if (command?.op === "connect") {
        process.stdout.write(JSON.stringify({ type: "bridge_test_connect", generation }) + "\\n");

        if (generation === 1) {
          setTimeout(() => process.exit(88), 10);
        }
      }
    });
    """
  end
end
