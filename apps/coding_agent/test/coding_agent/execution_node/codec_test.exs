defmodule CodingAgent.ExecutionNode.CodecTest do
  use ExUnit.Case, async: true

  alias CodingAgent.ExecutionNode.Codec
  alias LemonCore.ResumeToken

  test "encodes requests and decodes protocol frames" do
    encoded = Codec.encode_request("request-1", "health", %{"brief" => true})

    assert Jason.decode!(encoded) == %{
             "type" => "req",
             "id" => "request-1",
             "method" => "health",
             "params" => %{"brief" => true}
           }

    assert {:ok, {:hello, %{"auth" => %{"clientId" => "node-1"}}}} =
             Codec.decode(~s({"type":"hello-ok","auth":{"clientId":"node-1"}}))

    assert {:ok, {:event, "node.invoke.request", %{"invokeId" => "invoke-1"}}} =
             Codec.decode(
               ~s({"type":"event","event":"node.invoke.request","payload":{"invokeId":"invoke-1"}})
             )

    assert {:ok, {:response, "request-1", {:ok, %{"ready" => true}}}} =
             Codec.decode(~s({"type":"res","id":"request-1","ok":true,"payload":{"ready":true}}))

    assert {:ok, {:response, "request-2", {:error, %{"code" => "denied"}}}} =
             Codec.decode(
               ~s({"type":"res","id":"request-2","ok":false,"error":{"code":"denied"}})
             )
  end

  test "normalizes executor values for JSON without leaking structs" do
    value = %{
      resume: ResumeToken.new("lemon", "session-1"),
      status: :completed,
      nested: [%{ok: true}]
    }

    assert Codec.json_safe(value) == %{
             "resume" => %{"engine" => "lemon", "value" => "session-1"},
             "status" => "completed",
             "nested" => [%{"ok" => true}]
           }
  end

  test "rejects malformed and unsupported frames" do
    assert {:error, %Jason.DecodeError{}} = Codec.decode("not-json")
    assert {:error, {:invalid_frame, "mystery"}} = Codec.decode(~s({"type":"mystery"}))
  end
end
