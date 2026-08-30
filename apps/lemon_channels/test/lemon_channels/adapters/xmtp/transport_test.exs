defmodule LemonChannels.Adapters.Xmtp.TransportTest do
  alias Elixir.LemonChannels, as: LemonChannels
  use ExUnit.Case, async: false

  alias Elixir.LemonChannels.Adapters.Xmtp.Transport
  alias Elixir.LemonChannels.OutboundPayload
  alias LemonCore.InboundMessage

  defmodule XmtpTestRouter do
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
          id: meta[:xmtp] && meta[:xmtp].message_id,
          text: request.prompt,
          timestamp: nil,
          reply_to_id: nil
        },
        raw: meta[:raw],
        meta: meta
      }
    end
  end

  @gateway_config_key :"Elixir.LemonGateway.Config"

  setup do
    stop_transport()

    old_router_bridge = Application.get_env(:lemon_core, :router_bridge)
    old_gateway_env = Application.get_env(:lemon_gateway, @gateway_config_key)

    :persistent_term.put({XmtpTestRouter, :pid}, self())
    LemonCore.RouterBridge.configure(router: XmtpTestRouter, run_orchestrator: XmtpTestRouter)

    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      enable_xmtp: true,
      xmtp: %{
        require_live: false,
        poll_interval_ms: 30_000,
        connect_timeout_ms: 5_000
      }
    })

    on_exit(fn ->
      stop_transport()
      :persistent_term.erase({XmtpTestRouter, :pid})
      restore_env(:lemon_core, :router_bridge, old_router_bridge)
      restore_env(:lemon_gateway, @gateway_config_key, old_gateway_env)
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
    assert inbound.message.text == "/codex do the thing"
    refute Map.has_key?(inbound.meta, :engine_id)
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

  test "config resolves wallet_key_secret into wallet_key" do
    secret_env = "XMTP_TEST_WALLET_KEY_#{System.unique_integer([:positive])}"
    System.put_env(secret_env, "0xsecret-wallet-key")

    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      enable_xmtp: true,
      xmtp: %{wallet_key_secret: secret_env}
    })

    on_exit(fn -> System.delete_env(secret_env) end)

    assert Transport.config()[:wallet_key] == "0xsecret-wallet-key"
  end

  test "config resolves ${ENV_VAR} interpolation for xmtp values" do
    System.put_env("XMTP_TEST_WALLET_ADDRESS", "0x1111111111111111111111111111111111111111")

    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      enable_xmtp: true,
      xmtp: %{wallet_address: "${XMTP_TEST_WALLET_ADDRESS}"}
    })

    on_exit(fn -> System.delete_env("XMTP_TEST_WALLET_ADDRESS") end)

    assert Transport.config()[:wallet_address] == "0x1111111111111111111111111111111111111111"
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
end
