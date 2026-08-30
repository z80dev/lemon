defmodule LemonChannels.PortBridgeContractTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.WhatsApp.PortServer, as: WhatsAppPortServer
  alias LemonChannels.Adapters.Xmtp.PortServer, as: XmtpPortServer

  @moduletag :tmp_dir

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
      script_path = Path.join(tmp_dir, "bridge_parser_fixture.mjs")
      :ok = File.write(script_path, parser_fixture_script())

      Enum.each(@bridges, fn bridge ->
        with_bridge(bridge, script_path, fn pid ->
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
        :ok = File.write(script_path, restart_fixture_script(counter_path))

        with_bridge(bridge, script_path, fn pid ->
          bridge.module.command(pid, %{
            "op" => "connect",
            "identity" => "test-#{bridge.label}"
          })

          assert_receive {event_tag,
                          %{"type" => "bridge_test_connect", "generation" => first_generation}},
                         2_000

          assert event_tag == bridge.event_tag

          assert_receive {event_tag, %{"type" => "error", "message" => exit_message}},
                         4_000

          assert event_tag == bridge.event_tag
          assert exit_message == "#{bridge.label} bridge exited"

          assert_receive {event_tag,
                          %{
                            "type" => "bridge_test_connect",
                            "generation" => second_generation
                          }},
                         8_000

          assert event_tag == bridge.event_tag
          assert second_generation == first_generation + 1
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

  defp parser_fixture_script do
    """
    #!/usr/bin/env node
    import readline from "node:readline";

    const emit = (payload) => process.stdout.write(JSON.stringify(payload) + "\\n");
    const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

    rl.on("line", (line) => {
      const command = JSON.parse(line);
      process.stdout.write("not-json\\n");
      process.stdout.write("[]\\n");
      emit({ type: "bridge_contract", op: command.op, adapter: command.adapter });
    });
    """
  end

  defp restart_fixture_script(counter_path) do
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
    const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

    rl.on("line", (line) => {
      let command;

      try {
        command = JSON.parse(line);
      } catch (_error) {
        return;
      }

      if (command?.op === "connect") {
        emit({ type: "bridge_test_connect", generation });
        process.exit(0);
      }
    });
    """
  end
end
