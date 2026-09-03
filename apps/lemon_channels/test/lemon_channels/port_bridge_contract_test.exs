defmodule LemonChannels.PortBridgeContractTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.WhatsApp.PortServer, as: WhatsAppPortServer
  alias LemonChannels.Adapters.Xmtp.PortServer, as: XmtpPortServer

  @moduletag :tmp_dir
  @fixture_start_timeout 30_000

  @bridges [
    %{
      label: "xmtp",
      module: XmtpPortServer,
      event_tag: :xmtp_bridge_event,
      script_filename: "xmtp_bridge.mjs"
    },
    %{
      label: "whatsapp",
      module: WhatsAppPortServer,
      event_tag: :whatsapp_bridge_event,
      script_filename: "whatsapp_bridge.mjs"
    }
  ]

  test "adapter wrappers preserve their public worker child specs" do
    Enum.each(@bridges, fn %{module: module} ->
      opts = [config: %{bridge_script: "/tmp/bridge.mjs"}, notify_pid: self()]

      assert %{id: ^module, start: {^module, :start_link, [^opts]}} = module.child_spec(opts)
      assert function_exported?(module, :init, 1)
      assert function_exported?(module, :handle_cast, 2)
      assert function_exported?(module, :handle_info, 2)
    end)
  end

  test "adapter wrappers preserve event tags, labels, and configured script paths", %{
    tmp_dir: tmp_dir
  } do
    Enum.each(@bridges, fn bridge ->
      missing_script = Path.join(tmp_dir, "missing_#{bridge.script_filename}")

      with_bridge(bridge, missing_script, fn pid ->
        assert :proc_lib.translate_initial_call(pid) == {bridge.module, :init, 1}

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

        bridge.module.command(pid, %{"op" => "connect"})

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

          bridge.module.command(pid, %{op: "contract_probe", adapter: bridge.label})

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

  test "both wrappers replay the remembered connect command after a port restart", %{
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
          bridge.module.command(pid, %{
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

  defp with_bridge(bridge, script_path, fun) do
    {:ok, pid} =
      bridge.module.start_link(config: %{bridge_script: script_path}, notify_pid: self())

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
