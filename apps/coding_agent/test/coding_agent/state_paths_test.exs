defmodule CodingAgent.StatePathsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias CodingAgent.StatePaths

  setup do
    root = Path.join(System.tmp_dir!(), "state-paths-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    keys = [:state_dir, :agent_dir]
    old = Map.new(keys, &{&1, Application.fetch_env(:coding_agent, &1)})
    Application.delete_env(:coding_agent, :state_dir)
    Application.put_env(:coding_agent, :agent_dir, root)

    on_exit(fn ->
      Enum.each(old, fn
        {key, {:ok, value}} -> Application.put_env(:coding_agent, key, value)
        {key, :error} -> Application.delete_env(:coding_agent, key)
      end)

      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "trimmed local names select a digest, not a path" do
    digest = :crypto.hash(:sha256, "a/b") |> Base.encode16(case: :lower)

    assert StatePaths.worker_root(" a/b ") ==
             Path.join([System.user_home!(), ".lemon", "nodes", "state", digest])

    assert_raise ArgumentError, fn -> StatePaths.worker_root(" ") end
  end

  test "state path override leaves agent resources shared", %{root: root} do
    Application.put_env(:coding_agent, :state_dir, Path.join(root, "worker"))
    assert StatePaths.dets_path("tasks.dets") == Path.join(root, "worker/tasks.dets")
    assert CodingAgent.Config.agent_dir() == root
  end

  test "same VM is reentrant and reused PID identity is reclaimed", %{root: root} do
    path = Path.join(root, "tasks.dets")
    assert {:ok, :state_paths_a} = StatePaths.open_dets(:state_paths_a, path)

    assert {:ok, :state_paths_b} =
             StatePaths.open_dets(:state_paths_b, Path.join(root, "run_graph.dets"))

    :dets.close(:state_paths_a)
    :dets.close(:state_paths_b)
    File.write!(Path.join(root, ".lemon-state.lock"), System.pid() <> "\nwrong birth")
    assert {:ok, :state_paths_a} = StatePaths.open_dets(:state_paths_a, path)
    :dets.close(:state_paths_a)
  end

  test "controller repair backs up original bytes and runs once", %{root: root} do
    path = Path.join(root, "tasks.dets")
    {:ok, table} = :dets.open_file(:state_paths_fixture, file: String.to_charlist(path))
    :dets.insert(table, {:record, 1})
    :dets.close(table)
    original = File.read!(path)
    assert :ok = StatePaths.prepare_default_layout()
    [backup] = Path.wildcard(Path.join(root, "backups/dets-layout-v1-*/tasks.dets"))
    assert File.read!(backup) == original
    assert File.exists?(Path.join(root, ".dets-layout-v1"))
    assert :ok = StatePaths.prepare_default_layout()
    assert [backup] == Path.wildcard(Path.join(root, "backups/dets-layout-v1-*/tasks.dets"))
  end

  test "worker role skips controller repair", %{root: root} do
    Application.put_env(:coding_agent, :state_dir, root)
    assert :ok = StatePaths.prepare_default_layout()
    refute File.exists?(Path.join(root, ".dets-layout-v1"))
  end

  test "CLI configures state before starting application" do
    parent = self()

    assert {:error, _} =
             CodingAgent.ExecutionNode.CLI.run(
               ["--name", "test", "--controller", "ws://localhost:12345/ws"],
               configure_state: fn name ->
                 send(parent, {:configured, name})
                 :ok
               end,
               ensure_all_started: fn :coding_agent ->
                 assert_received {:configured, "test"}
                 {:error, :deliberately_not_started}
               end
             )

    assert capture_io(fn ->
             assert {:error, "no worker status recorded for this name"} =
                      CodingAgent.ExecutionNode.CLI.run([
                        "status",
                        "--name",
                        "missing-#{System.unique_integer([:positive])}",
                        "--json"
                      ])
           end) == ""
  end

  test "backup failure does not mark migration complete", %{root: root} do
    File.write!(Path.join(root, "backups"), "not a directory")

    assert ExUnit.CaptureLog.capture_log(fn ->
             assert :ok = StatePaths.prepare_default_layout()
           end) =~ "DETS layout repair incomplete"

    refute File.exists?(Path.join(root, ".dets-layout-v1"))
  end

  @tag :subprocess
  test "all four stores preserve explicit and per-store precedence", %{root: root} do
    {:ok, peer, _} =
      :peer.start_link(%{
        connection: :standard_io,
        args: [~c"-pa" | :code.get_path()]
      })

    on_exit(fn -> :peer.stop(peer) end)
    for app <- [:elixir, :logger, :crypto], do: :peer.call(peer, Application, :ensure_all_started, [app])
    :ok = :peer.call(peer, Application, :put_env, [:coding_agent, :agent_dir, root])

    stores = [
      {CodingAgent.TaskStoreServer, :task_store_path, "tasks.dets"},
      {CodingAgent.ParentQuestionStoreServer, :parent_question_store_path,
       "parent_questions.dets"},
      {CodingAgent.RunGraphServer, :run_graph_path, "run_graph.dets"},
      {CodingAgent.ProcessStoreServer, :process_store_path, "processes.dets"}
    ]

    for {module, key, file} <- stores do
      for mode <- [:default, :role, :store, :explicit] do
        role = Path.join(root, "role")
        store = Path.join(root, "store-#{file}")
        explicit = Path.join(root, "explicit-#{file}")

        if mode != :default,
          do: :peer.call(peer, Application, :put_env, [:coding_agent, :state_dir, role])

        if mode in [:store, :explicit],
          do: :peer.call(peer, Application, :put_env, [:coding_agent, key, store])

        opts = if mode == :explicit, do: [dets_path: explicit], else: []

        expected =
          case mode do
            :default -> Path.join(root, file)
            :role -> Path.join(role, file)
            :store -> store
            :explicit -> explicit
          end

        {:ok, server} = :peer.call(peer, GenServer, :start, [module, opts])
        assert :peer.call(peer, :sys, :get_state, [server]).dets_path == expected
        :ok = :peer.call(peer, GenServer, :stop, [server])
      end

      :peer.call(peer, Application, :delete_env, [:coding_agent, key])
      :peer.call(peer, Application, :delete_env, [:coding_agent, :state_dir])
    end
  end

  @tag :subprocess
  test "status is private, redacted and readable as human or JSON without a network", %{
    root: root
  } do
    {:ok, peer, _} =
      :peer.start_link(%{
        connection: :standard_io,
        args: [~c"-env", ~c"HOME", String.to_charlist(root), ~c"-pa" | :code.get_path()]
      })

    on_exit(fn -> :peer.stop(peer) end)
    for app <- [:elixir, :logger, :crypto], do: :peer.call(peer, Application, :ensure_all_started, [app])
    :ok = :peer.call(peer, ExUnit, :start, [[autorun: false]])

    status = %{
      "state" => "needs_enrollment",
      "reason" => "credential_missing",
      "nodeId" => nil,
      "changedAtMs" => 0
    }

    assert :ok = :peer.call(peer, StatePaths, :write_status, ["fixture", status])
    assert {:ok, saved} = :peer.call(peer, StatePaths, :read_status, ["fixture"])
    assert saved["version"] == 1
    assert saved["localName"] == "fixture"
    assert saved["osPid"] > 0
    assert saved["osPid"] != String.to_integer(System.pid())

    {output, _} =
      :peer.call(peer, Code, :eval_string, [
        """
        ExUnit.CaptureIO.capture_io(fn ->
          :ok = CodingAgent.ExecutionNode.CLI.run(["status", "--name", "fixture", "--json"])
        end)
        """
      ])

    assert Jason.decode!(output) == saved

    {human, _} =
      :peer.call(peer, Code, :eval_string, [
        """
        ExUnit.CaptureIO.capture_io(fn ->
          :ok = CodingAgent.ExecutionNode.CLI.run(["status", "--name", "fixture"])
        end)
        """
      ])

    assert human =~ "fixture: needs_enrollment (credential_missing) since 1970-01-01"
    path = :peer.call(peer, StatePaths, :status_path, ["fixture"])
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    File.write!(path, "{}")
    assert {:error, :invalid} = :peer.call(peer, StatePaths, :read_status, ["fixture"])
  end

  @tag :subprocess
  test "two VMs write separate files without orphaning controller writes", %{root: root} do
    # :peer's standard-IO transport does not require a distributed test VM.
    {:ok, peer, _} =
      :peer.start_link(%{connection: :standard_io, args: [~c"-pa" | :code.get_path()]})

    on_exit(fn -> :peer.stop(peer) end)
    for app <- [:elixir, :logger, :crypto], do: :peer.call(peer, Application, :ensure_all_started, [app])
    worker = Path.join(root, "worker")
    :ok = :peer.call(peer, Application, :put_env, [:coding_agent, :state_dir, worker])
    controller_path = StatePaths.dets_path("tasks.dets")
    {:ok, controller} = StatePaths.open_dets(:state_paths_controller, controller_path)

    assert {:error, {:state_dir_locked, _}} =
             :peer.call(peer, StatePaths, :open_dets, [:foreign_controller, controller_path])

    try do
      :dets.insert(controller, {:before, true})

      {owner, _} =
        :peer.call(peer, Code, :eval_string, [
          """
          parent = self()
          owner = spawn(fn ->
            {:ok, table} = CodingAgent.StatePaths.open_dets(:state_paths_worker, #{inspect(Path.join(worker, "tasks.dets"))})
            :ok = :dets.insert(table, {:worker, true})
            send(parent, {:ready, self()})
            receive do
              {:close, caller} ->
                :ok = :dets.close(table)
                send(caller, :closed)
            end
          end)
          receive do: ({:ready, ^owner} -> owner)
          """
        ])

      for n <- 1..100, do: :dets.insert(controller, {n, n})

      assert {:closed, _} =
               :peer.call(peer, Code, :eval_string, [
                 "send(owner, {:close, self()}); receive do: (:closed -> :closed)",
                 [owner: owner]
               ])

      assert File.stat!(controller_path).inode !=
               File.stat!(Path.join(worker, "tasks.dets")).inode
    after
      :dets.close(controller)
    end

    {:ok, table} = StatePaths.open_dets(:state_paths_controller, controller_path)

    try do
      for n <- 1..100, do: assert(:dets.lookup(table, n) == [{n, n}])
      assert :dets.lookup(table, :worker) == []
    after
      :dets.close(table)
    end
  end
end
