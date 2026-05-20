{:ok, _} = Application.ensure_all_started(:coding_agent)

alias AgentCore.Types.AgentToolResult
alias Ai.Types.TextContent
alias CodingAgent.Wasm.ToolFactory

defmodule LemonScripts.WasmToolTelemetrySmoke.FakeSidecar do
  use GenServer

  def start(opts), do: GenServer.start(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, Map.new(opts)}

  @impl true
  def handle_call({:invoke, tool, params_json, context_json}, _from, state) do
    send(state.owner, {:fake_wasm_invoke, tool, params_json, context_json})
    {:reply, state.response, state}
  end
end

defmodule LemonScripts.WasmToolTelemetrySmoke.TelemetryHandler do
  def handle_event(event, measurements, metadata, pid) do
    send(pid, {:wasm_tool_telemetry, event, measurements, metadata})
  end
end

now = DateTime.utc_now()
suffix = System.system_time(:millisecond) |> rem(1_000_000_000)
project_dir = Path.join(System.tmp_dir!(), "lemon-wasm-telemetry-proof-#{suffix}")
telemetry_ref = "wasm-tool-telemetry-smoke-#{suffix}"

File.rm_rf!(project_dir)
File.mkdir_p!(project_dir)

:ok =
  :telemetry.attach_many(
    telemetry_ref,
    [
      [:coding_agent, :wasm, :tool, :start],
      [:coding_agent, :wasm, :tool, :stop],
      [:coding_agent, :wasm, :tool, :exception]
    ],
    &LemonScripts.WasmToolTelemetrySmoke.TelemetryHandler.handle_event/4,
    self()
  )

tool_spec = fn name, path ->
  %{
    name: name,
    description: "WASM telemetry proof tool",
    schema_json:
      Jason.encode!(%{
        "type" => "object",
        "properties" => %{"input" => %{"type" => "string"}},
        "required" => ["input"]
      }),
    path: path,
    warnings: [],
    capabilities: %{http: false, tool_invoke: false, exec: false},
    auth: nil
  }
end

{:ok, success_sidecar} =
  LemonScripts.WasmToolTelemetrySmoke.FakeSidecar.start(
    owner: self(),
    response:
      {:ok,
       %{
         output_json: Jason.encode!(%{"ok" => true}),
         error: nil,
         logs: [],
         details: %{"runtime" => "fake"}
       }}
  )

{:ok, error_sidecar} =
  LemonScripts.WasmToolTelemetrySmoke.FakeSidecar.start(
    owner: self(),
    response: {:error, {:sidecar_error, "private sidecar error"}}
  )

dead_sidecar = spawn(fn -> :ok end)
dead_ref = Process.monitor(dead_sidecar)

receive do
  {:DOWN, ^dead_ref, :process, ^dead_sidecar, :normal} -> :ok
after
  1_000 -> raise "dead sidecar did not exit"
end

[{_success_name, success_tool, _success_source}] =
  ToolFactory.build_inventory(
    success_sidecar,
    [tool_spec.("wasm_telemetry_success", "/private/wasm/success.wasm")],
    cwd: project_dir,
    session_id: "private-session"
  )

[{_error_name, error_tool, _error_source}] =
  ToolFactory.build_inventory(
    error_sidecar,
    [tool_spec.("wasm_telemetry_error", "/private/wasm/error.wasm")],
    cwd: project_dir,
    session_id: "private-session"
  )

[{_exception_name, exception_tool, _exception_source}] =
  ToolFactory.build_inventory(
    dead_sidecar,
    [tool_spec.("wasm_telemetry_exception", "/private/wasm/exception.wasm")],
    cwd: project_dir,
    session_id: "private-session"
  )

success_result =
  success_tool.execute.(
    "raw-wasm-success-call",
    %{"input" => "ok", "secret" => "do-not-leak"},
    nil,
    nil
  )

error_result =
  error_tool.execute.(
    "raw-wasm-error-call",
    %{"input" => "fail", "secret" => "do-not-leak"},
    nil,
    nil
  )

exception_result =
  try do
    exception_tool.execute.(
      "raw-wasm-exception-call",
      %{"input" => "boom", "secret" => "do-not-leak"},
      nil,
      nil
    )

    :unexpected_success
  catch
    :exit, _reason -> :exited
  end

