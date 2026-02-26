defmodule LemonControlPlane.Protocol.FramesTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.Protocol.Frames

  describe "parse/1" do
    test "parses valid request with params" do
      json = ~s({"type":"req","id":"req-1","method":"chat.send","params":{"prompt":"hello"}})

      assert {:ok,
              %{
                type: :req,
                id: "req-1",
                method: "chat.send",
                params: %{"prompt" => "hello"}
              }} = Frames.parse(json)
    end

    test "parses valid request without params as nil" do
      json = ~s({"type":"req","id":"req-2","method":"sessions.list"})

      assert {:ok, %{type: :req, id: "req-2", method: "sessions.list", params: nil}} =
               Frames.parse(json)
    end

    test "returns structured error for invalid json" do
      assert {:error, {:json_decode_error, message}} = Frames.parse("{invalid-json")
      assert is_binary(message)
      assert message != ""
    end

    test "rejects non-request frame types" do
      json = ~s({"type":"event","event":"tick"})

      assert {:error, {:invalid_frame, "expected request frame, got: event"}} = Frames.parse(json)
    end

    test "rejects request frames missing id" do
      json = ~s({"type":"req","method":"chat.send"})

      assert {:error, {:invalid_frame, "request frame must have id and method"}} =
               Frames.parse(json)
    end

    test "rejects request frames missing method" do
      json = ~s({"type":"req","id":"req-3"})

      assert {:error, {:invalid_frame, "request frame must have id and method"}} =
               Frames.parse(json)
    end
  end

  describe "encode_response/2" do
    test "encodes successful response" do
      json = Frames.encode_response("req-10", {:ok, %{"sessionKey" => "sess-1"}})
      decoded = Jason.decode!(json)

      assert decoded["type"] == "res"
      assert decoded["id"] == "req-10"
      assert decoded["ok"] == true
      assert decoded["payload"] == %{"sessionKey" => "sess-1"}
      refute Map.has_key?(decoded, "error")
    end

    test "encodes error response" do
      error = {:invalid_params, "Missing required fields", %{"missing" => ["sessionKey"]}}
      json = Frames.encode_response("req-11", {:error, error})
      decoded = Jason.decode!(json)

      assert decoded["type"] == "res"
      assert decoded["id"] == "req-11"
      assert decoded["ok"] == false
      assert decoded["error"]["code"] == "INVALID_PARAMS"
      assert decoded["error"]["message"] == "Missing required fields"
      assert decoded["error"]["details"] == %{"missing" => ["sessionKey"]}
      refute Map.has_key?(decoded, "payload")
    end
  end

  describe "encode_hello_ok/1" do
    test "encodes provided hello-ok options including auth" do
      opts = [
        protocol: 7,
        version: "1.2.3",
        commit: "abc1234",
        host: "test-host",
        conn_id: "conn-1",
        methods: ["connect", "chat.send"],
        events: ["chat", "tick"],
        snapshot: %{"presence" => %{"status" => "online"}},
        max_payload: 4096,
        max_buffered_bytes: 8192,
        tick_interval_ms: 250,
        auth: %{"required" => true, "scopes" => ["chat:write"]}
      ]

      json = Frames.encode_hello_ok(opts)
      decoded = Jason.decode!(json)

      assert decoded["type"] == "hello-ok"
      assert decoded["protocol"] == 7
      assert decoded["server"]["version"] == "1.2.3"
      assert decoded["server"]["commit"] == "abc1234"
      assert decoded["server"]["host"] == "test-host"
      assert decoded["server"]["connId"] == "conn-1"
      assert decoded["features"]["methods"] == ["connect", "chat.send"]
      assert decoded["features"]["events"] == ["chat", "tick"]
      assert decoded["snapshot"] == %{"presence" => %{"status" => "online"}}
      assert decoded["policy"]["maxPayload"] == 4096
      assert decoded["policy"]["maxBufferedBytes"] == 8192
      assert decoded["policy"]["tickIntervalMs"] == 250
      assert decoded["auth"] == %{"required" => true, "scopes" => ["chat:write"]}
    end
  end
end
