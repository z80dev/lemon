defmodule CodingAgent.WasmSessionTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Session
  alias CodingAgent.SettingsManager

  alias Ai.Types.{AssistantMessage, Cost, Model, ModelCost, TextContent, Usage}

  @moduletag :tmp_dir

  defp mock_model do
    %Model{
      id: "mock-model",
      name: "Mock Model",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://api.mock.test",
      reasoning: false,
      input: [:text],
      cost: %ModelCost{input: 0.01, output: 0.03},
      context_window: 128_000,
      max_tokens: 4096,
      headers: %{},
      compat: nil
    }
  end

  defp mock_usage do
    %Usage{
      input: 10,
      output: 5,
      cache_read: 0,
      cache_write: 0,
      total_tokens: 15,
      cost: %Cost{input: 0.0001, output: 0.0002, total: 0.0003}
    }
  end

  defp assistant_message(text) do
    %AssistantMessage{
      role: :assistant,
      content: [%TextContent{type: :text, text: text}],
      api: :mock,
      provider: :mock_provider,
      model: "mock-model",
      usage: mock_usage(),
      stop_reason: :stop,
      error_message: nil,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp mock_stream_fn_single(response) do
    fn _model, _context, _options ->
      {:ok, stream} = Ai.EventStream.start_link()

      Task.start(fn ->
        Ai.EventStream.push(stream, {:start, response})
        Ai.EventStream.push(stream, {:done, response.stop_reason, response})
        Ai.EventStream.complete(stream, response)
      end)

      {:ok, stream}
    end
  end

  defp settings_with_wasm(wasm_cfg) do
    %SettingsManager{tools: %{wasm: wasm_cfg}}
  end

  defp write_fake_sidecar(tmp_dir) do
    path = Path.join(tmp_dir, "fake-wasm-sidecar.py")

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
        send({"type": "response", "id": req_id, "ok": True, "result": {"version": 1, "name": "fake"}, "error": None})
      elif req_type == "discover":
        tool = {
          "name": "echo_wasm",
          "path": "/tmp/echo_wasm.wasm",
          "description": "Echo from fake wasm",
          "schema_json": json.dumps({"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}),
          "capabilities": {"workspace_read": False, "http": False, "tool_invoke": False, "secrets": False},
          "warnings": []
        }
        send({"type": "response", "id": req_id, "ok": True, "result": {"tools": [tool], "warnings": [], "errors": []}, "error": None})
      elif req_type == "invoke":
        params_raw = req.get("params_json") or "{}"
        params = json.loads(params_raw)
        output = json.dumps({"echo": params.get("text", "")})
        result = {"output_json": output, "error": None, "logs": [], "details": {"runtime": "fake"}}
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

  defp start_session(tmp_dir, settings_manager) do
    {:ok, session} =
      Session.start_link(
        cwd: tmp_dir,
        model: mock_model(),
        settings_manager: settings_manager,
        stream_fn: mock_stream_fn_single(assistant_message("ok"))
      )

    session
  end

  test "session startup does not fail when wasm runtime is missing", %{tmp_dir: tmp_dir} do
    settings =
      settings_with_wasm(%{
        enabled: true,
        auto_build: false,
        runtime_path: Path.join(tmp_dir, "missing-runtime"),
        tool_paths: []
      })

    session = start_session(tmp_dir, settings)
    state = Session.get_state(session)

    assert state.wasm_sidecar_pid == nil
    assert state.wasm_tool_names == []
    assert is_map(state.wasm_status)
    assert Map.has_key?(state.wasm_status, :reason)
    assert "read" in Enum.map(state.tools, & &1.name)
  end

  test "reload_extensions re-discovers wasm tools", %{tmp_dir: tmp_dir} do
    runtime_path = write_fake_sidecar(tmp_dir)

    settings =
      settings_with_wasm(%{
        enabled: true,
        auto_build: false,
        runtime_path: runtime_path,
        tool_paths: []
      })

    session = start_session(tmp_dir, settings)
    state = Session.get_state(session)

    assert is_pid(state.wasm_sidecar_pid)
    assert "echo_wasm" in state.wasm_tool_names

    assert {:ok, report} = Session.reload_extensions(session)
    assert report.wasm.running == true

    reloaded_state = Session.get_state(session)
    assert "echo_wasm" in reloaded_state.wasm_tool_names
  end

  test "session terminate cleans up wasm sidecar", %{tmp_dir: tmp_dir} do
    runtime_path = write_fake_sidecar(tmp_dir)

    settings =
      settings_with_wasm(%{
        enabled: true,
        auto_build: false,
        runtime_path: runtime_path,
        tool_paths: []
      })

    session = start_session(tmp_dir, settings)
    sidecar_pid = Session.get_state(session).wasm_sidecar_pid

    assert is_pid(sidecar_pid)
    Process.monitor(sidecar_pid)

    :ok = GenServer.stop(session)

    assert_receive {:DOWN, _ref, :process, ^sidecar_pid, _reason}, 1_000
  end
end
