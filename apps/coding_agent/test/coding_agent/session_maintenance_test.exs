defmodule CodingAgent.SessionMaintenanceTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{
    Artifacts,
    Config,
    ControlPlaneProvider,
    SessionMaintenance
  }

  alias CodingAgent.Session.Ownership
  alias LemonCore.{AgentRuntime, SessionLifecycle, Store}

  @cutoff 1_700_000_000_000
  @old_seconds 1_600_000_000
  @table :session_maintenance_previews

  setup do
    root =
      Path.join(System.tmp_dir!(), "session-maintenance-#{System.unique_integer([:positive])}")

    cwd = Path.join(root, "workspace")
    File.mkdir_p!(cwd)
    previous_directory = System.get_env("LEMON_AGENT_DIR")
    previous_provider = Application.fetch_env(:lemon_core, :agent_runtime_provider)
    {:ok, retained} = Store.fetch_all(@table)
    Enum.each(retained, fn {key, _} -> :ok = Store.delete(@table, key) end)
    System.put_env("LEMON_AGENT_DIR", Path.join(root, "agent"))
    :ok = AgentRuntime.register(ControlPlaneProvider)

    if Process.whereis(CodingAgent.MutationLock) == nil do
      start_supervised!(CodingAgent.MutationLock)
    end

    on_exit(fn ->
      {:ok, current} = Store.fetch_all(@table)
      Enum.each(current, fn {key, _} -> :ok = Store.delete(@table, key) end)
      Enum.each(retained, fn {key, value} -> :ok = Store.put(@table, key, value) end)

      case previous_directory do
        nil -> System.delete_env("LEMON_AGENT_DIR")
        value -> System.put_env("LEMON_AGENT_DIR", value)
      end

      case previous_provider do
        {:ok, value} -> Application.put_env(:lemon_core, :agent_runtime_provider, value)
        :error -> Application.delete_env(:lemon_core, :agent_runtime_provider)
      end

      File.rm_rf!(root)
    end)

    %{root: root, cwd: cwd}
  end

  test "concurrent startups share re-entrant root admission" do
    parent = self()

    tasks =
      for _ <- 1..32 do
        Task.async(fn ->
          SessionMaintenance.with_root_lock(fn ->
            SessionMaintenance.with_root_lock(fn ->
              send(parent, {:admitted, self()})

              receive do
                :finish -> :ok
              end
            end)
          end)
        end)
      end

    # All startups must enter before any can leave. An exclusive root lock
    # serializes whole Session.init calls and starves later callers.
    for _ <- tasks do
      assert_receive {:admitted, _pid}, 5_000
    end

    Enum.each(tasks, &send(&1.pid, :finish))
    assert Enum.map(tasks, &Task.await/1) == List.duplicate(:ok, 32)
  end

  test "a dead startup owner releases root admission to maintenance" do
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        SessionMaintenance.with_root_lock(fn ->
          send(parent, :startup_admitted)

          receive do
            :finish -> :ok
          end
        end)
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    assert_receive :startup_admitted

    task =
      Task.async(fn ->
        SessionMaintenance.with_root_lock(
          fn ->
            send(parent, :maintenance_admitted)
            :ok
          end,
          :exclusive
        )
      end)

    refute_receive :maintenance_admitted
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert Task.await(task) == :ok
    assert_receive :maintenance_admitted
  end

  test "shared admission refuses an unsafe upgrade to exclusive maintenance" do
    assert SessionMaintenance.with_root_lock(fn ->
             SessionMaintenance.with_root_lock(
               fn -> flunk("upgraded shared lock") end,
               :exclusive
             )
           end) == {:error, :lock_upgrade}
  end

  test "a dry run takes no root admission, so it never blocks startup or artifact spill", %{
    cwd: cwd
  } do
    journal(cwd, "cold")
    {:ok, _} = Artifacts.spill("orphaned output", cwd, session_id: "orphan")
    parent = self()

    # A startup or spill writer still inside shared admission.
    {holder, monitor} =
      spawn_monitor(fn ->
        SessionMaintenance.with_root_lock(fn ->
          send(parent, :admitted)

          receive do
            :stop -> :ok
          end
        end)
      end)

    cleanup_owner_on_exit(holder)
    assert_receive :admitted, 5_000

    :erlang.trace_pattern({:global, :trans, :_}, true, [])
    :erlang.trace(self(), true, [:call])

    try do
      assert {:ok, report} = preview()
      assert report.archive_count == 1
      assert report.orphan_count == 1
    after
      :erlang.trace(self(), false, [:call])
      :erlang.trace_pattern({:global, :trans, :_}, false, [])
    end

    root_locks =
      for {:trace, _, :call, {:global, :trans, [{{SessionMaintenance, _root}, _}, _ | _]}} <-
            drain_traces(),
          do: :root_lock

    assert root_locks == []

    # Spills and startups admitted while maintenance only previews.
    assert {:ok, _} = Artifacts.spill("written during preview", cwd, session_id: "warm")
    send(holder, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}, 5_000
  end

  test "preview does not write journals or archive directories", %{cwd: cwd} do
    path = journal(cwd, "cold")
    before = File.read!(path)
    names = File.ls!(Config.sessions_dir(cwd))
    stat = File.stat!(path)

    assert {:ok, report} = preview()
    assert report.archive_count == 1
    assert report.orphan_count == 0
    assert report.archived_count == 0
    refute report.verified
    assert File.read!(path) == before
    assert File.stat!(path).mtime == stat.mtime
    assert File.ls!(Config.sessions_dir(cwd)) == names
    refute File.exists?(Path.join(Config.sessions_dir(cwd), "archive"))
    refute inspect(report) =~ cwd
  end

  test "archives cold journals and retains archived artifacts", %{
    cwd: cwd
  } do
    path = journal(cwd, "cold")
    {:ok, uri} = Artifacts.spill("keep archived output", cwd, session_id: "cold")
    {:ok, original_artifact} = Artifacts.resolve(uri, cwd, session_id: "cold")
    assert {:ok, report} = preview()
    assert {:ok, executed} = execute(report)
    assert executed.archived_count == 1
    assert executed.swept_count == 0
    assert executed.verified
    refute File.exists?(path)
    assert File.regular?(Path.join([Config.sessions_dir(cwd), "archive", "cold.jsonl"]))
    assert {:ok, ^original_artifact} = Artifacts.resolve(uri, cwd, session_id: "cold")
    assert {:ok, next} = preview()
    assert next.archive_count == 0
    assert next.orphan_count == 0
  end

  test "sweeps orphan spill directories but never an indexed external target", %{
    cwd: cwd,
    root: root
  } do
    external = Path.join(root, "external.txt")
    File.write!(external, "must survive")
    {:ok, _} = Artifacts.spill("discard", cwd, session_id: "orphan")
    {:ok, _} = Artifacts.register(external, cwd, session_id: "orphan")
    journal(cwd, "warm", @cutoff + 10_000)
    {:ok, _} = Artifacts.spill("keep live journal output", cwd, session_id: "warm")

    assert {:ok, report} = preview()
    assert report.archive_count == 0
    assert report.orphan_count == 1
    assert {:ok, executed} = execute(report)
    assert executed.swept_count == 1
    refute File.exists?(Config.spill_dir(cwd, "orphan"))
    assert File.dir?(Config.spill_dir(cwd, "warm"))
    assert File.read!(external) == "must survive"
  end

  test "changed bytes with restored mtime invalidate and consume confirmation", %{cwd: cwd} do
    path = journal(cwd, "cold")
    assert {:ok, report} = preview()
    contents = File.read!(path)
    File.write!(path, String.replace(contents, "cold", "bold"))
    File.touch!(path, @old_seconds)
    assert {:error, :confirmation_mismatch} = execute(report)
    assert File.regular?(path)
    assert {:error, :confirmation_mismatch} = execute(report)
  end

  test "new candidates and newly created artifacts invalidate the complete plan", %{cwd: cwd} do
    journal(cwd, "cold")
    assert {:ok, report} = preview()
    journal(cwd, "new-cold")
    assert {:error, :confirmation_mismatch} = execute(report)

    assert {:ok, report} = preview()
    {:ok, _} = Artifacts.spill("new orphan", cwd, session_id: "orphan")
    assert {:error, :confirmation_mismatch} = execute(report)

    assert {:ok, report} = preview()
    {:ok, _} = Artifacts.spill("another file", cwd, session_id: "orphan")
    assert {:error, :confirmation_mismatch} = execute(report)
    assert File.regular?(Path.join(Config.sessions_dir(cwd), "cold.jsonl"))
  end

  # Files a run would not mutate are bound by stat fingerprint (size, inode,
  # mtime, ctime, mode, links); only candidates are content-hashed.
  test "changed retained artifacts also invalidate archive confirmation", %{cwd: cwd} do
    journal(cwd, "cold")
    {:ok, uri} = Artifacts.spill("original", cwd, session_id: "cold")
    {:ok, artifact} = Artifacts.resolve(uri, cwd, session_id: "cold")
    assert {:ok, report} = preview()
    File.write!(artifact, "modified retained output")
    assert {:error, :confirmation_mismatch} = execute(report)
  end

  test "symlinked journals, spill children, archive roots and workspace roots fail closed",
       context do
    %{cwd: cwd, root: root} = context
    external = Path.join(root, "external")
    File.mkdir_p!(external)
    external_file = Path.join(external, "retain.txt")
    File.write!(external_file, "retain")
    path = journal(cwd, "cold")
    File.rm!(path)
    File.ln_s!(external_file, path)
    assert {:error, :maintenance_unavailable} = preview()
    File.rm!(path)

    journal(cwd, "cold")
    spill = Config.spill_dir(cwd, "orphan")
    File.mkdir_p!(spill)
    link = Path.join(spill, "escape")
    File.ln_s!(external, link)
    assert {:error, :maintenance_unavailable} = preview()
    File.rm!(link)

    archive = Path.join(Config.sessions_dir(cwd), "archive")
    File.ln_s!(external, archive)
    assert {:error, :maintenance_unavailable} = preview()
    File.rm!(archive)

    directory = Config.sessions_dir(cwd)
    moved = directory <> "-saved"
    File.rename!(directory, moved)
    File.ln_s!(external, directory)
    assert {:error, :maintenance_unavailable} = preview()
    File.rm!(directory)
    File.rename!(moved, directory)
    assert File.read!(external_file) == "retain"
  end

  test "a symlink introduced after preview is rejected without following it", %{
    cwd: cwd,
    root: root
  } do
    journal(cwd, "cold")
    assert {:ok, report} = preview()
    external = Path.join(root, "outside")
    File.mkdir_p!(external)
    File.ln_s!(external, Path.join(Config.sessions_dir(cwd), "archive"))
    assert {:error, _} = execute(report)
    assert File.ls!(external) == []
    assert File.regular?(Path.join(Config.sessions_dir(cwd), "cold.jsonl"))
  end

  test "unregistered live owners exclude their journals and artifacts", %{cwd: cwd} do
    path = journal(cwd, "unregistered")
    {:ok, _} = Artifacts.spill("retain", cwd, session_id: "unregistered")
    {pid, monitor} = own(path)

    try do
      assert {:ok, report} = preview()
      assert report.archive_count == 0
      assert report.orphan_count == 0
      assert {:ok, %{verified: true}} = execute(report)
      assert File.regular?(path)
    after
      stop_owner(pid, monitor)
    end
  end

  test "an owner arriving after preview invalidates the archive plan", %{cwd: cwd} do
    path = journal(cwd, "late-owner")
    assert {:ok, report} = preview()
    {pid, monitor} = own(path)

    try do
      assert {:error, :confirmation_mismatch} = execute(report)
      assert File.regular?(path)
    after
      stop_owner(pid, monitor)
    end
  end

  test "journal-less startup admission protects its spills before the journal exists", %{
    cwd: cwd
  } do
    {:ok, _} = Artifacts.spill("retain", cwd, session_id: "starting")
    assert {:ok, %{orphan_count: 1} = before_startup} = preview()
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, _opts, _path} = Ownership.admit(cwd: cwd, session_id: "starting")
        send(parent, :startup_admitted)

        receive do
          :stop -> :ok
        end
      end)

    cleanup_owner_on_exit(pid)
    assert_receive :startup_admitted, 5_000

    try do
      assert {:ok, report} = preview()
      assert report.orphan_count == 0
      assert {:error, :confirmation_mismatch} = execute(before_startup)
      assert File.dir?(Config.spill_dir(cwd, "starting"))
    after
      stop_owner(pid, monitor)
    end
  end

  test "artifact writers and maintenance share admission and bind the completed write", %{
    cwd: cwd
  } do
    {:ok, _} = Artifacts.spill("first", cwd, session_id: "orphan")
    assert {:ok, preview} = preview()
    parent = self()

    writer =
      Task.async(fn ->
        SessionMaintenance.with_root_lock(fn ->
          send(parent, :writer_admitted)

          receive do
            :write -> Artifacts.spill("second", cwd, session_id: "orphan")
          end
        end)
      end)

    assert_receive :writer_admitted, 5_000

    executor =
      Task.async(fn ->
        send(parent, :execution_started)
        execute(preview)
      end)

    assert_receive :execution_started, 5_000
    send(writer.pid, :write)
    assert {:ok, _} = Task.await(writer)
    assert {:error, :confirmation_mismatch} = Task.await(executor)
    assert File.dir?(Config.spill_dir(cwd, "orphan"))
  end

  test "a failed mutation stops the pass without retrying or sweeping later candidates", %{
    cwd: cwd
  } do
    journal(cwd, "cold")
    {:ok, _} = Artifacts.spill("undeletable", cwd, session_id: "orphan-a")
    {:ok, _} = Artifacts.spill("retain on failure", cwd, session_id: "orphan-b")
    locked = Config.spill_dir(cwd, "orphan-a")
    File.chmod!(locked, 0o500)
    on_exit(fn -> File.chmod(locked, 0o700) end)
    assert {:ok, plan} = SessionMaintenance.plan(@cutoff)
    assert Enum.map(plan.candidates, & &1.kind) == [:archive, :orphan_artifact, :orphan_artifact]

    assert {:error, {:partial_failure, report}} = SessionMaintenance.execute(plan)
    refute report.verified
    assert report.archived_count == 1
    assert report.swept_count == 0
    assert File.ls!(locked) != []
    assert File.dir?(Config.spill_dir(cwd, "orphan-b"))
    assert File.regular?(Path.join([Config.sessions_dir(cwd), "archive", "cold.jsonl"]))
  end

  test "corrupt journals cannot turn retained spill directories into orphans", %{cwd: cwd} do
    path = journal(cwd, "damaged")
    {:ok, _} = Artifacts.spill("retain", cwd, session_id: "damaged")
    File.write!(path, "not a journal\n")
    assert {:error, :maintenance_unavailable} = preview()
    assert File.dir?(Config.spill_dir(cwd, "damaged"))
  end

  test "missing roots preview empty without creating directories", %{root: root} do
    assert {:ok, report} = preview()
    assert report.archive_count == 0
    assert report.orphan_count == 0
    refute File.exists?(Path.join(root, "agent"))
    assert {:ok, %{verified: true}} = execute(report)
    refute File.exists?(Path.join(root, "agent"))
  end

  test "archive collisions preserve both journal versions and their artifacts", %{cwd: cwd} do
    path = journal(cwd, "same-id")
    archive = Path.join([Config.sessions_dir(cwd), "archive", "same-id.jsonl"])
    File.mkdir_p!(Path.dirname(archive))
    File.cp!(path, archive)
    File.write!(path, File.read!(path) <> Jason.encode!(%{type: "custom", id: "new"}) <> "\n")
    File.touch!(path, @old_seconds)
    {:ok, _} = Artifacts.spill("retain both", cwd, session_id: "same-id")
    assert {:ok, report} = preview()
    assert report.archive_count == 0
    assert report.orphan_count == 0
    assert {:ok, %{verified: true}} = execute(report)
    refute File.read!(path) == File.read!(archive)
  end

  defp journal(cwd, id, timestamp \\ @old_seconds * 1000) do
    directory = Config.sessions_dir(cwd)
    File.mkdir_p!(directory)
    path = Path.join(directory, id <> ".jsonl")

    header = %{
      type: "session",
      version: 3,
      id: id,
      cwd: cwd,
      timestamp: timestamp |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601()
    }

    File.write!(path, Jason.encode!(header) <> "\n")
    File.touch!(path, div(timestamp, 1000))
    path
  end

  defp own(path) do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        Ownership.with_file(path, fn -> :ok = Ownership.publish(path) end)
        send(parent, {:owned, self()})

        receive do
          :stop -> :ok
        end
      end)

    cleanup_owner_on_exit(pid)
    assert_receive {:owned, ^pid}, 5_000
    {pid, monitor}
  end

  defp stop_owner(pid, monitor) do
    send(pid, :stop)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
  end

  defp cleanup_owner_on_exit(pid) do
    on_exit(fn ->
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 5_000
    end)
  end

  defp drain_traces(acc \\ []) do
    receive do
      {:trace, _, :call, _} = trace -> drain_traces([trace | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp preview, do: SessionLifecycle.maintenance(older_than_ms: @cutoff)

  defp execute(report) do
    SessionLifecycle.maintenance(
      older_than_ms: @cutoff,
      dry_run: false,
      confirm_token: report.confirmation_token
    )
  end
end
