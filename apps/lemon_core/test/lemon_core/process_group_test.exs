defmodule LemonCore.ProcessGroupTest do
  use ExUnit.Case, async: false

  alias LemonCore.ProcessGroup

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
               ProcessGroup.signal_workload_group(identity, :sigterm)

      assert {:error, :workload_unobservable, ^identity} =
               ProcessGroup.signal_workload_group(identity, :sigkill, true)
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
             ProcessGroup.signal_workload_group(recycled, :sigkill)

    assert {:error, :workload_unobservable, ^lost} =
             ProcessGroup.signal_workload_group(lost, :sigkill)

    assert {:unknown, %{ownership_lost: true}} =
             ProcessGroup.workload_group_status(identity, true)

    assert {:alive, _} = ProcessGroup.workload_group_status(identity)

    assert {:ok, _} = ProcessGroup.signal_workload_group(identity, :sigterm)
    assert_receive {^port, {:exit_status, _}}, 5_000
    eventually(fn -> ProcessGroup.workload_group_status(identity) == :terminated end)
    assert {:terminated, ^identity} = ProcessGroup.signal_workload_group(identity, :sigkill)
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
    assert {:ok, _} = ProcessGroup.signal_workload_group(identity, :sigkill)
    assert_receive {^port, {:exit_status, _}}, 5_000
    eventually(fn -> ProcessGroup.workload_group_status(identity) == :terminated end)
    refute File.exists?(executable <> ".used")
    refute File.exists?(marker)
  end

  defp gated_group do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        args: ["-c", "IFS= read -r lemon_gate"]
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
