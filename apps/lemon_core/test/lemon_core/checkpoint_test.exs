defmodule LemonCore.CheckpointTest do
  use ExUnit.Case, async: false

  alias LemonCore.Checkpoint
  alias LemonCore.Introspection

  setup do
    original = Application.get_env(:lemon_core, :introspection, [])
    Application.put_env(:lemon_core, :introspection, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:lemon_core, :introspection, original) end)
    :ok
  end

  test "creates, lists, stats, and deletes generic checkpoints" do
    session_id = unique_session("core-generic")

    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    assert {:ok, checkpoint} =
             Checkpoint.create(session_id,
               context: %{step: 1},
               metadata: %{tool: "core-test"}
             )

    assert checkpoint.session_id == session_id
    assert checkpoint.context.step == 1
    assert [listed] = Checkpoint.list(session_id)
    assert listed.id == checkpoint.id
    assert Checkpoint.exists?(checkpoint.id)
    assert Checkpoint.stats(session_id).count == 1
    assert :ok = Checkpoint.delete(checkpoint.id)
    refute Checkpoint.exists?(checkpoint.id)
  end

  @tag :tmp_dir
  test "diffs and restores filesystem checkpoints with events", %{tmp_dir: tmp_dir} do
    session_id = unique_session("core-filesystem")
    run_id = "run_#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "target.txt")

    File.write!(path, "before\n")
    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(run_id))

    assert {:ok, checkpoint} =
             Checkpoint.create_filesystem(session_id, [path],
               cwd: tmp_dir,
               tool: "core-test",
               run_id: run_id,
               session_key: session_id
             )

    assert_receive %LemonCore.Event{
                     type: :checkpoint_created,
                     payload: %{checkpoint_id: checkpoint_id, checkpoint_kind: "filesystem"}
                   },
                   1_000

    assert checkpoint_id == checkpoint.id
    File.write!(path, "after\n")

    assert {:ok, diff} = Checkpoint.diff_filesystem(checkpoint.id)
    assert diff.changed == [path]
    assert diff.output =~ "-before"
    assert diff.output =~ "+after"

    assert {:ok, restored} =
             Checkpoint.restore_filesystem(checkpoint.id,
               paths: [path],
               run_id: run_id,
               session_key: session_id
             )

    assert restored.restored == [path]
    assert File.read!(path) == "before\n"

    assert_receive %LemonCore.Event{
                     type: :checkpoint_restored,
                     payload: %{checkpoint_id: ^checkpoint_id, restored_count: 1}
                   },
                   1_000

    event =
      Introspection.list(event_type: :checkpoint_restored, run_id: run_id, limit: 20)
      |> Enum.find(&(&1.payload.checkpoint_id == checkpoint.id))

    assert event.payload.restored_count == 1
  end

  defp unique_session(prefix) do
    "#{prefix}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