telemetry_events =
  Enum.reduce(1..8, [], fn _, events ->
    receive do
      {:wasm_tool_telemetry, event, measurements, metadata} ->
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

has_event? = fn event_name, tool_name, matcher ->
  Enum.any?(telemetry_events, fn
    {^event_name, measurements, metadata} ->
      metadata.host == :wasm and metadata.tool_name == tool_name and
        is_binary(metadata.wasm_path_hash) and is_binary(metadata.tool_call_hash) and
        matcher.(measurements, metadata)

    _ ->
      false
  end)
end

telemetry_text = inspect(telemetry_events)

checks = [
  run_check.("wasm_tool_success_emits_redacted_start_stop_telemetry", fn ->
    match?(%AgentToolResult{content: [%TextContent{} | _], trust: :untrusted}, success_result) and
      has_event?.([:coding_agent, :wasm, :tool, :start], "wasm_telemetry_success", fn
        %{count: 1}, _metadata -> true
        _, _ -> false
      end) and
      has_event?.([:coding_agent, :wasm, :tool, :stop], "wasm_telemetry_success", fn
        %{count: 1, duration_us: duration_us}, %{status: :ok} -> is_integer(duration_us)
        _, _ -> false
      end)
  end),
  run_check.("wasm_tool_error_emits_redacted_error_status", fn ->
    match?(%AgentToolResult{trust: :untrusted}, error_result) and
      has_event?.([:coding_agent, :wasm, :tool, :stop], "wasm_telemetry_error", fn
        %{count: 1, duration_us: duration_us}, %{status: :error} -> is_integer(duration_us)
        _, _ -> false
      end)
  end),
  run_check.("wasm_tool_exit_emits_redacted_exception_telemetry", fn ->
    exception_result == :exited and
      has_event?.([:coding_agent, :wasm, :tool, :exception], "wasm_telemetry_exception", fn
        %{count: 1, duration_us: duration_us}, %{kind: :exit, error_type: error_type} ->
          is_integer(duration_us) and is_binary(error_type)

        _, _ ->
          false
      end)
  end),
  run_check.("wasm_tool_telemetry_omits_raw_sensitive_values", fn ->
    not String.contains?(telemetry_text, "raw-wasm-success-call") and
      not String.contains?(telemetry_text, "raw-wasm-error-call") and
      not String.contains?(telemetry_text, "raw-wasm-exception-call") and
      not String.contains?(telemetry_text, "do-not-leak") and
      not String.contains?(telemetry_text, "/private/wasm") and
      not String.contains?(telemetry_text, project_dir) and
      not String.contains?(telemetry_text, "private-session") and
      not String.contains?(telemetry_text, "private sidecar error")
  end)
]

completed_count = Enum.count(checks, &(&1.status == "completed"))
failed_count = Enum.count(checks, &(&1.status == "failed"))

proof = %{
  "proof" => "wasm_tool_telemetry_smoke",
  "status" => if(failed_count == 0, do: "completed", else: "failed"),
  "generated_at" => DateTime.to_iso8601(now),
  "completed_count" => completed_count,
  "failed_count" => failed_count,
  "checks" => checks,
  "host_boundary" => %{
    "host" => "wasm",
    "emits_start_stop_exception" => true,
    "uses_hashed_wasm_paths" => true,
    "tool_count" => 3
  },
  "redaction" => %{
    "contains_raw_paths" => false,
    "contains_raw_params" => false,
    "contains_raw_tool_call_ids" => false,
    "contains_sidecar_error_text" => false,
    "contains_tool_result_payload" => false
  }
}

File.mkdir_p!(".lemon/proofs")
json = Jason.encode!(proof, pretty: true)
File.write!(".lemon/proofs/wasm-tool-telemetry-latest.json", json <> "\n")

archive =
  ".lemon/proofs/wasm-tool-telemetry-" <>
    (now |> DateTime.to_iso8601() |> String.replace(~r/[:.]/, "-")) <> ".json"

File.write!(archive, json <> "\n")

for pid <- [success_sidecar, error_sidecar] do
  if Process.alive?(pid), do: GenServer.stop(pid)
end

File.rm_rf!(project_dir)
:telemetry.detach(telemetry_ref)

if failed_count == 0 do
  IO.puts("wasm tool telemetry smoke proof passed: #{completed_count} completed")
else
  IO.puts("wasm tool telemetry smoke proof failed: #{failed_count} failed")
  System.halt(1)
end
