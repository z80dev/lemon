defmodule CodingAgent.WasmIntegrationTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Wasm.Builder
  alias CodingAgent.Wasm.Config, as: WasmConfig
  alias CodingAgent.Wasm.SidecarSession

  @moduletag :integration
  @moduletag :tmp_dir

  defp write_sidecar_with_host_call(tmp_dir) do
    path = Path.join(tmp_dir, "fake-wasm-integration.py")

    File.write!(path, """
    #!/usr/bin/env python3
    import json
    import sys

    def send(obj):
      sys.stdout.write(json.dumps(obj) + "\\n")
      sys.stdout.flush()

    pending = {}

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
            "description": "echo",
            "schema_json": json.dumps({"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}),
            "capabilities": {"workspace_read": False, "http": False, "tool_invoke": False, "secrets": False},
            "warnings": []
          },
          {
            "name": "call_host",
            "path": "/tmp/call_host.wasm",
            "description": "calls host",
            "schema_json": json.dumps({"type": "object", "properties": {}, "required": []}),
            "capabilities": {"workspace_read": False, "http": False, "tool_invoke": True, "secrets": False},
            "warnings": []
          }
        ]
        send({"type": "response", "id": req_id, "ok": True, "result": {"tools": tools, "warnings": [], "errors": []}, "error": None})
      elif req_type == "invoke":
        tool = req.get("tool")

        if tool == "echo_wasm":
          params = json.loads(req.get("params_json") or "{}")
          result = {"output_json": json.dumps({"echo": params.get("text", "")}), "error": None, "logs": [], "details": {}}
          send({"type": "response", "id": req_id, "ok": True, "result": result, "error": None})
        elif tool == "call_host":
          call_id = "host-call-1"
          pending[call_id] = req_id
          send({"type": "event", "event": "host_call", "request_id": req_id, "call_id": call_id, "tool": "host_echo", "params_json": json.dumps({"message": "hi"})})
        else:
          send({"type": "response", "id": req_id, "ok": False, "result": None, "error": "unknown tool"})
      elif req_type == "host_call_result":
        call_id = req.get("call_id")
        invoke_id = pending.pop(call_id, None)

        if invoke_id is None:
          send({"type": "response", "id": req_id, "ok": True, "result": {"accepted": True}, "error": None})
        else:
          output = req.get("output_json") or "null"
          result = {"output_json": output, "error": None, "logs": [], "details": {"from": "host"}}
          send({"type": "response", "id": invoke_id, "ok": True, "result": result, "error": None})
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

  defp start_sidecar(tmp_dir, runtime_path, host_invoke_fun) do
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
        session_id: "integration",
        wasm_config: wasm_config,
        host_invoke_fun: host_invoke_fun
      )

    sidecar
  end

  defp start_real_sidecar(tmp_dir, discover_path, host_invoke_fun) do
    wasm_config = %WasmConfig{
      enabled: true,
      auto_build: true,
      runtime_path: nil,
      tool_paths: [],
      discover_paths: [discover_path],
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
        session_id: "integration-real",
        wasm_config: wasm_config,
        host_invoke_fun: host_invoke_fun
      )

    sidecar
  end

  defp build_json_transform_tool(tmp_dir) do
    repo_root = Path.expand("../../../../", __DIR__)
    tool_dir = Path.join(tmp_dir, ".lemon/wasm-tools")
    target_dir = Path.join(tmp_dir, "json-transform-target")

    manifest_path =
      Path.join([repo_root, "native", "wasm-tools", "json-transform", "Cargo.toml"])

    args = [
      "build",
      "--target",
      "wasm32-wasip2",
      "--release",
      "--manifest-path",
      manifest_path
    ]

    {output, exit_code} =
      System.cmd("cargo", args,
        cd: repo_root,
        env: [{"CARGO_TARGET_DIR", target_dir}],
        stderr_to_stdout: true
      )

    if exit_code != 0 do
      {:error, {:build_failed, output}}
    else
      compiled_wasm =
        Path.join([target_dir, "wasm32-wasip2", "release", "json_transform.wasm"])

      if File.regular?(compiled_wasm) do
        File.mkdir_p!(tool_dir)
        destination = Path.join(tool_dir, "json_transform.wasm")
        File.cp!(compiled_wasm, destination)
        {:ok, tool_dir}
      else
        {:error, {:missing_artifact, compiled_wasm, output}}
      end
    end
  end

  defp missing_wasm_target_error?(output) when is_binary(output) do
    String.contains?(output, "target may not be installed") and
      String.contains?(output, "wasm32-wasip2")
  end

  test "sidecar discover + invoke smoke", %{tmp_dir: tmp_dir} do
    runtime_path = write_sidecar_with_host_call(tmp_dir)

    sidecar =
      start_sidecar(tmp_dir, runtime_path, fn _tool, _params_json ->
        {:error, :not_used}
      end)

    assert {:ok, discover} = SidecarSession.discover(sidecar)
    assert Enum.any?(discover.tools, &(&1.name == "echo_wasm"))

    assert {:ok, invoke} =
             SidecarSession.invoke(sidecar, "echo_wasm", Jason.encode!(%{"text" => "hello"}), nil)

    assert invoke.error == nil
    assert invoke.output_json =~ "echo"
  end

  test "host callback round-trip works for tool-invoke", %{tmp_dir: tmp_dir} do
    runtime_path = write_sidecar_with_host_call(tmp_dir)

    sidecar =
      start_sidecar(tmp_dir, runtime_path, fn "host_echo", params_json ->
        params = Jason.decode!(params_json)
        {:ok, Jason.encode!(%{"host_message" => params["message"]})}
      end)

    assert {:ok, _discover} = SidecarSession.discover(sidecar)

    assert {:ok, invoke} = SidecarSession.invoke(sidecar, "call_host", Jason.encode!(%{}), nil)
    assert invoke.error == nil
    assert invoke.output_json =~ "host_message"
  end

  @tag timeout: 300_000
  test "real runtime discovers and invokes json_transform wasm tool", %{tmp_dir: tmp_dir} do
    case Builder.ensure_runtime_binary(%WasmConfig{enabled: true, auto_build: true}) do
      {:ok, _runtime_path, _build_report} ->
        :ok

      {:error, reason} ->
        flunk("failed to ensure runtime binary for integration test: #{inspect(reason)}")
    end

    tool_dir =
      case build_json_transform_tool(tmp_dir) do
        {:ok, tool_dir} ->
          tool_dir

        {:error, {:build_failed, output}} ->
          if missing_wasm_target_error?(output) do
            IO.puts("""
            skipping real wasm integration test because `wasm32-wasip2` is unavailable.
            install it with `rustup target add wasm32-wasip2`.
            """)

            nil
          else
            flunk("""
            failed to build json_transform wasm tool.
            Ensure Rust target wasm32-wasip2 is installed (e.g. `rustup target add wasm32-wasip2`).
            cargo output:
            #{output}
            """)
          end

        {:error, reason} ->
          flunk("failed to prepare json_transform wasm tool: #{inspect(reason)}")
      end

    if is_binary(tool_dir) do
      sidecar =
        start_real_sidecar(tmp_dir, tool_dir, fn _tool, _params_json ->
          {:error, :not_used}
        end)

      assert {:ok, discover} = SidecarSession.discover(sidecar)
      assert Enum.any?(discover.tools, &(&1.name == "json_transform"))

      params = %{
        "input" => %{"drop" => "x", "keep" => "value"},
        "pick" => ["keep"],
        "set" => %{"added" => true}
      }

      assert {:ok, invoke} =
               SidecarSession.invoke(
                 sidecar,
                 "json_transform",
                 Jason.encode!(params),
                 nil,
                 120_000
               )

      assert invoke.error == nil
      assert Jason.decode!(invoke.output_json) == %{"added" => true, "keep" => "value"}
    end
  end
end
