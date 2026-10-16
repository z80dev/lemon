defmodule CodingAgent.SessionRecoveryTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{ControlPlaneProvider, Session, SessionManager}
  alias CodingAgent.Session.Recovery
  alias LemonAi.Types.{Model, ModelCost}

  @tag :tmp_dir
  test "native recovery reads are serialized, immutable and exclude model context", %{
    tmp_dir: cwd
  } do
    model = %Model{
      id: "recovery-read",
      name: "Recovery read",
      api: :mock,
      provider: :mock_provider,
      base_url: "https://invalid.test",
      input: [:text],
      cost: %ModelCost{},
      context_window: 128_000,
      max_tokens: 4_096
    }

    observer = self()

    session =
      start_supervised!(
        {Session,
         [
           cwd: cwd,
           model: model,
           system_prompt: "PRIVATE SYSTEM CONTEXT",
           stream_fn: fn _, _, _ ->
             send(observer, :unexpected_model_call)
             {:error, :not_requested}
           end
         ]}
      )

    assert {:ok, [], todo_revision} = Session.todos(session)

    assert {:ok, todos, _todo_revision} =
             Session.write_todos(
               session,
               [
                 %{
                   "id" => "recovery-todo",
                   "content" => "Recover journal todos",
                   "status" => "pending",
                   "priority" => "medium"
                 }
               ],
               todo_revision
             )

    before = Session.get_state(session)
    assert {:ok, snapshot} = Session.recovery_snapshot(session)
    assert snapshot.session_id == before.session_manager.header.id
    assert snapshot.branch_id == before.session_manager.leaf_id
    assert snapshot.entries == SessionManager.get_branch(before.session_manager)
    assert snapshot.streaming == false
    assert {:ok, ^todos, _revision} = Session.todos(session)

    assert Enum.any?(snapshot.entries, fn entry ->
             entry.type == :custom and entry.custom_type == "lemon.todo" and
               entry.data["todos"] == todos
           end)

    refute Map.has_key?(snapshot, :system_prompt)
    refute Map.has_key?(snapshot, :model)
    refute Map.has_key?(snapshot, :agent)
    refute Map.has_key?(snapshot, :settings_manager)
    assert Session.get_state(session) == before
    assert {:ok, ^snapshot} = Session.recovery_snapshot(session)
    refute_receive :unexpected_model_call
    on_exit(fn -> File.rm_rf!(CodingAgent.Config.sessions_dir(cwd)) end)
  end

  @tag :tmp_dir
  test "the same selected branch produces equality revisions and journal changes invalidate them",
       %{tmp_dir: cwd} do
    selected =
      SessionManager.new(cwd)
      |> SessionManager.append_message(%{role: :user, content: "Selected"})

    first = Recovery.snapshot(selected)
    assert Recovery.snapshot(selected) == first
    abandoned = SessionManager.append_message(selected, %{role: :assistant, content: "Abandoned"})
    assert Recovery.snapshot(abandoned).revision != first.revision
    restored = SessionManager.set_leaf_id(abandoned, selected.leaf_id)
    assert Recovery.snapshot(restored).branch_id == first.branch_id
    assert Recovery.snapshot(restored).entries == first.entries
    # Selected content identity is an equality token; abandoned history does not
    # become the selected branch simply because it was appended most recently.
    refute Enum.any?(Recovery.snapshot(restored).entries, &(&1.message[:content] == "Abandoned"))
  end

  test "a missing process owner is never a privileged process inventory" do
    assert ControlPlaneProvider.session_process_receipts(nil) == {:error, :unavailable}
    assert ControlPlaneProvider.session_process_receipts("") == {:error, :unavailable}
  end

  test "process receipt reconciliation filters real store records by exact owner before projection" do
    owner = "snapshot-owner-#{System.unique_integer([:positive])}"

    mine = owner <> "-launch"
    foreign = owner <> "-foreign-launch"
    fingerprint = owner <> "-fingerprint"

    on_exit(fn ->
      CodingAgent.ProcessStore.confirm_termination(mine, :workload_empty)
      CodingAgent.ProcessStore.delete(mine)
      CodingAgent.ProcessStore.delete(foreign)
    end)

    assert :new =
             CodingAgent.ProcessStore.register_launch(
               mine,
               owner,
               fingerprint,
               System.system_time(:millisecond) + 60_000,
               self()
             )

    # Exercise the managed admission owner without starting an external workload.
    assert :ok = CodingAgent.ProcessStore.claim_launch(mine, owner, fingerprint)

    assert ^mine =
             CodingAgent.ProcessStore.new_process(%{
               id: mine,
               owner: owner,
               launch_fingerprint: fingerprint,
               command: "PRIVATE OWNED COMMAND",
               env: %{"API_KEY" => "test-only-secret"}
             })

    assert ^foreign =
             CodingAgent.ProcessStore.new_process(%{
               id: foreign,
               owner: owner <> "-foreign",
               status: :running,
               command: "PRIVATE FOREIGN COMMAND"
             })

    assert {:ok, [receipt]} = ControlPlaneProvider.session_process_receipts(owner)
    assert receipt.identity == mine
    assert receipt.status == :lost
    assert receipt.classification == :outcome_unknown
    refute Map.has_key?(receipt, :command)
    refute Map.has_key?(receipt, :env)
  end

  test "an unreadable lifecycle row makes process receipt recovery unavailable" do
    owner = "snapshot-unreadable-owner-#{System.unique_integer([:positive])}"
    id = owner <> "-launch"

    # A damaged legacy row cannot supply receipt identity. Do not silently omit
    # it or mistake an unreadable inventory for an empty process inventory.
    CodingAgent.ProcessStore.list(:all)
    on_exit(fn -> :ets.delete(:coding_agent_processes, id) end)
    :ets.insert(:coding_agent_processes, {id, %{owner: owner, status: :lost}, []})

    assert ControlPlaneProvider.session_process_receipts(owner) == {:error, :unavailable}
  end
end
