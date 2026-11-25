defmodule LemonCore.RawProcessArchitectureTest do
  use ExUnit.Case, async: true

  @root Path.expand("../../../..", __DIR__)
  @raw_process ~r/\b(?:Task\.start|spawn)\s*\(/

  # Exact paths and counts, not directory exemptions. Removing a retained site
  # must shrink this list; adding one needs its own lifecycle justification.
  # Existing linked/monitored ownership primitives are not operational task
  # fallbacks. Do not evade this contract by changing the spawning primitive.
  @allowlist %{
    "apps/coding_agent/lib/coding_agent/eval/bridge.ex" =>
      {1, "Lock-lifetime guardian kills a tool when its eval lock owner dies, including :kill."},
    "apps/coding_agent/lib/coding_agent/execution_node/worker.ex" =>
      {1, "Cancellation reaper must finish the abort grace and force-kill after worker teardown."},
    "apps/coding_agent/lib/coding_agent/executor/remote_session_runner.ex" =>
      {1, "Approval guardian outlives both owners to cancel a row only after waiter death."},
    "apps/coding_agent/lib/coding_agent/tools/bash/capture.ex" =>
      {1, "Secret-file guardian removes capture files even when the tool skips its after block."},
    "apps/coding_agent/lib/coding_agent/tools/bash/managed.ex" =>
      {1, "Foreground guardian kills its managed workload after brutal tool-owner death."},
    "apps/coding_agent/lib/coding_agent/tools/checker_runner.ex" =>
      {1, "Launch guardian kills the checker process group after brutal tool-caller death."},
    "apps/coding_agent/lib/coding_agent/tools/webfetch.ex" =>
      {1, "Staged-PDF reaper must remove private files after forced extractor cancellation."},
    "apps/lemon_ai/lib/lemon_ai/event_stream.ex" =>
      {1, "Stream cancellation reaper enforces kill after grace even after stream-owner exit."},
    "apps/lemon_channels/lib/lemon_channels/adapters/email/attachments.ex" =>
      {1, "Channel attachment write ownership is excluded from #585 and tracked by #580/#581."},
    "apps/lemon_core/lib/lemon_core/bus/delivery.ex" =>
      {1,
       "One bounded admission process per delivery handle monitors creator and consumer and exits on close/fence; this is the retained Bus.Delivery lifetime primitive."},
    "apps/lemon_core/lib/lemon_core/drain.ex" =>
      {2,
       "VM drain coordinator and deadline failsafe must survive application supervisor shutdown to stop the VM."},
    "apps/lemon_core/lib/lemon_core/testing/async_helpers.ex" =>
      {1, "Documentation-only latch example; no production task is launched by this literal."},
    "apps/lemon_core/lib/lemon_core/testing/file_server_tap.ex" =>
      {1,
       "Test-only :file_server_2 proxy for async: false race tests; with_tap/2 restores the real server and kills the proxy."},
    "apps/lemon_gateway/lib/lemon_gateway/transports/webhook/response.ex" =>
      {1, "Channel callback-delivery ownership is excluded from #585 and tracked by #580/#581."},
    "apps/lemon_gateway/lib/lemon_gateway/voice/twilio_websocket.ex" =>
      {1, "Voice WebSocket operation ownership belongs to #588."},
    "apps/lemon_gateway/lib/lemon_gateway/voice/webhook_router.ex" =>
      {1, "Voice webhook operation ownership belongs to #588."},
    "apps/lemon_omp/lib/lemon_omp/approval.ex" =>
      {1,
       "Approval guardian must survive forced Session/waiter death to cancel pending authority."},
    "apps/lemon_skills/lib/lemon_mcp/client/sse.ex" =>
      {1,
       "SSE reader owns the pinned Mint socket, monitors its client and closes the stream when the client exits."}
  }

  test "raw process creation in lib matches the exact reviewed lifecycle allowlist" do
    sources =
      ["apps/*/lib/**/*.{ex,exs}", "lib/**/*.{ex,exs}"]
      |> Enum.flat_map(&Path.wildcard(Path.join(@root, &1)))

    assert sources != []

    actual =
      sources
      |> Enum.map(fn path ->
        {Path.relative_to(path, @root), raw_count(File.read!(path))}
      end)
      |> Enum.reject(fn {_path, count} -> count == 0 end)
      |> Map.new()

    expected = Map.new(@allowlist, fn {path, {count, _reason}} -> {path, count} end)

    assert actual == expected,
           "Raw tasks must use LemonCore.TaskSupervisor without a fallback. " <>
             "Only the exact lifecycle/issue exclusions above are retained. " <>
             "Update removed exclusions too.\nActual: #{inspect(actual, pretty: true)}"
  end

  test "the guard catches literal and qualified calls but not supervised admission" do
    assert raw_count("Task.start(fn -> :ok end)") == 1
    assert raw_count("spawn(fn -> :ok end)") == 1
    assert raw_count("Kernel.spawn (fn -> :ok end)") == 1
    assert raw_count(":erlang.spawn(fn -> :ok end)") == 1
    assert raw_count("LemonCore.TaskSupervisor.start_child(supervisor, fun)") == 0
    assert raw_count("Task.Supervisor.start_child(supervisor, fun)") == 0
    assert Enum.all?(@allowlist, fn {_path, {count, reason}} -> count > 0 and reason != "" end)
  end

  defp raw_count(source), do: length(Regex.scan(@raw_process, source))
end
