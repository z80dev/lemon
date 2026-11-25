defmodule LemonCore.Service.IdentityTest do
  use ExUnit.Case, async: true

  alias LemonCore.LoopbackListener
  alias LemonCore.Service.{Identity, Lock}

  @moduletag :tmp_dir

  test "lock acquires after boot run no ps or id", %{tmp_dir: dir} do
    assert {:ok, identity} = Identity.self_identity()
    assert identity.pid == String.to_integer(System.pid())
    calls = :counters.new(1, [:atomics])

    runner = fn command, args, _opts ->
      :counters.add(calls, 1, 1)
      System.cmd(command, args)
    end

    for n <- 1..25 do
      path = Path.join(dir, "state-#{rem(n, 3)}.lock")
      assert ^n = Lock.with_lock_path(path, [command_runner: runner], fn -> n end)
    end

    assert {:ok, ^identity} = Identity.self_identity()
    assert Identity.uid(command_runner: runner) == String.trim(elem(System.cmd("id", ["-u"]), 0))

    assert :unverifiable =
             LoopbackListener.owned_by_self?({{127, 0, 0, 1}, 4044},
               os_type: {:win32, :nt},
               command_runner: runner
             )

    assert :counters.get(calls, 1) == 0
  end

  test "the effective uid is captured once and shared with loopback inspection" do
    {id, 0} = System.cmd("id", ["-u"])
    assert {:ok, uid} = Identity.current_uid()
    assert Integer.to_string(uid) == String.trim(id)
    assert Identity.uid([]) == String.trim(id)
  end

  test "Linux /proc identity is read without forking", %{tmp_dir: root} do
    btime = 1_794_000_000
    hz = 250
    start_ticks = 123_456
    pid = String.to_integer(System.pid())
    File.mkdir_p!(Path.join(root, "self"))
    File.write!(Path.join(root, "stat"), "cpu  1 2 3\nbtime #{btime}\nprocesses 9\n")

    fields = ["S" | Enum.map(4..21, &Integer.to_string/1)] ++ ["#{start_ticks}", "0", "0"]

    File.write!(
      Path.join([root, "self", "stat"]),
      "#{pid} (beam ) (smp) #{Enum.join(fields, " ")}\n"
    )

    File.write!(
      Path.join([root, "self", "auxv"]),
      <<6::native-64, 4096::native-64, 17::native-64, hz::native-64, 0::native-64, 0::native-64>>
    )

    File.ln_s!("/opt/lemon/erts/bin/beam.smp", Path.join([root, "self", "exe"]))

    assert {:ok, identity} =
             Identity.capture_self(
               os: :linux,
               proc_root: root,
               command_runner: fn _, _, _ -> flunk("must not fork") end
             )

    assert identity == %{
             pid: pid,
             started_at: local_ctime(btime + div(start_ticks, hz)),
             executable: "/opt/lemon/erts/bin/beam.smp"
           }
  end

  test "unreadable /proc falls back to ps and a failed probe is unverified", %{tmp_dir: root} do
    started = "Tue Nov 10 12:00:00 2026"
    {uid, 0} = System.cmd("id", ["-u"])

    ps = fn
      "ps", [_, _, "-o", "uid=,lstart=,comm="], _ -> {"#{String.trim(uid)} #{started} beam\n", 0}
      "readlink", _, _ -> {"/opt/lemon/bin/beam.smp\n", 0}
    end

    assert {:ok, %{started_at: ^started, executable: "/opt/lemon/bin/beam.smp"}} =
             Identity.capture_self(os: :linux, proc_root: root, command_runner: ps)

    assert {:error, :process_identity_unverified} =
             Identity.capture_self(os: :darwin, command_runner: fn _, _, _ -> {"", 1} end)
  end

  @tag :linux_only
  test "the /proc self identity equals the ps identity on Linux" do
    pid = String.to_integer(System.pid())

    for _ <- 1..20 do
      assert {:ok, proc} = Identity.capture_self(os: :linux)
      assert {:ok, ^proc} = Identity.capture(pid, os: :linux)
    end
  end

  defp local_ctime(seconds) do
    {:unix, os} = :os.type()

    args =
      if os == :linux,
        do: ["-d", "@#{seconds}", "+%a %b %e %H:%M:%S %Y"],
        else: ["-r", "#{seconds}", "+%a %b %e %H:%M:%S %Y"]

    {formatted, 0} = System.cmd("date", args, env: [{"LC_ALL", "C"}])
    Identity.normalize_time(formatted)
  end
end
