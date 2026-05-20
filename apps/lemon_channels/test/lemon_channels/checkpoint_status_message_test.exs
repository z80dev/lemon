defmodule LemonChannels.CheckpointStatusMessageTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Transport.Commands
  alias LemonChannels.CheckpointStatusMessage
  alias LemonCore.Checkpoint

  setup do
    original = Application.get_env(:lemon_core, :introspection, [])
    Application.put_env(:lemon_core, :introspection, Keyword.put(original, :enabled, true))
    on_exit(fn -> Application.put_env(:lemon_core, :introspection, original) end)
    :ok
  end

  test "renders redacted checkpoint status text" do
    tmp_dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(tmp_dir)

    File.write!(
      Path.join(tmp_dir, "chk_channel.json"),
      Jason.encode!(%{
        id: "chk_channel",
        session_id: "agent:private-session",
        timestamp: "2026-05-15T12:00:00Z",
        metadata: %{
          kind: "filesystem",
          tool: "write",
          path_count: 1
        },
        state: %{
          filesystem: %{
            files: [
              %{path: "/private/file.ex", content_b64: Base.encode64("secret")}
            ]
          }
        }
      })
    )

    text = CheckpointStatusMessage.text(checkpoint_dir: tmp_dir)

    assert text =~ "Checkpoint Status"
    assert text =~ "Total: 1"
    assert text =~ "Filesystem: 1"
    assert text =~ "chk_channel filesystem write (1 paths)"
    assert text =~ "/checkpoint diff <id>"
    assert text =~ "/checkpoint restore <id> confirm"
    assert text =~ "Chat output is redacted"
    refute text =~ "agent:private-session"
    refute text =~ "/private/file.ex"
    refute text =~ "secret"
  end

  test "renders redacted checkpoint event text" do
    event = %LemonCore.Event{
      type: :checkpoint_restored,
      ts_ms: System.system_time(:millisecond),
      payload: %{
        checkpoint_id: "chk_event",
        restored_count: 2,
        paths: ["/private/file.ex"],
        content: "secret"
      },
      meta: %{session_key: "agent:private-session"}
    }

    text = CheckpointStatusMessage.event_text(event)

    assert text == "Checkpoint Event\nrestored chk_event (2 paths)"
    refute text =~ "/private/file.ex"
    refute text =~ "secret"
    refute text =~ "agent:private-session"
  end

  @tag :tmp_dir
  test "renders redacted checkpoint lifecycle events", %{tmp_dir: tmp_dir} do
    session_id = "channel-event-#{System.unique_integer([:positive])}"
    run_id = "run-channel-event-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "event-private.txt")

    File.write!(path, "secret-before\n")
    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    assert {:ok, checkpoint} =
             Checkpoint.create_filesystem(session_id, [path],
               cwd: tmp_dir,
               tool: "channel-event-test",
               run_id: run_id,
               session_key: session_id
             )

    File.write!(path, "secret-after\n")

    assert {:ok, _restored} =
             Checkpoint.restore_filesystem(checkpoint.id,
               run_id: run_id,
               session_key: session_id
             )

    text = CheckpointStatusMessage.text(event_filters: [run_id: run_id])

    assert text =~ "Events: created 1, restored 1, deleted 0"
    assert text =~ "restored #{checkpoint.id} (1 paths)"
    assert text =~ "created #{checkpoint.id} (1 paths)"
    refute text =~ path
    refute text =~ "secret-before"
    refute text =~ "secret-after"
    refute text =~ session_id

    events_text = CheckpointStatusMessage.handle("events 2", event_filters: [run_id: run_id])

    assert events_text =~ "Checkpoint Events"
    assert events_text =~ "Limit: 2"
    assert events_text =~ "- restored #{checkpoint.id} (1 paths)"
    assert events_text =~ "- created #{checkpoint.id} (1 paths)"
    refute events_text =~ path
    refute events_text =~ "secret-before"
    refute events_text =~ "secret-after"
    refute events_text =~ session_id
  end

  @tag :tmp_dir
  test "diffs and restores checkpoints with redacted chat output", %{tmp_dir: tmp_dir} do
    session_id = "channel-checkpoint-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "private.txt")

    File.write!(path, "secret-before\n")
    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    assert {:ok, checkpoint} =
             Checkpoint.create_filesystem(session_id, [path],
               cwd: tmp_dir,
               tool: "channel-test"
             )

    File.write!(path, "secret-after\n")

    diff_text = CheckpointStatusMessage.handle("diff #{checkpoint.id}")

    assert diff_text =~ "Checkpoint Diff"
    assert diff_text =~ "Changed paths: 1"
    assert diff_text =~ "redacted in chat"
    refute diff_text =~ path
    refute diff_text =~ "secret-before"
    refute diff_text =~ "secret-after"

    restore_prompt = CheckpointStatusMessage.handle("restore #{checkpoint.id}")

    assert restore_prompt =~ "requires confirmation"
    assert File.read!(path) == "secret-after\n"

    restore_text = CheckpointStatusMessage.handle("restore #{checkpoint.id} confirm")

    assert restore_text =~ "Checkpoint Restored"
    assert restore_text =~ "Restored paths: 1"
    assert File.read!(path) == "secret-before\n"
    refute restore_text =~ path
    refute restore_text =~ "secret-before"
  end

  @tag :tmp_dir
  test "rolls back checkpoints through rollback alias with redacted chat output", %{
    tmp_dir: tmp_dir
  } do
    session_id = "channel-rollback-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "private-rollback.txt")

    File.write!(path, "secret-before\n")
    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    assert {:ok, checkpoint} =
             Checkpoint.create_filesystem(session_id, [path],
               cwd: tmp_dir,
               tool: "channel-rollback-test"
             )

    File.write!(path, "secret-after\n")

    diff_text = CheckpointStatusMessage.handle_rollback("diff #{checkpoint.id}")

    assert diff_text =~ "Checkpoint Diff"
    assert diff_text =~ "Changed paths: 1"
    refute diff_text =~ path
    refute diff_text =~ "secret-before"
    refute diff_text =~ "secret-after"

    restore_prompt = CheckpointStatusMessage.handle_rollback(checkpoint.id)

    assert restore_prompt =~ "Rollback requires confirmation"
    assert File.read!(path) == "secret-after\n"

    restore_text = CheckpointStatusMessage.handle_rollback("#{checkpoint.id} confirm")

    assert restore_text =~ "Checkpoint Restored"
    assert restore_text =~ "Restored paths: 1"
    assert File.read!(path) == "secret-before\n"
    refute restore_text =~ path
    refute restore_text =~ "secret-before"
  end

  test "recognizes telegram checkpoint command for bot" do
    assert Commands.checkpoint_command?("/checkpoint", "lemon_bot")
    assert Commands.checkpoint_command?("/checkpoint diff chk_123", "lemon_bot")
    assert Commands.checkpoint_command?("/checkpoint@lemon_bot", "lemon_bot")
    refute Commands.checkpoint_command?("/checkpoint@other_bot", "lemon_bot")
  end

  test "recognizes telegram rollback command for bot" do
    assert Commands.rollback_command?("/rollback", "lemon_bot")
    assert Commands.rollback_command?("/rollback chk_123 confirm", "lemon_bot")
    assert Commands.rollback_command?("/rollback@lemon_bot", "lemon_bot")
    refute Commands.rollback_command?("/rollback@other_bot", "lemon_bot")
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "lemon_channels_checkpoint_status_test_#{System.unique_integer([:positive])}"
    )
  end
end
