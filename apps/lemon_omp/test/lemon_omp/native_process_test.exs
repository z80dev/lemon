defmodule LemonOmp.NativeProcessTest do
  use ExUnit.Case, async: false

  import LemonOmp.TestSupport
  alias LemonCore.{NativeProcess, ProcessGroup}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.fetch_env(:lemon_core, :native_process_ledger)
    :ok = NativeProcess.configure!(Path.join(dir, "native.dets"))
    ledger = Process.whereis(NativeProcess)

    on_exit(fn ->
      close_all_sessions()
      if Process.alive?(ledger), do: GenServer.stop(ledger)

      case previous do
        {:ok, value} -> Application.put_env(:lemon_core, :native_process_ledger, value)
        :error -> Application.delete_env(:lemon_core, :native_process_ledger)
      end
    end)

    use_fake_omp()
    executable = Path.join(dir, "omp")
    File.cp!(fake_omp(), executable)
    File.chmod!(executable, 0o755)
    put_app_env(:executable, executable)
    put_app_env(:session_dir, Path.join(dir, "sessions"))

    for key <- ~w(FAKE_OMP_MODELS_MODE FAKE_OMP_MODELS_COUNT LEMON_CATALOG_SECRET) do
      previous = System.get_env(key)
      System.delete_env(key)

      on_exit(fn ->
        if previous, do: System.put_env(key, previous), else: System.delete_env(key)
      end)
    end

    :ok
  end

  test "managed registration and schema construction do not dispatch native work", %{tmp_dir: dir} do
    assert {:omp, LemonOmp.Tools.Omp, :managed} in LemonAgent.ToolRegistry.all()

    tool =
      LemonAgent.ToolRegistry.build_tool(:managed, fn ->
        LemonOmp.Tools.Omp.tool(dir, session_key: "agent:native-construction")
      end)

    assert tool.name == "omp"
    assert NativeProcess.snapshot() == []
    assert tool.execute.("invalid", %{"action" => "invalid"}, nil, nil).is_error
    assert NativeProcess.snapshot() == []
  end

  test "catalog launches are tracked and cached without unknown work" do
    assert {:ok, [_ | _]} = LemonOmp.models()
    rows = local_records()
    assert rows != []
    assert {:ok, [_ | _]} = LemonOmp.models()
    assert length(local_records()) == length(rows)
    assert_local_work_terminated()
  end

  test "catalog timeout tracks its kill helper and confirms the local work ended" do
    System.put_env("FAKE_OMP_MODELS_MODE", "timeout")
    put_app_env(:models_timeout_ms, 100)

    assert {:error, {:catalog_failed, message}} = LemonOmp.models()
    assert message =~ "timed out"
    assert length(local_records()) == 2
    assert_local_work_terminated()
  end

  test "status version probing is tracked without unknown work" do
    assert %{"available" => true, "version" => "omp 0.0.0-fake (test double)"} =
             LemonOmp.status()

    assert length(local_records()) == 1
    assert_local_work_terminated()
  end

  test "worktree validation, creation, discovery and cleanup track every git launch", %{
    tmp_dir: dir
  } do
    cwd = Path.join(dir, "repo")
    File.mkdir!(cwd)
    assert {_, 0} = System.cmd("git", ["-C", cwd, "init", "--quiet"])

    assert {_, 0} =
             System.cmd("git", [
               "-C",
               cwd,
               "-c",
               "user.name=Test",
               "-c",
               "user.email=test@example.invalid",
               "commit",
               "--quiet",
               "--allow-empty",
               "-m",
               "base"
             ])

    assert NativeProcess.snapshot() == []
    assert {:ok, repo} = LemonOmp.Worktree.validate(cwd, true)
    validated = length(local_records())
    assert validated == 4
    assert {:ok, worktree} = LemonOmp.Worktree.create(repo, "native-audit")
    created = length(local_records())
    assert created == validated + 2
    assert [found] = LemonOmp.Worktree.kept(cwd)
    assert found.path == worktree.path
    discovered = length(local_records())
    assert discovered == created + 6

    assert %{"kept" => false, "dirty" => 0, "commits" => 0} =
             LemonOmp.Worktree.cleanup(worktree)

    assert length(local_records()) == discovered + 4
    refute File.exists?(worktree.path)
    assert_local_work_terminated()
  end

  test "local delegate ownership does not attest termination of delegate tools" do
    workspace = workspace!()
    assert {:error, :invalid_prompt} = LemonOmp.start(%{cwd: workspace})
    assert NativeProcess.snapshot() == []
    assert {:ok, wire} = LemonOmp.start(%{cwd: workspace, prompt: "offline test"})
    assert {:ok, _, :settled} = LemonOmp.wait(wire["id"], 10_000)

    rows = NativeProcess.snapshot()

    assert [{_, %{workload_identity: identity}, _}] =
             Enum.filter(rows, fn {_, record, _} -> record.backend == :local end)

    assert ProcessGroup.valid_identity?(identity)

    assert [{id, %{backend: :unsupported, capacity_held: true}, %{}}] =
             Enum.filter(rows, fn {_, record, _} -> record.backend == :unsupported end)

    assert {:ok, _} = LemonOmp.close(wire["id"])

    assert Enum.any?(NativeProcess.snapshot(), fn {row_id, record, _} ->
             row_id == id and record.capacity_held and not record.termination_confirmed
           end)
  end

  test "delegate shutdown tracks liveness, descendant discovery and signal helpers" do
    workspace = workspace!("ignore-term")
    assert {:ok, wire} = LemonOmp.start(%{cwd: workspace, prompt: "HOLD"})
    root = fake_pid(workspace)
    child = fake_pid(workspace, ".fake_omp.child")
    kill_on_exit([root, child])
    assert [{_, %{workload_identity: identity}, _}] = local_records()
    assert identity.root_pid == root
    assert {:alive, observed} = ProcessGroup.workload_group_status(identity)
    assert Map.has_key?(observed.members, child)
    session = session_pid(wire["id"])

    assert {:ok, _} = LemonOmp.close(wire["id"])
    refute Process.alive?(session)
    wait_until(fn -> ProcessGroup.workload_group_status(observed) == :terminated end)
    assert length(local_records()) > 3
    assert [{_, %{backend: :unsupported, capacity_held: true}, _}] = unsupported_records()

    wait_until(fn ->
      Enum.all?(local_records(), fn {_, record, _} -> record.termination_confirmed end)
    end)
  end

  defp local_records do
    Enum.filter(NativeProcess.snapshot(), fn {_, record, _} -> record.backend == :local end)
  end

  defp unsupported_records do
    Enum.filter(NativeProcess.snapshot(), fn {_, record, _} -> record.backend == :unsupported end)
  end

  defp assert_local_work_terminated do
    assert unsupported_records() == []

    wait_until(fn ->
      Enum.all?(local_records(), fn {_, record, _} ->
        ProcessGroup.valid_identity?(record.workload_identity) and
          record.termination_confirmed and not record.capacity_held
      end)
    end)
  end
end
