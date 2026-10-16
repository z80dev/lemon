defmodule LemonCore.ExecApprovalExpiryTest do
  use ExUnit.Case, async: false

  alias LemonCore.{ExecApprovalExpiry, ExecApprovals, ExecApprovalStore, Store}

  @moduletag :tmp_dir

  defmodule OwnerProvider do
    def native_session_owner(id), do: Process.whereis(String.to_existing_atom(id))
  end

  setup %{tmp_dir: tmp_dir} do
    original_config = Application.fetch_env!(:lemon_core, Store)
    original_runtime = ExecApprovalExpiry.runtime_id()

    stop_child(ExecApprovalExpiry)
    stop_child(Store)

    Application.put_env(:lemon_core, Store,
      backend: LemonCore.Store.SqliteBackend,
      backend_opts: [path: Path.join(tmp_dir, "approvals.sqlite3"), ephemeral_tables: [:runs]],
      finalize_run_hooks: [{ExecApprovalExpiry, :handle_finalize_run}]
    )

    restart_child(Store)
    restart_child(ExecApprovalExpiry)
    LemonCore.Bus.subscribe("exec_approvals")

    on_exit(fn ->
      stop_child(ExecApprovalExpiry)
      stop_child(Store)
      :persistent_term.put({ExecApprovalExpiry, :runtime_id}, original_runtime)
      Application.put_env(:lemon_core, Store, original_config)
      restart_child(Store)
      restart_child(ExecApprovalExpiry)
    end)

    :ok
  end

  test "SQLite recovery expires retained approvals from the dead runtime before resolution" do
    {task, id} = request("old-runtime")
    pending = ExecApprovalStore.get_pending(id)
    assert is_nil(pending.expires_at_ms)
    assert :ok = Store.put(:runs, pending.run_id, %{events: [], summary: nil})

    # The database survives; its ephemeral runs and all owning processes do not.
    stop_child(ExecApprovalExpiry)
    Task.shutdown(task, :brutal_kill)
    stop_child(Store)
    :persistent_term.put({ExecApprovalExpiry, :runtime_id}, "replacement-daemon")
    restart_child(Store)
    assert nil == Store.get(:runs, pending.run_id)
    assert %{id: ^id} = ExecApprovalStore.get_pending(id)

    # A resolver cannot act while runtime recovery has not completed.
    assert {:error, :store_unavailable} = ExecApprovals.resolve(id, :approve_global)
    restart_child(ExecApprovalExpiry)

    assert_expired(id)

    assert_receive %LemonCore.Event{
      type: :approval_resolved,
      payload: %{approval_id: ^id, decision: :expired}
    }
  end

  test "recovery also expires legacy pending records without incarnation evidence" do
    {task, id} = request("legacy-runtime")
    pending = ExecApprovalStore.get_pending(id) |> Map.delete(:owner_runtime_id)
    assert :ok = ExecApprovalStore.put_pending(id, pending)
    stop_child(ExecApprovalExpiry)
    restart_child(ExecApprovalExpiry)
    assert {:ok, :denied} = Task.await(task)
    assert_expired(id)
  end

  test "worker restart preserves a live session and restores its death monitor" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> Process.exit(owner, :kill) end)
    assert :ok = ExecApprovalExpiry.watch_session("live-session", owner)
    {task, id} = request("worker-restart", session_id: "live-session")

    before = ExecApprovalStore.get_pending(id)
    assert before.owner_session_pid == owner
    stop_child(ExecApprovalExpiry)
    restart_child(ExecApprovalExpiry)
    assert before == ExecApprovalStore.get_pending(id)
    assert Process.alive?(owner)

    Process.exit(owner, :kill)
    assert {:ok, :denied} = Task.await(task)
    assert_expired(id)
  end

  test "runtime provider supplies an owner without a core dependency on its registry" do
    previous = Application.get_env(:lemon_core, :agent_runtime_provider)
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    Process.register(owner, :approval_runtime_owner)
    assert :ok = LemonCore.AgentRuntime.register(OwnerProvider)

    on_exit(fn ->
      Process.exit(owner, :kill)

      if previous do
        Application.put_env(:lemon_core, :agent_runtime_provider, previous)
      else
        Application.delete_env(:lemon_core, :agent_runtime_provider)
      end
    end)

    {task, id} = request("runtime-provider", session_id: "approval_runtime_owner")
    assert ExecApprovalStore.get_pending(id).owner_session_pid == owner
    stop_child(ExecApprovalExpiry)
    restart_child(ExecApprovalExpiry)
    Process.exit(owner, :kill)
    assert {:ok, :denied} = Task.await(task)
    assert_expired(id)
  end

  test "resolution itself refuses a dead session without relying on a DOWN notification" do
    owner = spawn(fn -> receive do: (:stop -> :ok) end)
    {task, id} = request("dead-session", session_id: "dead-session")
    pending = ExecApprovalStore.get_pending(id)
    assert :ok = ExecApprovalStore.put_pending(id, %{pending | owner_session_pid: owner})
    ref = Process.monitor(owner)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    assert {:error, :expired} = ExecApprovals.resolve(id, :approve_global)
    assert {:ok, :denied} = Task.await(task)
    assert_expired(id)
  end

  test "worker recovery reconciles a run finalized while notifications were unavailable" do
    {task, id} = request("missed-finalization")
    stop_child(ExecApprovalExpiry)

    assert :ok =
             LemonCore.RunStore.finalize("run-missed-finalization", %{completed: %{ok: false}})

    restart_child(ExecApprovalExpiry)
    assert {:ok, :denied} = Task.await(task)
    assert_expired(id)
  end

  defp request(suffix, opts \\ []) do
    id = "approval-#{suffix}"

    task =
      Task.async(fn ->
        ExecApprovals.request(%{
          approval_id: id,
          run_id: "run-#{suffix}",
          session_id: opts[:session_id],
          session_key: "agent:test:#{suffix}",
          agent_id: "test",
          tool: "computer_use",
          action: %{type: "click"},
          expires_in_ms: :infinity
        })
      end)

    assert_receive %LemonCore.Event{
      type: :approval_requested,
      payload: %{approval_id: ^id}
    }

    {task, id}
  end

  defp assert_expired(id) do
    assert {:ok, nil} = ExecApprovalStore.fetch_pending(id)

    assert {:ok, %{resolution: %{decision: :expired, outcome: :expired}}} =
             ExecApprovalStore.fetch_record(id)

    for decision <- [:approve_once, :approve_session, :approve_agent, :approve_global] do
      assert {:error, :expired} = ExecApprovals.resolve(id, decision)
    end

    for table <- [
          :exec_approvals_policy,
          :exec_approvals_policy_session,
          :exec_approvals_policy_agent
        ] do
      assert [] == Store.list(table)
    end
  end

  defp stop_child(child), do: :ok = Supervisor.terminate_child(LemonCore.Supervisor, child)

  defp restart_child(child),
    do: {:ok, _pid} = Supervisor.restart_child(LemonCore.Supervisor, child)
end
