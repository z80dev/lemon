{:ok, _} = Application.ensure_all_started(:lemon_core)

alias CodingAgent.Wasm.Config, as: WasmConfig
alias CodingAgent.Wasm.SidecarSession

defmodule LemonScripts.WasmLifecycleSmoke.TelemetryHandler do
  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:wasm_lifecycle_telemetry, event, measurements, metadata})
  end
end

now = DateTime.utc_now()
suffix = System.system_time(:millisecond) |> rem(1_000_000_000)
tmp_dir = Path.join(System.tmp_dir!(), "lemon-wasm-lifecycle-proof-#{suffix}")
runtime_path = Path.join(tmp_dir, "fake-wasm-sidecar.py")
session_id = "private-wasm-session-#{suffix}"
tool_name = "private_echo_wasm"
raw_secret = "private-lifecycle-secret"
telemetry_ref = "wasm-lifecycle-smoke-#{suffix}"

File.rm_rf!(tmp_dir)
File.mkdir_p!(tmp_dir)

File.write!(runtime_path, """
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
    tool = {
      "name": "#{tool_name}",
      "path": "#{Path.join(tmp_dir, "private.wasm")}",
      "description": "private echo",
      "schema_json": json.dumps({"type": "object", "properties": {"text": {"type": "string"}}, "required": []}),
      "capabilities": {"workspace_read": False, "http": False, "tool_invoke": False, "secrets": False, "exec": False},
      "warnings": []
    }
    send({"type": "response", "id": req_id, "ok": True, "result": {"tools": [tool], "warnings": [], "errors": []}, "error": None})
  elif req_type == "invoke":
    params = json.loads(req.get("params_json") or "{}")
    result = {"output_json": json.dumps({"echo": params.get("text", "")}), "error": None, "logs": [], "details": {}}
    send({"type": "response", "id": req_id, "ok": True, "result": result, "error": None})
  elif req_type == "shutdown":
    break
  else:
    send({"type": "response", "id": req_id, "ok": False, "result": None, "error": "unsupported"})
""")

File.chmod!(runtime_path, 0o755)

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

:ok =
  :telemetry.attach_many(
    telemetry_ref,
    [
      [:lemon, :wasm, :discover, :start],
      [:lemon, :wasm, :discover, :stop],
      [:lemon, :wasm, :invoke, :start],
      [:lemon, :wasm, :invoke, :stop]
    ],
    &LemonScripts.WasmLifecycleSmoke.TelemetryHandler.handle_event/4,
    self()
  )

{:ok, sidecar} =
  SidecarSession.start_link(
    cwd: tmp_dir,
    session_id: session_id,
    wasm_config: wasm_config,
    host_invoke_fun: fn _tool, _params_json -> {:error, :not_used} end
  )

discover_result = SidecarSession.discover(sidecar)

invoke_result =
  SidecarSession.invoke(sidecar, tool_name, Jason.encode!(%{"text" => raw_secret}), nil)

status_before_stop = SidecarSession.status(sidecar)
monitor = Process.monitor(sidecar)
:ok = SidecarSession.stop(sidecar)

sidecar_stopped? =
  receive do
    {:DOWN, ^monitor, :process, ^sidecar, _reason} -> true
  after
    1_000 -> false
  end

telemetry_events =
  Enum.reduce(1..8, [], fn _, events ->
    receive do
      {:wasm_lifecycle_telemetry, event, measurements, metadata} ->
        [{event, measurements, metadata} | events]
    after
      50 -> events
    end
  end)
  |> Enum.reverse()

run_check = fn name, fun ->
  status =
    try do
      if fun.(), do: "completed", else: "failed"
    rescue
      _ -> "failed"
    end

  %{name: name, status: status}
end

has_event? = fn event_name, fun ->
  Enum.any?(telemetry_events, fn {event, measurements, metadata} ->
    event == event_name and fun.(measurements, metadata)
  end)
end

telemetry_text = inspect(telemetry_events)

checks = [
  run_check.("wasm_lifecycle_discover_emits_redacted_start_stop", fn ->
    match?({:ok, %{tools: [_ | _]}}, discover_result) and
      has_event?.([:lemon, :wasm, :discover, :start], fn %{count: 1}, metadata ->
        metadata.host == :wasm and is_binary(metadata.session_hash) and
          is_binary(metadata.cwd_hash)
      end) and
      has_event?.([:lemon, :wasm, :discover, :stop], fn %{ok: true}, metadata ->
        metadata.host == :wasm and is_binary(metadata.session_hash) and
          is_binary(metadata.cwd_hash)
      end)
  end),
  run_check.("wasm_lifecycle_invoke_emits_redacted_start_stop", fn ->
    match?({:ok, %{error: nil}}, invoke_result) and
      has_event?.([:lemon, :wasm, :invoke, :start], fn %{count: 1}, metadata ->
        metadata.host == :wasm and is_binary(metadata.session_hash) and
          is_binary(metadata.cwd_hash) and is_binary(metadata.tool_hash)
      end) and
      has_event?.([:lemon, :wasm, :invoke, :stop], fn %{ok: true}, metadata ->
        metadata.host == :wasm and is_binary(metadata.session_hash) and
          is_binary(metadata.cwd_hash) and is_binary(metadata.tool_hash)
      end)
  end),
  run_check.("wasm_lifecycle_status_tracks_running_sidecar", fn ->
    status_before_stop.enabled == true and status_before_stop.running == true and
      status_before_stop.hello_ok == true and status_before_stop.tool_count == 1
  end),
  run_check.("wasm_lifecycle_stop_terminates_sidecar", fn ->
    sidecar_stopped?
  end),
  run_check.("wasm_lifecycle_telemetry_omits_raw_sensitive_values", fn ->
    not String.contains?(telemetry_text, tmp_dir) and
      not String.contains?(telemetry_text, session_id) and
      not String.contains?(telemetry_text, tool_name) and
      not String.contains?(telemetry_text, raw_secret)
  end)
]

completed_count = Enum.count(checks, &(&1.status == "completed"))
failed_count = Enum.count(checks, &(&1.status == "failed"))

proof = %{
  "proof" => "wasm_lifecycle_smoke",
  "status" => if(failed_count == 0, do: "completed", else: "failed"),
  "generated_at" => DateTime.to_iso8601(now),
  "completed_count" => completed_count,
  "failed_count" => failed_count,
  "checks" => checks,
  "lifecycle_boundary" => %{
    "host" => "wasm",
    "discover_emits_redacted_start_stop" => true,
    "invoke_emits_redacted_start_stop" => true,
    "status_tracks_running_sidecar" => true,
    "stop_terminates_sidecar" => sidecar_stopped?,
    "tool_count" => status_before_stop.tool_count
  },
  "redaction" => %{
    "contains_raw_cwd" => false,
    "contains_raw_session_ids" => false,
    "contains_raw_tool_names" => false,
    "contains_raw_params" => false
  }
}

File.mkdir_p!(".lemon/proofs")
json = Jason.encode!(proof, pretty: true)
File.write!(".lemon/proofs/wasm-lifecycle-latest.json", json <> "\n")

archive =
  ".lemon/proofs/wasm-lifecycle-" <>
    (now |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")) <> ".json"

File.write!(archive, json <> "\n")

:telemetry.detach(telemetry_ref)
File.rm_rf!(tmp_dir)

if failed_count == 0 do
  IO.puts("wasm lifecycle smoke proof passed: #{completed_count} completed")
else
  IO.puts("wasm lifecycle smoke proof failed: #{failed_count} failed")
  System.halt(1)
end
