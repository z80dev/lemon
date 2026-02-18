defmodule CodingAgent.WasmToolTest do
  use ExUnit.Case, async: false

  alias AgentCore.Types.{AgentTool, AgentToolResult}
  alias CodingAgent.ToolRegistry
  alias CodingAgent.Wasm.Config, as: WasmConfig
  alias CodingAgent.Wasm.SidecarSession
  alias CodingAgent.Wasm.ToolFactory

  alias Ai.Types.TextContent

  @moduletag :tmp_dir

  defp write_fake_sidecar(tmp_dir) do
    path = Path.join(tmp_dir, "fake-wasm-tools.py")

    File.write!(path, """
    #!/usr/bin/env python3
    import json
    import sys

    def send(obj):
      sys.stdout.write(json.dumps(obj) + "\\n")
      sys.stdout.flush()

    for line in sys.stdin:
      line = line.strip()
      if not line:
        continue

      req = json.loads(line)
      req_type = req.get("type")
      req_id = req.get("id")

      if req_type == "hello":
        send({"type": "response", "id": req_id, "ok": True, "result": {"version": 1}, "error": None})
      elif req_type == "discover":
        tools = [
          {
            "name": "echo_wasm",
            "path": "/tmp/echo_wasm.wasm",
            "description": "Echo fake wasm",
            "schema_json": json.dumps({"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}),
            "capabilities": {"workspace_read": False, "http": False, "tool_invoke": False, "secrets": False},
            "warnings": []
          },
          {
            "name": "error_wasm",
            "path": "/tmp/error_wasm.wasm",
            "description": "Always errors",
            "schema_json": json.dumps({"type": "object", "properties": {}, "required": []}),
            "capabilities": {"workspace_read": False, "http": False, "tool_invoke": False, "secrets": False},
            "warnings": []
          }
        ]

        send({"type": "response", "id": req_id, "ok": True, "result": {"tools": tools, "warnings": [], "errors": []}, "error": None})
      elif req_type == "invoke":
        tool = req.get("tool")

        if tool == "error_wasm":
          result = {"output_json": None, "error": "boom", "logs": [], "details": {"runtime": "fake"}}
        else:
          params = json.loads(req.get("params_json") or "{}")
          result = {"output_json": json.dumps({"echo": params.get("text", "")}), "error": None, "logs": [], "details": {"runtime": "fake"}}

        send({"type": "response", "id": req_id, "ok": True, "result": result, "error": None})
      elif req_type == "host_call_result":
        send({"type": "response", "id": req_id, "ok": True, "result": {"accepted": True}, "error": None})
      elif req_type == "shutdown":
        send({"type": "response", "id": req_id, "ok": True, "result": {"stopped": True}, "error": None})
        break
      else:
        send({"type": "response", "id": req_id, "ok": False, "result": None, "error": "unsupported"})
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp start_sidecar(tmp_dir, runtime_path) do
    wasm_config = %WasmConfig{
      enabled: true,
      auto_build: false,
      runtime_path: runtime_path,
      tool_paths: [],
      discover_paths: [tmp_dir],
      default_memory_limit: 10_485_760,
      default_timeout_ms: 60_000,
      default_fuel_limit: 10_000_000,
      cache_compiled: true,
      cache_dir: nil,
      max_tool_invoke_depth: 4
    }

    {:ok, sidecar} =
      SidecarSession.start_link(
        cwd: tmp_dir,
        session_id: "wasm-tool-test",
        wasm_config: wasm_config,
        host_invoke_fun: fn _tool, _params -> {:error, :not_used} end
      )

    sidecar
  end

  test "wasm tool success result is untrusted", %{tmp_dir: tmp_dir} do
    runtime_path = write_fake_sidecar(tmp_dir)
    sidecar = start_sidecar(tmp_dir, runtime_path)

    assert {:ok, discover} = SidecarSession.discover(sidecar)

    inventory =
      ToolFactory.build_inventory(sidecar, discover.tools, cwd: tmp_dir, session_id: "s1")

    {"echo_wasm", tool, _source} =
      Enum.find(inventory, fn {name, _, _} -> name == "echo_wasm" end)

    result = tool.execute.("call-1", %{"text" => "hello"}, nil, nil)

    assert %AgentToolResult{} = result
    assert result.trust == :untrusted
    assert [%TextContent{text: text}] = result.content
    assert text =~ "echo"
  end

  test "wasm tool error payload is converted to text", %{tmp_dir: tmp_dir} do
    runtime_path = write_fake_sidecar(tmp_dir)
    sidecar = start_sidecar(tmp_dir, runtime_path)

    assert {:ok, discover} = SidecarSession.discover(sidecar)

    inventory =
      ToolFactory.build_inventory(sidecar, discover.tools, cwd: tmp_dir, session_id: "s1")

    {"error_wasm", tool, _source} =
      Enum.find(inventory, fn {name, _, _} -> name == "error_wasm" end)

    result = tool.execute.("call-2", %{}, nil, nil)

    assert %AgentToolResult{} = result
    assert result.trust == :untrusted
    assert [%TextContent{text: text}] = result.content
    assert text =~ "returned an error"
  end

  test "http-capable wasm tools require approval by default", %{tmp_dir: tmp_dir} do
    wasm_tool = %AgentTool{
      name: "http_wasm",
      description: "HTTP wasm",
      parameters: %{},
      label: "HTTP WASM",
      execute: fn _, _, _, _ -> %AgentToolResult{content: [%TextContent{text: "ok"}]} end
    }

    wasm_inventory = [
      {"http_wasm", wasm_tool,
       {:wasm, %{name: "http_wasm", path: "/tmp/http_wasm.wasm", capabilities: %{http: true}}}}
    ]

    approval_context = %{
      session_key: "wasm-policy-test",
      approval_request_fun: fn _request -> {:ok, :denied} end
    }

    tools =
      ToolRegistry.get_tools(tmp_dir,
        include_extensions: false,
        wasm_tools: wasm_inventory,
        tool_policy: %{allow: :all, deny: [], require_approval: [], approvals: %{}},
        approval_context: approval_context
      )

    tool = Enum.find(tools, &(&1.name == "http_wasm"))
    result = tool.execute.("call-3", %{}, nil, nil)

    assert %AgentToolResult{} = result
    assert [%TextContent{text: text}] = result.content
    assert text =~ "denied"
  end
end
