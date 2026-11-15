defmodule LemonOmp.RpcTest do
  use ExUnit.Case, async: true

  alias LemonCore.Rpc.JsonLines
  alias LemonOmp.Rpc

  describe "decode/1" do
    test "classifies the ready frame" do
      assert {:ready, %{"protocolVersion" => 1}} =
               Rpc.decode(
                 ~s({"type":"ready","protocolVersion":1,"supportedProtocolVersions":[1,2]})
               )
    end

    test "classifies successful responses with their data" do
      assert {:response, "lemon-3", "prompt", {:ok, %{"agentInvoked" => true}}} =
               Rpc.decode(
                 ~s({"type":"response","id":"lemon-3","command":"prompt","success":true,"data":{"agentInvoked":true}})
               )

      assert {:response, "lemon-4", "steer", {:ok, nil}} =
               Rpc.decode(~s({"type":"response","id":"lemon-4","command":"steer","success":true}))
    end

    test "classifies error responses with message and code" do
      assert {:response, "lemon-5", "abort", {:error, "nothing to abort", "E_IDLE"}} =
               Rpc.decode(
                 ~s({"type":"response","id":"lemon-5","command":"abort","success":false,"error":"nothing to abort","code":"E_IDLE"})
               )
    end

    test "fails closed on partial or odd responses" do
      # Only a literal `true` is success.
      assert {:response, "x", "prompt", {:error, "omp rejected the command", nil}} =
               Rpc.decode(~s({"type":"response","id":"x","command":"prompt","success":"true"}))

      assert {:response, nil, "unknown", {:error, "omp rejected the command", nil}} =
               Rpc.decode(~s({"type":"response","id":7,"command":["x"],"error":{"m":1}}))
    end

    test "passes session events through by type" do
      for type <-
            ~w(agent_start agent_end tool_execution_start prompt_result session_settled whatever_new) do
        frame = Rpc.decode(~s({"type":"#{type}","n":1}))
        assert {:event, ^type, %{"type" => ^type, "n" => 1}} = frame
      end
    end

    test "classifies extension UI requests and rejects malformed ones" do
      assert {:ui_request, "ui-1", "confirm", %{"title" => "Allow?"}} =
               Rpc.decode(
                 ~s({"type":"extension_ui_request","id":"ui-1","method":"confirm","title":"Allow?"})
               )

      assert {:malformed, :invalid_ui_request} =
               Rpc.decode(~s({"type":"extension_ui_request","method":"confirm"}))

      assert {:malformed, :invalid_ui_request} =
               Rpc.decode(~s({"type":"extension_ui_request","id":"ui-2","method":3}))
    end

    test "classifies host requests and rejects ones without an id" do
      assert {:host_request, "h-1", %{"type" => "host_tool_call"}} =
               Rpc.decode(~s({"type":"host_tool_call","id":"h-1","toolName":"x"}))

      assert {:host_request, "h-2", %{"type" => "host_uri_request"}} =
               Rpc.decode(~s({"type":"host_uri_request","id":"h-2","uri":"file:///etc/passwd"}))

      assert {:malformed, :invalid_host_request} = Rpc.decode(~s({"type":"host_tool_call"}))
    end

    test "never raises on malformed lines" do
      assert {:malformed, :invalid_json} = Rpc.decode("not json")
      assert {:malformed, :invalid_json} = Rpc.decode("")
      assert {:malformed, :invalid_json} = Rpc.decode(~s({"type":"ready"))
      assert {:malformed, :invalid_json} = Rpc.decode(<<"{\"type\":\"", 0xFF, 0xFE, "\"}">>)
      assert {:malformed, :not_a_frame} = Rpc.decode("[1,2,3]")
      assert {:malformed, :not_a_frame} = Rpc.decode(~s("ready"))
      assert {:malformed, :not_a_frame} = Rpc.decode(~s({"no":"type"}))
      assert {:malformed, :not_a_frame} = Rpc.decode(~s({"type":5}))
    end
  end

  describe "decline_ui_request/2" do
    test "answers a confirm with false" do
      assert Rpc.decline_ui_request("ui-1", "confirm") ==
               %{"type" => "extension_ui_response", "id" => "ui-1", "confirmed" => false}
    end

    test "cancels every other blocking dialog" do
      for method <- ~w(select input editor) do
        assert Rpc.decline_ui_request("ui-2", method) ==
                 %{"type" => "extension_ui_response", "id" => "ui-2", "cancelled" => true}
      end
    end

    test "owes nothing for fire-and-forget methods" do
      for method <- ~w(notify setStatus setWidget setTitle unknownMethod) do
        assert Rpc.decline_ui_request("ui-3", method) == nil
      end
    end
  end

  describe "reject_host_request/2" do
    test "rejects host URI requests" do
      assert Rpc.reject_host_request("h-1", %{"type" => "host_uri_request"}) == %{
               "type" => "host_uri_result",
               "id" => "h-1",
               "isError" => true,
               "error" => "not supported by host"
             }
    end

    test "rejects host tool calls with an error result" do
      assert %{
               "type" => "host_tool_result",
               "id" => "h-2",
               "isError" => true,
               "result" => %{
                 "content" => [%{"type" => "text", "text" => "not supported by host"}]
               }
             } = Rpc.reject_host_request("h-2", %{"type" => "host_tool_call"})
    end
  end

  describe "command/3 and shared JSONL framing" do
    test "builds a command with string keys and the correlation id" do
      assert Rpc.command("prompt", "lemon-1", %{message: "hi"}) ==
               %{"type" => "prompt", "id" => "lemon-1", "message" => "hi"}

      # Caller fields cannot override the command type or id.
      assert Rpc.command("abort", "lemon-2", %{"type" => "prompt", "id" => "x"}) ==
               %{"type" => "abort", "id" => "lemon-2"}

      assert Rpc.command("get_state", "lemon-3") == %{"type" => "get_state", "id" => "lemon-3"}
    end

    test "encodes exactly one JSON line, escaping embedded newlines" do
      assert {:ok, line} =
               "prompt"
               |> Rpc.command("lemon-1", %{"message" => "line one\nline two \u202E"})
               |> JsonLines.encode()

      assert String.ends_with?(line, "\n")
      assert [json, ""] = String.split(line, "\n")
      assert Jason.decode!(json)["message"] == "line one\nline two \u202E"
    end

    test "round-trips through decode for a reply the host writes" do
      assert {:ok, line} = "ui-1" |> Rpc.decline_ui_request("confirm") |> JsonLines.encode()

      assert {:event, "extension_ui_response", %{"confirmed" => false}} =
               Rpc.decode(String.trim_trailing(line))
    end
  end
end
