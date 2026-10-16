defmodule LemonChannels.Adapters.WhatsApp.BridgeScriptTest do
  @moduledoc """
  Runs the shipped `whatsapp_bridge.mjs` under Node against a fake Baileys
  package, so the way it reports a failed send is exercised without a WhatsApp
  account or network. A send exception thrown once the message was handed to
  Baileys may follow the relay delivering it, so it is flagged
  `outcome_unknown`; a failure before that point is definite.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.WhatsApp.{Bridge, PortServer}

  @moduletag :tmp_dir
  @moduletag :node
  @boot_timeout 30_000
  @jid "15551234567@s.whatsapp.net"

  # `sendMessage` throws when the text, caption or reaction asks for it, like a
  # socket that closes while the message is in flight.
  @fake_baileys """
  export default function makeWASocket() {
    const handlers = {};
    const sock = {
      user: { id: "15550000000:1@s.whatsapp.net" },
      ev: { on(name, handler) { handlers[name] = handler; } },
      async sendMessage(_jid, content) {
        if (content.text === "relay-fails" || content.caption === "relay-fails" || content.react?.text === "relay-fails") {
          throw new Error("Connection Closed");
        }
        return { key: { id: "FAKE-WA-ID" } };
      },
    };
    setImmediate(() => handlers["connection.update"]({ connection: "open" }));
    return sock;
  }
  export const useMultiFileAuthState = async () => ({ state: { creds: { registered: true }, keys: {} }, saveCreds: async () => {} });
  export const fetchLatestBaileysVersion = async () => ({ version: [2, 3000, 1] });
  export const makeCacheableSignalKeyStore = (keys) => keys;
  export const DisconnectReason = { loggedOut: 401 };
  export const downloadMediaMessage = async () => Buffer.from("");
  """

  setup %{tmp_dir: tmp_dir} do
    script = Path.join(tmp_dir, "whatsapp_bridge.mjs")
    File.cp!(Application.app_dir(:lemon_channels, "priv/whatsapp_bridge.mjs"), script)

    baileys = Path.join([tmp_dir, "node_modules", "@whiskeysockets", "baileys"])
    File.mkdir_p!(baileys)

    File.write!(
      Path.join(baileys, "package.json"),
      ~s({"name":"@whiskeysockets/baileys","version":"0.0.0","type":"module","main":"index.js"})
    )

    File.write!(Path.join(baileys, "index.js"), @fake_baileys)

    {:ok, port_server} =
      PortServer.start_link(config: %{bridge_script: script}, notify_pid: self())

    on_exit(fn -> if Process.alive?(port_server), do: GenServer.stop(port_server) end)

    %{port_server: port_server, credentials_path: Path.join(tmp_dir, "auth")}
  end

  defp connect(ctx) do
    Bridge.connect(ctx.port_server, %{credentials_path: ctx.credentials_path})
    assert_receive {:whatsapp_bridge_event, %{"type" => "connected"}}, @boot_timeout
  end

  test "a send before the bridge is connected is a definite error", ctx do
    Bridge.send_text(ctx.port_server, %{id: "early", jid: @jid, text: "hello"})

    assert_receive {:whatsapp_bridge_event,
                    %{"type" => "command_error", "id" => "early"} = event},
                   @boot_timeout

    assert event["error"] == "not connected"
    refute event["outcome_unknown"]
  end

  test "an exception from the send call is flagged as an unknown outcome", ctx do
    connect(ctx)
    media = Path.join(Path.dirname(ctx.credentials_path), "photo.png")
    File.write!(media, "image-bytes")

    Bridge.send_text(ctx.port_server, %{id: "text", jid: @jid, text: "relay-fails"})

    Bridge.send_media(ctx.port_server, %{
      id: "media",
      jid: @jid,
      file_path: media,
      media_type: "image",
      caption: "relay-fails"
    })

    Bridge.send_reaction(ctx.port_server, %{
      id: "reaction",
      jid: @jid,
      message_id: "wamid-1",
      emoji: "relay-fails"
    })

    for id <- ["text", "media", "reaction"] do
      assert_receive {:whatsapp_bridge_event,
                      %{"type" => "command_error", "id" => ^id, "error" => "Connection Closed"} =
                        event},
                     5_000

      assert event["outcome_unknown"] == true
    end
  end

  test "a failure before the send call is definite and an accepted send succeeds", ctx do
    connect(ctx)
    missing = Path.join(Path.dirname(ctx.credentials_path), "missing.png")

    Bridge.send_media(ctx.port_server, %{
      id: "unreadable",
      jid: @jid,
      file_path: missing,
      media_type: "image"
    })

    assert_receive {:whatsapp_bridge_event,
                    %{"type" => "command_error", "id" => "unreadable"} = event},
                   5_000

    assert event["error"] =~ "ENOENT"
    refute event["outcome_unknown"]

    Bridge.send_text(ctx.port_server, %{id: "ok", jid: @jid, text: "hello"})

    assert_receive {:whatsapp_bridge_event,
                    %{"type" => "command_result", "id" => "ok", "ok" => true}},
                   5_000
  end
end
