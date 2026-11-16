defmodule LemonChannels.PortBridgeContractTest do
  use ExUnit.Case, async: false

  alias LemonChannels.PortBridge

  @moduletag :tmp_dir
  @fixture_start_timeout 30_000

  @bridges [
    %{
      label: "xmtp",
      event_tag: :xmtp_bridge_event,
      script_filename: "xmtp_bridge.mjs"
    },
    %{
      label: "whatsapp",
      event_tag: :whatsapp_bridge_event,
      script_filename: "whatsapp_bridge.mjs"
    }
  ]

  test "adapter specs preserve event tags, labels, and configured script paths", %{
    tmp_dir: tmp_dir
  } do
    Enum.each(@bridges, fn bridge ->
      missing_script = Path.join(tmp_dir, "missing_#{bridge.script_filename}")

      with_bridge(bridge, missing_script, fn pid ->
        assert :proc_lib.translate_initial_call(pid) == {PortBridge, :init, 1}

        assert_receive {event_tag,
                        %{
                          "type" => "error",
                          "message" => message,
                          "reason" => reason
                        }},
                       1_000

        assert event_tag == bridge.event_tag
        assert message == "failed to start #{bridge.label} bridge"
        assert reason =~ missing_script or reason =~ "node executable not found"

        PortBridge.command(pid, %{"op" => "connect"})

        assert_receive {event_tag,
                        %{
                          "type" => "error",
                          "message" => unavailable_message,
                          "op" => "connect"
                        }},
                       1_000

        assert event_tag == bridge.event_tag
        assert unavailable_message == "#{bridge.label} bridge unavailable"

        state = :sys.get_state(pid)
        assert state.script_path == Path.expand(missing_script)
        assert state.bridge.script_filename == bridge.script_filename
      end)
    end)
  end

  test "without a configured bridge_script both adapters run the script shipped in lemon_channels/priv" do
    Enum.each(@bridges, fn bridge ->
      {:ok, pid} = PortBridge.start_link({bridge, [config: %{}, notify_pid: self()]})

      try do
        expected = Application.app_dir(:lemon_channels, "priv/#{bridge.script_filename}")

        assert :sys.get_state(pid).script_path == expected
        assert File.regular?(expected)
      after
        if Process.alive?(pid), do: GenServer.stop(pid)
      end
    end)
  end

  test "shared parser keeps adapter-specific event and error envelopes", %{tmp_dir: tmp_dir} do
    if System.find_executable("node") do
      startup_marker_path = Path.join(tmp_dir, "bridge_parser_started.txt")
      script_path = Path.join(tmp_dir, "bridge_parser_fixture.mjs")
      :ok = File.write(script_path, parser_fixture_script(startup_marker_path))

      Enum.each(@bridges, fn bridge ->
        with_bridge(bridge, script_path, fn pid ->
          assert_receive {ready_event_tag, %{"type" => "bridge_test_ready"}},
                         @fixture_start_timeout

          assert ready_event_tag == bridge.event_tag

          PortBridge.command(pid, %{op: "contract_probe", adapter: bridge.label})

          assert_receive {event_tag,
                          %{
                            "type" => "error",
                            "message" => invalid_message,
                            "line" => "not-json"
                          }},
                         2_000

          assert event_tag == bridge.event_tag
          assert invalid_message == "#{bridge.label} bridge emitted invalid JSON"

          assert_receive {event_tag,
                          %{
                            "type" => "error",
                            "message" => non_object_message,
                            "payload" => []
                          }},
                         2_000

          assert event_tag == bridge.event_tag
          assert non_object_message == "#{bridge.label} bridge emitted non-object JSON"

          assert_receive {event_tag,
                          %{
                            "type" => "bridge_contract",
                            "op" => "contract_probe",
                            "adapter" => adapter
                          }},
                         2_000

          assert event_tag == bridge.event_tag
          assert adapter == bridge.label
        end)
      end)
    else
      assert true
    end
  end

  test "both adapters replay the remembered connect command after a port restart", %{
    tmp_dir: tmp_dir
  } do
    if System.find_executable("node") do
      Enum.each(@bridges, fn bridge ->
        bridge_dir = Path.join(tmp_dir, bridge.label)
        :ok = File.mkdir_p(bridge_dir)

        counter_path = Path.join(bridge_dir, "bridge_start_count.txt")
        script_path = Path.join(bridge_dir, "bridge_restart_fixture.mjs")

        # One deliberately slow first boot proves that response deadlines begin
        # at fixture readiness while the immediately queued command is preserved.
        startup_delay_ms = if bridge.label == "xmtp", do: 2_500, else: 0

        :ok =
          File.write(script_path, restart_fixture_script(counter_path, startup_delay_ms))

        with_bridge(bridge, script_path, fn pid ->
          PortBridge.command(pid, %{
            "op" => "connect",
            "identity" => "test-#{bridge.label}"
          })

          assert_receive {ready_event_tag,
                          %{
                            "type" => "bridge_test_ready",
                            "generation" => first_generation
                          }},
                         @fixture_start_timeout

          assert ready_event_tag == bridge.event_tag

          assert_receive {connect_event_tag,
                          %{
                            "type" => "bridge_test_connect",
                            "generation" => ^first_generation
                          }},
                         2_000

          assert connect_event_tag == bridge.event_tag

          assert_receive {exit_event_tag, %{"type" => "error", "message" => exit_message}},
                         4_000

          assert exit_event_tag == bridge.event_tag
          assert exit_message == "#{bridge.label} bridge exited"

          assert_receive {restart_ready_event_tag,
                          %{
                            "type" => "bridge_test_ready",
                            "generation" => second_generation
                          }},
                         @fixture_start_timeout

          assert restart_ready_event_tag == bridge.event_tag
          assert second_generation == first_generation + 1

          assert_receive {replay_event_tag,
                          %{
                            "type" => "bridge_test_connect",
                            "generation" => ^second_generation
                          }},
                         2_000

          assert replay_event_tag == bridge.event_tag
        end)
      end)
    else
      assert true
    end
  end

  @tag :node
  test "stopping either bridge kills orphaned grandchildren before returning", %{tmp_dir: tmp_dir} do
    script = Path.join(tmp_dir, "process_tree.mjs")
    File.write!(script, process_tree_script())

    for bridge <- @bridges do
      with_bridge(bridge, script, fn pid ->
        pids = await_process_tree(bridge)
        :ok = GenServer.stop(pid)
        assert_processes_stopped(pids)
      end)
    end
  end

  @tag :node
  test "manual bridge exit cleans its group before notifying its owner", %{tmp_dir: tmp_dir} do
    script = Path.join(tmp_dir, "process_tree.mjs")
    File.write!(script, process_tree_script())
    bridge = Enum.find(@bridges, &(&1.label == "whatsapp"))

    {:ok, pid} =
      PortBridge.start_link(
        {bridge, [config: %{bridge_script: script}, notify_pid: self(), restart: :manual]}
      )

    try do
      pids = await_process_tree(bridge)
      PortBridge.command(pid, %{"op" => "crash"})
      assert_receive {:whatsapp_bridge_event, %{"type" => "bridge_down"}}, 5_000
      assert_processes_stopped(pids)
      assert :sys.get_state(pid).os_pid == nil
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  @tag :node
  test "WhatsApp timeout kills its group and fails all pending sends without replay", %{
    tmp_dir: tmp_dir
  } do
    script = Path.join(tmp_dir, "process_tree.mjs")
    File.write!(script, process_tree_script())
    bridge = Enum.find(@bridges, &(&1.label == "whatsapp"))

    {:ok, pid} =
      PortBridge.start_link(
        {bridge, [config: %{bridge_script: script}, notify_pid: self(), restart: :manual]}
      )

    try do
      pids = await_process_tree(bridge)
      PortBridge.command(pid, %{"op" => "connect"})
      assert :sys.get_state(pid).connect_command == %{"op" => "connect"}
      first = make_ref()
      second = make_ref()
      first_timer = Process.send_after(self(), :unexpected_timeout, 60_000)
      second_timer = Process.send_after(self(), :unexpected_timeout, 60_000)

      state = %{
        port_server: pid,
        pending_commands: %{
          "first" => {{self(), first}, first_timer},
          "second" => {{self(), second}, second_timer}
        },
        connected?: true,
        own_jid: "test",
        reconnect_timer: nil,
        reconnect_attempts: 0
      }

      assert {:noreply, failed} =
               LemonChannels.Adapters.WhatsApp.Transport.handle_info(
                 {:command_timeout, "first"},
                 state
               )

      {reconnect_timer, _ref} = failed.reconnect_timer
      Process.cancel_timer(reconnect_timer)
      assert_receive {^first, {:error, :outcome_unknown}}
      assert_receive {^second, {:error, :outcome_unknown}}
      assert Process.read_timer(first_timer) == false
      assert Process.read_timer(second_timer) == false
      assert failed.pending_commands == %{}
      refute failed.connected?
      assert failed.reconnect_attempts == 1
      assert_processes_stopped(pids)
      assert %{port: nil, os_pid: nil, connect_command: nil} = :sys.get_state(pid)

      assert {:noreply, ^failed} =
               LemonChannels.Adapters.WhatsApp.Transport.handle_info(
                 {:command_timeout, "second"},
                 failed
               )
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp await_process_tree(bridge) do
    event_tag = bridge.event_tag
    assert_receive {^event_tag, %{"type" => "process_tree", "pids" => [root, grandchild]}}, 30_000
    assert root > 1
    assert grandchild > 1
    on_exit(fn -> LemonCore.ProcessGroup.terminate(root, grace_ms: 0) end)
    assert Enum.all?([root, grandchild], &os_process_alive?/1)
    [root, grandchild]
  end

  defp assert_processes_stopped(pids) do
    Enum.each(pids, fn pid ->
      refute os_process_alive?(pid), "OS process #{pid} survived cleanup"
    end)
  end

  defp os_process_alive?(pid) do
    case System.cmd("ps", ["-o", "stat=", "-p", to_string(pid)], stderr_to_stdout: true) do
      {status, 0} ->
        status = String.trim(status)
        status != "" and not String.starts_with?(status, "Z")

      {_output, _status} ->
        false
    end
  end

  defp process_tree_script do
    ~S"""
    import { spawn } from "node:child_process";
    import { createInterface } from "node:readline";

    process.on("SIGTERM", () => {});
    const child = spawn("/bin/sh", ["-c",
      'trap "" TERM; sleep 60 </dev/null >/dev/null 2>&1 & printf "%s" "$!"'
    ], { stdio: ["ignore", "pipe", "ignore"] });
    let pid = "";
    child.stdout.on("data", data => { pid += data; });
    await new Promise((resolve, reject) => {
      child.once("error", reject);
      child.once("close", resolve);
    });
    createInterface({ input: process.stdin }).on("line", line => {
      if (JSON.parse(line).op === "crash") process.exit(7);
    });
    process.stdout.write(JSON.stringify({
      type: "process_tree", pids: [process.pid, Number(pid)]
    }) + "\n");
    """
  end

  defp with_bridge(bridge, script_path, fun) do
    {:ok, pid} =
      PortBridge.start_link({bridge, [config: %{bridge_script: script_path}, notify_pid: self()]})

    try do
      fun.(pid)
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp parser_fixture_script(startup_marker_path) do
    """
    #!/usr/bin/env node
    import fs from "node:fs";
    import readline from "node:readline";

    const startupMarkerPath = #{inspect(startup_marker_path)};
    const emit = (payload) => process.stdout.write(JSON.stringify(payload) + "\\n");

    // Make one fixture boot exceed the former response timeout. Port.open/2
    // confirms the OS process exists, not that Node has installed its reader.
    if (!fs.existsSync(startupMarkerPath)) {
      fs.writeFileSync(startupMarkerPath, "started");
      await new Promise((resolve) => setTimeout(resolve, 2500));
    }

    const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

    rl.on("line", (line) => {
      const command = JSON.parse(line);
      process.stdout.write("not-json\\n");
      process.stdout.write("[]\\n");
      emit({ type: "bridge_contract", op: command.op, adapter: command.adapter });
    });

    emit({ type: "bridge_test_ready" });
    """
  end

  defp restart_fixture_script(counter_path, startup_delay_ms) do
    """
    #!/usr/bin/env node
    import fs from "node:fs";
    import readline from "node:readline";

    const counterPath = #{inspect(counter_path)};
    let generation = 1;

    try {
      const prev = Number.parseInt(fs.readFileSync(counterPath, "utf8"), 10);
      if (!Number.isNaN(prev)) generation = prev + 1;
    } catch (_error) {}

    fs.writeFileSync(counterPath, String(generation));

    const emit = (payload) => process.stdout.write(JSON.stringify(payload) + "\\n");
    const startupDelayMs = #{startup_delay_ms};

    // Model a cold Node startup that is slower than the command-response timeout.
    // The bridge pipe may accept a command before the fixture installs its reader.
    if (generation === 1 && startupDelayMs > 0) {
      await new Promise((resolve) => setTimeout(resolve, startupDelayMs));
    }

    const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

    rl.on("line", (line) => {
      let command;

      try {
        command = JSON.parse(line);
      } catch (_error) {
        return;
      }

      if (command?.op === "connect") {
        const event = JSON.stringify({ type: "bridge_test_connect", generation }) + "\\n";
        process.stdout.write(event, () => process.exit(0));
      }
    });

    emit({ type: "bridge_test_ready", generation });
    """
  end
end
