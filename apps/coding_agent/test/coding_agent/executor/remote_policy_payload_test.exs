defmodule CodingAgent.Executor.RemotePolicyPayloadTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Executor.RemoteRequestCodec
  alias LemonGateway.ExecutionRequest

  test "full native policy arrays cross JSON without truncation" do
    names = Enum.map(1..16_384, &"mcp_tool_#{&1}")

    assert {:ok, context} =
             LemonCore.ExecutionContext.new(
               run_id: "dense-policy",
               tool_policy: %{"require_approval" => names}
             )

    request = %ExecutionRequest{
      run_id: "dense-policy",
      session_key: "agent:dense:main",
      prompt: "Use only admitted tools",
      execution_context: context,
      tool_policy: %{"require_approval" => names}
    }

    assert {:ok, %{"toolPolicy" => %{"require_approval" => ^names}}} =
             RemoteRequestCodec.encode(request)

    assert {:error, {:invalid_request_payload, _}} =
             RemoteRequestCodec.encode(request, max_items: 10_000)

    assert {:error, {:invalid_request_payload, _}} =
             RemoteRequestCodec.encode(request, max_bytes: 128)

    assert {:error, {:invalid_request_payload, _}} =
             RemoteRequestCodec.encode(%{request | meta: %{callback: fn -> :private end}})
  end

  test "execution budget helpers preserve explicit caller limits" do
    opts = LemonCore.ToolPolicy.execution_json_opts(max_items: 25, max_bytes: 128)
    assert opts[:max_items] == 25
    assert opts[:max_bytes] == 128
    assert LemonCore.ToolPolicy.execution_json_opts()[:max_items] == 131_072
    assert LemonCore.ToolPolicy.execution_json_opts()[:max_bytes] == 16_777_216
  end
end
