defmodule CodingAgent.ProcessSessionOneshot586Test do
  use ExUnit.Case, async: false

  alias CodingAgent.ProcessSession

  setup do
    handler = {__MODULE__, make_ref()}
    parent = self()
    events = Enum.map([:start, :stop, :failure], &[:lemon, :process_session, &1])

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, measurements, metadata, _ ->
          send(parent, {:telemetry, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "startup failure telemetry omits caller supplied secrets" do
    assert {:stop, {:invalid_process_output_limit, :max_log_lines}} =
             ProcessSession.init(
               {"secret-process",
                [max_log_lines: 0, command: "secret", env: %{"KEY" => "secret"}]}
             )

    assert_receive {:telemetry, [:lemon, :process_session, :failure],
                    %{count: 1, duration: duration},
                    %{mode: :managed, outcome: :startup_failed} = metadata}

    assert is_integer(duration) and duration >= 0
    assert map_size(metadata) == 2
  end

  test "status redacts commands, paths, environment, output and arbitrary reasons" do
    secret = "secret-status-sentinel"

    status =
      ProcessSession.format_status(%{
        state: %{command: secret, cwd: secret, env: %{secret => secret}, partial_line: secret},
        message: {:write_stdin, secret},
        log: [secret],
        reason: {:failure, secret}
      })

    assert status == %{
             state: %{},
             message: :process_event,
             log: [],
             reason: :process_session_failed
           }

    refute inspect(status) =~ secret
  end

  test "one-shot owner relays output and exits after the root exit event" do
    shell = System.find_executable("sh") || "/bin/sh"

    {port, _os_pid, owner} =
      ProcessSession.start_oneshot(
        shell,
        [
          :binary,
          :exit_status,
          :use_stdio,
          :stderr_to_stdout,
          {:args, ["-c", "printf ready; read line; printf done"]}
        ]
      )

    monitor = Process.monitor(owner)
    on_exit(fn -> ProcessSession.stop_oneshot(owner) end)

    assert_receive {^port, {:data, "ready"}}, 5_000

    assert_receive {:telemetry, [:lemon, :process_session, :start],
                    %{count: 1, duration: start_duration},
                    %{mode: :oneshot, outcome: :running} = start_metadata}

    assert is_integer(start_duration) and start_duration >= 0
    assert map_size(start_metadata) == 2
    assert %{mode: :oneshot, owner: caller} = :sys.get_state(owner)
    assert caller == self()
    assert Port.command(port, "finish\n")
    assert_receive {^port, {:data, "done"}}, 5_000
    assert_receive {^port, {:exit_status, 0}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000

    assert_receive {:telemetry, [:lemon, :process_session, :stop],
                    %{count: 1, duration: duration},
                    %{mode: :oneshot, outcome: :stopped} = metadata}

    assert duration >= start_duration
    assert map_size(metadata) == 2
  end

  test "a killed caller cannot leave its one-shot workload running" do
    parent = self()

    caller =
      spawn(fn ->
        {port, os_pid, owner} =
          ProcessSession.start_oneshot(
            "/bin/sh",
            [
              :binary,
              :exit_status,
              :use_stdio,
              :stderr_to_stdout,
              {:args, ["-c", "printf ready; read line"]}
            ]
          )

        receive do
          {^port, {:data, "ready"}} -> send(parent, {:ready, owner, os_pid})
        end

        receive do
          :finish -> :ok
        end
      end)

    on_exit(fn -> Process.exit(caller, :kill) end)
    assert_receive {:ready, owner, os_pid}, 5_000
    monitor = Process.monitor(owner)
    {:ok, identity} = LemonCore.ProcessGroup.capture_workload_group(os_pid)
    on_exit(fn -> ProcessSession.stop_oneshot(owner) end)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}, 5_000
    assert :terminated = LemonCore.ProcessGroup.workload_group_status(identity, true)
  end

  test "workload reconciliation has no periodic scan timer" do
    source = File.read!(Path.expand("../lib/coding_agent/process_session.ex", __DIR__))
    refute source =~ ":reconcile_workload"
    refute source =~ ":kill_after_grace"
  end
end
