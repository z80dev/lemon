defmodule LemonCore.ProcessGroupTest do
  use ExUnit.Case, async: false

  alias LemonCore.ProcessGroup

  test "termination telemetry contains only bounded classifications" do
    handler = {__MODULE__, make_ref()}
    events = Enum.map([:start, :stop, :failure], &[:lemon, :process_group, &1])
    parent = self()

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

    assert :ok =
             ProcessGroup.terminate(2,
               scope: :process,
               command: fn _, _ -> {"secret command output", 0} end
             )

    assert_receive {:telemetry, [:lemon, :process_group, :start], %{count: 1}, %{scope: :process}}

    assert_receive {:telemetry, [:lemon, :process_group, :stop], %{count: 1, duration: duration},
                    %{scope: :process, outcome: :signaled}}

    assert is_integer(duration) and duration >= 0
    identity = %{secret: "private path and environment"}
    assert {:error, :workload_unobservable, ^identity} = ProcessGroup.terminate(identity)
    assert_receive {:telemetry, [:lemon, :process_group, :start], _, %{scope: :group}}

    assert_receive {:telemetry, [:lemon, :process_group, :failure], _,
                    %{scope: :group, outcome: :unobservable} = metadata}

    assert map_size(metadata) == 2
  end

  test "malformed, missing and lost ownership never establish termination or authorize signals" do
    base = %{
      pgid: 2,
      root_pid: 2,
      root_birth: "birth",
      members: %{2 => "birth"},
      ownership_lost: false
    }

    invalid = [
      nil,
      %{},
      Map.delete(base, :members),
      %{base | pgid: 1},
      %{base | root_pid: 3},
      %{base | root_birth: ""},
      %{base | members: %{}},
      %{base | members: %{2 => "different"}},
      %{base | members: %{3 => ""}},
      %{base | members: %{0 => "birth"}},
      %{base | ownership_lost: true}
    ]

    for identity <- invalid do
      refute ProcessGroup.valid_identity?(identity)
      assert {:unknown, ^identity} = ProcessGroup.workload_group_status(identity)
      assert {:unknown, ^identity} = ProcessGroup.workload_group_status(identity, true)

      assert {:error, :workload_unobservable, ^identity} =
               ProcessGroup.terminate(identity, signal: :sigterm)

      assert {:error, :workload_unobservable, ^identity} =
               ProcessGroup.terminate(identity, signal: :sigkill, root_exited: true)
    end

    identities =
      invalid |> Enum.with_index() |> Map.new(fn {identity, index} -> {index, identity} end)

    assert ProcessGroup.workload_group_statuses(identities) ==
             Map.new(identities, fn {id, identity} -> {id, {:unknown, identity}} end)

    assert ProcessGroup.workload_group_statuses(%{}) == %{}

    for pid <- [nil, -1, 0, 1, "123"] do
      assert {:error, :workload_unobservable} = ProcessGroup.capture_workload_group(pid)
    end
  end

  test "a real captured group is alive, birth-bound, signalled and proven terminated" do
    {port, identity} = gated_group()
    assert ProcessGroup.valid_identity?(identity)
    assert identity.root_pid == identity.pgid
    assert identity.members[identity.root_pid] == identity.root_birth
    assert {:alive, observed} = ProcessGroup.workload_group_status(identity)
    assert {:alive, _} = ProcessGroup.workload_group_statuses(%{workload: observed}).workload

    recycled = %{
      identity
      | root_birth: identity.root_birth <> "-other",
        members: %{identity.root_pid => identity.root_birth <> "-other"}
    }

    assert ProcessGroup.valid_identity?(recycled)

    assert {:unknown, %{ownership_lost: true} = lost} =
             ProcessGroup.workload_group_status(recycled)

    assert {:error, :workload_unobservable, _} =
             ProcessGroup.terminate(recycled, signal: :sigkill)

    assert {:error, :workload_unobservable, ^lost} =
             ProcessGroup.terminate(lost, signal: :sigkill)

    assert {:unknown, %{ownership_lost: true}} =
             ProcessGroup.workload_group_status(identity, true)

    assert {:error, :workload_unobservable, %{ownership_lost: true}} =
             ProcessGroup.terminate(identity, signal: :sigkill, root_exited: true)

    assert {:alive, _} = ProcessGroup.workload_group_status(identity)

    assert {:terminated, _} = ProcessGroup.terminate(identity)
    assert_receive {^port, {:exit_status, _}}, 5_000
    eventually(fn -> ProcessGroup.workload_group_status(identity) == :terminated end)
    assert {:terminated, ^identity} = ProcessGroup.terminate(identity, signal: :sigkill)
  end

  test "group signalling ignores a PATH-shadowed kill executable" do
    directory =
      Path.join(System.tmp_dir!(), "lemon-group-path-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    executable = Path.join(directory, "kill")
    marker = Path.join(directory, "shadow-used")
    File.write!(executable, "#!/bin/sh\nprintf shadow > \"$0.used\"\nexit 0\n")
    File.chmod!(executable, 0o700)
    original = System.get_env("PATH")

    on_exit(fn ->
      if original, do: System.put_env("PATH", original), else: System.delete_env("PATH")
      File.rm_rf!(directory)
    end)

    {port, identity} = gated_group()
    System.put_env("PATH", directory)
    assert {:terminated, _} = ProcessGroup.terminate(identity, signal: :sigkill)
    assert_receive {^port, {:exit_status, _}}, 5_000
    eventually(fn -> ProcessGroup.workload_group_status(identity) == :terminated end)
    refute File.exists?(executable <> ".used")
    refute File.exists?(marker)
  end

  test "TERM escalates for a resistant group without touching another owned group" do
    {port, identity} = gated_group("trap '' TERM; printf ready; IFS= read -r lemon_gate")
    {_sentinel_port, sentinel} = gated_group()
    assert_receive {^port, {:data, "ready"}}, 5_000
    parent = self()

    before_signal = fn observed ->
      send(parent, {:before_signal, observed})
      :ok
    end

    assert {:terminated, _} =
             ProcessGroup.terminate(identity, grace_ms: 0, before_signal: before_signal)

    assert_receive {:before_signal, %{root_pid: root_pid}}
    assert root_pid == identity.root_pid
    assert_receive {:before_signal, %{root_pid: ^root_pid}}
    assert_receive {^port, {:exit_status, _}}, 5_000
    assert :terminated = ProcessGroup.workload_group_status(identity)
    assert {:alive, _} = ProcessGroup.workload_group_status(sentinel)
  end

  test "a failed durability barrier prevents both TERM and KILL" do
    {port, identity} = gated_group()
    parent = self()

    for signal <- [:sigterm, :sigkill] do
      before_signal = fn observed ->
        send(parent, {:before_signal, observed})
        {:error, :sync_failed}
      end

      assert {:error, :workload_unobservable, observed} =
               ProcessGroup.terminate(identity, signal: signal, before_signal: before_signal)

      assert_receive {:before_signal, ^observed}
      assert {:alive, _} = ProcessGroup.workload_group_status(identity)
      refute_receive {^port, {:exit_status, _}}, 0
    end
  end

  test "single-process service scope delegates one TERM without group escalation" do
    parent = self()

    command = fn executable, args ->
      send(parent, {:command, executable, args})
      {"", 0}
    end

    assert :ok = ProcessGroup.terminate(123, scope: :process, command: command)
    assert_receive {:command, "/bin/kill", ["-TERM", "123"]}
    refute_received {:command, _, _}

    assert :error =
             ProcessGroup.terminate(123, scope: :process, command: fn _, _ -> {"denied", 1} end)
  end

  defp gated_group(script \\ "IFS= read -r lemon_gate") do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        args: ["-c", script]
      ])

    {:os_pid, pid} = Port.info(port, :os_pid)

    on_exit(fn ->
      # This fixture owns the port and its stdin-blocked shell, with no descendants.
      if Port.info(port), do: Port.close(port)
    end)

    assert {:ok, identity} = ProcessGroup.capture_workload_group(pid)
    {port, identity}
  end

  defp eventually(predicate, attempts \\ 100)
  defp eventually(predicate, 0), do: assert(predicate.())

  defp eventually(predicate, attempts) do
    if predicate.() do
      :ok
    else
      Process.sleep(20)
      eventually(predicate, attempts - 1)
    end
  end
end
