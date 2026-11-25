defmodule LemonGateway.Voice.WebhookSecurityTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Sms.TwilioSignature
  alias LemonGateway.Voice.{RecordingDownloader, WebhookRouter}

  @gateway_config_key :gateway_test_config
  @auth_token "test-voice-auth-token"
  @account_sid "ACtestaccount"

  setup do
    old_gateway = Application.get_env(:lemon_core, @gateway_config_key)
    old_dir = Application.get_env(:lemon_gateway, :voice_recordings_dir)

    tmp =
      Path.join(System.tmp_dir!(), "voice-sec-#{System.unique_integer([:positive])}")

    recordings = Path.join(tmp, "recordings")
    File.mkdir_p!(recordings)

    Application.put_env(:lemon_core, @gateway_config_key, %{
      voice: %{
        twilio_auth_token: @auth_token,
        twilio_account_sid: @account_sid,
        public_url: "https://voice.example.test"
      }
    })

    Application.put_env(:lemon_gateway, :voice_recordings_dir, recordings)

    on_exit(fn ->
      if old_gateway,
        do: Application.put_env(:lemon_core, @gateway_config_key, old_gateway),
        else: Application.delete_env(:lemon_core, @gateway_config_key)

      restore_env(:voice_recordings_dir, old_dir)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp, recordings: recordings}
  end

  describe "Twilio signature on voice callbacks" do
    test "unsigned recording callback returns 403 and performs no HTTP request" do
      {port, listener} = start_capture_listener()

      conn =
        post("/webhooks/twilio/voice/recording", recording_params(port), nil)

      assert conn.status == 403
      refute_receive {:captured_request, _}, 500
      stop_listener(listener)
    end

    test "badly signed recording callback returns 403 and performs no HTTP request" do
      {port, listener} = start_capture_listener()

      conn =
        post("/webhooks/twilio/voice/recording", recording_params(port), "bm9wZQ==")

      assert conn.status == 403
      refute_receive {:captured_request, _}, 500
      stop_listener(listener)
    end

    test "unsigned incoming-call and status callbacks return 403" do
      params = %{"CallSid" => "CA1", "From" => "+15550000000", "To" => "+15551111111"}

      assert post("/webhooks/twilio/voice", params, nil).status == 403
      assert post("/webhooks/twilio/voice/status", params, nil).status == 403
    end

    test "signed incoming-call callback is accepted" do
      params = %{"CallSid" => "CA1", "From" => "+15550000000", "To" => "+15551111111"}
      url = "https://voice.example.test/webhooks/twilio/voice"
      sig = TwilioSignature.signature(@auth_token, url, params)

      conn = post("/webhooks/twilio/voice", params, sig)
      assert conn.status == 200
      assert conn.resp_body =~ "<Stream url="
    end

    test "unsigned media stream WebSocket upgrade returns 403" do
      conn =
        Plug.Test.conn(:get, "/webhooks/twilio/voice/stream?callSid=CA1")
        |> WebhookRouter.call([])

      assert conn.status == 403
    end

    test "callbacks fail closed when no auth token is configured" do
      Application.put_env(:lemon_core, @gateway_config_key, %{
        voice: %{twilio_auth_token: "", public_url: "https://voice.example.test"}
      })

      params = %{"CallSid" => "CA1"}
      url = "https://voice.example.test/webhooks/twilio/voice/status"
      sig = TwilioSignature.signature("", url, params)

      assert post("/webhooks/twilio/voice/status", params, sig).status == 403
    end

    test "callbacks fail closed when no public_url is configured" do
      Application.put_env(:lemon_core, @gateway_config_key, %{
        voice: %{twilio_auth_token: @auth_token}
      })

      params = %{"CallSid" => "CA1"}
      # Even a signature over the request-derived URL is not accepted.
      url = "https://voice.example.test/webhooks/twilio/voice/status"
      sig = TwilioSignature.signature(@auth_token, url, params)

      assert post("/webhooks/twilio/voice/status", params, sig).status == 403
    end

    test "an http public_url is rejected even for correctly signed requests" do
      Application.put_env(:lemon_core, @gateway_config_key, %{
        voice: %{twilio_auth_token: @auth_token, public_url: "http://voice.example.test"}
      })

      params = %{"CallSid" => "CA1", "From" => "+1", "To" => "+2"}

      for path <- ["/webhooks/twilio/voice", "/webhooks/twilio/voice/status"] do
        sig = TwilioSignature.signature(@auth_token, "http://voice.example.test" <> path, params)
        assert post(path, params, sig).status == 403
      end

      ws = "ws://voice.example.test/webhooks/twilio/voice/stream"
      assert handshake(TwilioSignature.signature(@auth_token, ws, %{})).status == 403
    end

    for url <- [
          "wss://voice.example.test/webhooks/twilio/voice/stream",
          "wss://voice.example.test/webhooks/twilio/voice/stream/",
          "https://voice.example.test/webhooks/twilio/voice/stream",
          "https://voice.example.test/webhooks/twilio/voice/stream/"
        ] do
      test "a WSS handshake signed over #{url} passes" do
        conn = handshake(TwilioSignature.signature(@auth_token, unquote(url), %{}))
        refute conn.status == 403
        assert conn.halted
      end
    end

    test "a WSS handshake signed over another host or with another token is rejected" do
      other_host = "wss://evil.example/webhooks/twilio/voice/stream"
      assert handshake(TwilioSignature.signature(@auth_token, other_host, %{})).status == 403

      own = "wss://voice.example.test/webhooks/twilio/voice/stream"
      assert handshake(TwilioSignature.signature("wrong-token", own, %{})).status == 403
    end

    test "https callback signature ignores a backend port in public_url" do
      Application.put_env(:lemon_core, @gateway_config_key, %{
        voice: %{twilio_auth_token: @auth_token, public_url: "https://voice.example.test:4047"}
      })

      params = %{"CallSid" => "CA1"}
      url = "https://voice.example.test/webhooks/twilio/voice/status"
      sig = TwilioSignature.signature(@auth_token, url, params)

      assert post("/webhooks/twilio/voice/status", params, sig).status == 200
    end
  end

  describe "proxied signature URL reconstruction (SMS)" do
    test "forwarded proto/host without forwarded port never uses the backend port" do
      conn =
        Plug.Test.conn(:post, "http://internal:4047/webhooks/twilio/sms", %{})
        |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
        |> Plug.Conn.put_req_header("x-forwarded-host", "voice.example.com")

      assert TwilioSignature.request_url(conn) == "https://voice.example.com/webhooks/twilio/sms"
    end

    test "explicit forwarded port is kept; direct requests keep their port" do
      proxied =
        Plug.Test.conn(:post, "http://internal:4047/webhooks/twilio/sms", %{})
        |> Plug.Conn.put_req_header("x-forwarded-proto", "https")
        |> Plug.Conn.put_req_header("x-forwarded-host", "voice.example.com")
        |> Plug.Conn.put_req_header("x-forwarded-port", "8443")

      assert TwilioSignature.request_url(proxied) ==
               "https://voice.example.com:8443/webhooks/twilio/sms"

      direct = Plug.Test.conn(:post, "http://internal:4047/webhooks/twilio/sms", %{})
      assert TwilioSignature.request_url(direct) == "http://internal:4047/webhooks/twilio/sms"
    end
  end

  describe "recording download host allowlist" do
    test "non-Twilio RecordingUrl performs no request and sends no Authorization header" do
      {port, listener} = start_capture_listener()

      assert {:error, _} = RecordingDownloader.download(recording_params(port))

      refute_receive {:captured_request, _}, 500
      stop_listener(listener)
    end

    test "plain-http and look-alike Twilio hosts are refused" do
      for url <- [
            "http://api.twilio.com/2010-04-01/Accounts/AC1/Recordings/RE1",
            "https://api.twilio.com.evil.test/2010-04-01/Recordings/RE1",
            "https://evil.test@127.0.0.1/Recordings/RE1",
            "https://user:pw@api.twilio.com/2010-04-01/Recordings/RE1"
          ] do
        assert {:error, {:recording_url_not_allowed, _}} =
                 RecordingDownloader.download(%{
                   "RecordingUrl" => url,
                   "CallSid" => "CA1",
                   "RecordingSid" => "RE1"
                 })
      end
    end
  end

  describe "recording filename" do
    test "CallSid and duration cannot escape the recordings directory", %{recordings: recordings} do
      path =
        RecordingDownloader.recording_path(%{
          "CallSid" => "../../x",
          "From" => "../../../etc/passwd",
          "RecordingDuration" => "/../../y"
        })

      expanded = Path.expand(path)
      assert String.starts_with?(expanded, Path.expand(recordings) <> "/")
      refute String.contains?(Path.basename(path), "/")
      refute String.contains?(path, "..")
    end
  end

  # Helpers

  defp recording_params(port) do
    %{
      "RecordingSid" => "RE123",
      "CallSid" => "CA123",
      "RecordingStatus" => "completed",
      "RecordingDuration" => "3",
      "RecordingUrl" => "http://127.0.0.1:#{port}/steal"
    }
  end

  defp handshake(signature) do
    Plug.Test.conn(:get, "/webhooks/twilio/voice/stream")
    |> Plug.Conn.put_req_header("x-twilio-signature", signature)
    |> then(&%{&1 | req_headers: [{"host", "voice.example.test"} | &1.req_headers]})
    |> Plug.Conn.put_req_header("connection", "upgrade")
    |> Plug.Conn.put_req_header("upgrade", "websocket")
    |> Plug.Conn.put_req_header("sec-websocket-version", "13")
    |> Plug.Conn.put_req_header("sec-websocket-key", "dGhlIHNhbXBsZSBub25jZQ==")
    |> WebhookRouter.call([])
  end

  defp post(path, params, signature) do
    conn =
      Plug.Test.conn(:post, path, params)
      |> Plug.Conn.put_req_header("x-forwarded-host", "voice.example.test")
      |> Plug.Conn.put_req_header("x-forwarded-proto", "https")

    conn =
      if signature,
        do: Plug.Conn.put_req_header(conn, "x-twilio-signature", signature),
        else: conn

    WebhookRouter.call(conn, [])
  end

  defp start_capture_listener do
    test_pid = self()
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)

    pid =
      spawn(fn ->
        accept_loop(socket, test_pid)
      end)

    {port, {pid, socket}}
  end

  defp accept_loop(socket, test_pid) do
    case :gen_tcp.accept(socket) do
      {:ok, client} ->
        data =
          case :gen_tcp.recv(client, 0, 2_000) do
            {:ok, data} -> data
            _ -> ""
          end

        send(test_pid, {:captured_request, data})
        :gen_tcp.send(client, "HTTP/1.1 200 OK\r\ncontent-length: 4\r\n\r\nRIFF")
        :gen_tcp.close(client)
        accept_loop(socket, test_pid)

      _ ->
        :ok
    end
  end

  defp stop_listener({pid, socket}) do
    :gen_tcp.close(socket)
    Process.exit(pid, :kill)
  end

  defp restore_env(key, nil), do: Application.delete_env(:lemon_gateway, key)
  defp restore_env(key, value), do: Application.put_env(:lemon_gateway, key, value)
end
