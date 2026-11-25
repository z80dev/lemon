defmodule LemonChannels.CheckpointStatusMessageTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Transport.Commands
  alias LemonChannels.CheckpointStatusMessage
  alias LemonAgent.Checkpoint

  @session_key "agent:test:telegram:default:group:-1001"

  defp chat(owner, sender \\ "1"),
    do: [checkpoint_owner: owner, session_key: @session_key, sender_id: sender]

  defp tokens_in(text, command, checkpoint_id) do
    Regex.scan(~r/#{command} #{checkpoint_id} ([A-Za-z0-9_-]{32,})/, text)
    |> Enum.map(&List.last/1)
  end

  defmodule BusyBackend do
    @behaviour LemonCore.Store.Backend
    def init(_), do: {:ok, %{}}
    def put(_, _, _, _), do: {:error, :sqlite_busy}
    def put_new(_, _, _, _), do: {:error, :sqlite_busy}
    def get(_, _, _), do: {:error, :sqlite_busy}
    def delete(_, _, _), do: {:error, :sqlite_busy}
    def list(_, _), do: {:error, {:sqlite_busy, "private-backend-detail"}}
  end

  test "checkpoint history reports unavailable without inventing zero events" do
    original = :sys.get_state(LemonCore.Store)
    :sys.replace_state(LemonCore.Store, &%{&1 | backend: BusyBackend, backend_state: %{}})

    try do
      status = CheckpointStatusMessage.text()
      assert status =~ "Events: unavailable"
      assert status =~ "Recent events: unavailable"
      refute status =~ "created 0"
      refute status =~ "private-backend-detail"

      assert CheckpointStatusMessage.handle("events") == "Checkpoint Events\nunavailable"
      assert CheckpointStatusMessage.handle_rollback("events") == "Checkpoint Events\nunavailable"
    after
      :sys.replace_state(LemonCore.Store, fn _ -> original end)
    end
  end

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

    text =
      CheckpointStatusMessage.text(
        checkpoint_dir: tmp_dir,
        checkpoint_owner: "agent:private-session"
      )

    assert text =~ "Checkpoint Status"
    assert text =~ "Total: 1"
    assert text =~ "Filesystem: 1"
    assert text =~ "chk_channel filesystem write (1 paths)"
    assert text =~ "/checkpoint diff <id>"
    assert text =~ "/checkpoint restore <id> (preview, then confirm with its token)"
    assert text =~ "Chat output is redacted"
    refute text =~ "agent:private-session"
    refute text =~ "/private/file.ex"
    refute text =~ "secret"
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
             Checkpoint.restore_filesystem(checkpoint.id, session_id,
               run_id: run_id,
               session_key: session_id
             )

    text =
      CheckpointStatusMessage.text(
        event_filters: [run_id: run_id],
        checkpoint_owner: session_id
      )

    assert text =~ "Events: created 1, restored 1, deleted 0"
    assert text =~ "restored #{checkpoint.id} (1 paths)"
    assert text =~ "created #{checkpoint.id} (1 paths)"
    refute text =~ path
    refute text =~ "secret-before"
    refute text =~ "secret-after"
    refute text =~ session_id

    events_text =
      CheckpointStatusMessage.handle("events 2",
        event_filters: [run_id: run_id],
        checkpoint_owner: session_id
      )

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

    diff_text = CheckpointStatusMessage.handle("diff #{checkpoint.id}", chat(session_id))

    assert diff_text =~ "Checkpoint Diff"
    assert diff_text =~ "Changed paths: 1"
    assert diff_text =~ "redacted in chat"
    refute diff_text =~ path
    refute diff_text =~ "secret-before"
    refute diff_text =~ "secret-after"

    restore_prompt = CheckpointStatusMessage.handle("restore #{checkpoint.id}", chat(session_id))

    assert restore_prompt =~ "Restore Preview"
    assert restore_prompt =~ "Changed paths: 1"
    assert [token] = tokens_in(restore_prompt, "restore", checkpoint.id)
    refute restore_prompt =~ path
    assert File.read!(path) == "secret-after\n"

    # The bare word is not a confirmation; it changes nothing.
    word_text =
      CheckpointStatusMessage.handle("restore #{checkpoint.id} confirm", chat(session_id))

    assert word_text =~ "nothing was restored"
    assert File.read!(path) == "secret-after\n"

    restore_text =
      CheckpointStatusMessage.handle("restore #{checkpoint.id} #{token}", chat(session_id))

    assert restore_text =~ "Checkpoint Restored"
    assert restore_text =~ "Restored paths: 1"
    assert File.read!(path) == "secret-before\n"
    refute restore_text =~ path
    refute restore_text =~ "secret-before"
  end

  @tag :tmp_dir
  test "a stale preview token restores nothing", %{tmp_dir: tmp_dir} do
    session_id = "channel-stale-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "stale.txt")
    File.write!(path, "v1\n")
    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    assert {:ok, checkpoint} = Checkpoint.create_filesystem(session_id, [path], cwd: tmp_dir)
    File.write!(path, "v2\n")

    preview = CheckpointStatusMessage.handle("restore #{checkpoint.id}", chat(session_id))

    assert [token] = tokens_in(preview, "restore", checkpoint.id)
    File.write!(path, "v3\n")

    text = CheckpointStatusMessage.handle("restore #{checkpoint.id} #{token}", chat(session_id))

    assert text =~ "nothing was restored"
    assert File.read!(path) == "v3\n"
  end

  @tag :tmp_dir
  test "a preview token works once and only for the chat member it was issued to", %{
    tmp_dir: tmp_dir
  } do
    session_id = "channel-member-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "member.txt")
    File.write!(path, "v1\n")
    on_exit(fn -> Checkpoint.delete_all(session_id) end)

    assert {:ok, checkpoint} = Checkpoint.create_filesystem(session_id, [path], cwd: tmp_dir)
    File.write!(path, "v2\n")

    preview = CheckpointStatusMessage.handle("restore #{checkpoint.id}", chat(session_id, "1"))
    assert [token] = tokens_in(preview, "restore", checkpoint.id)

    other_member =
      CheckpointStatusMessage.handle("restore #{checkpoint.id} #{token}", chat(session_id, "2"))

    assert other_member =~ "nothing was restored"
    assert File.read!(path) == "v2\n"

    # The foreign attempt spent the token.
    replay =
      CheckpointStatusMessage.handle("restore #{checkpoint.id} #{token}", chat(session_id, "1"))

    assert replay =~ "nothing was restored"
    assert File.read!(path) == "v2\n"

    preview = CheckpointStatusMessage.handle("restore #{checkpoint.id}", chat(session_id, "1"))
    assert [token] = tokens_in(preview, "restore", checkpoint.id)

    assert CheckpointStatusMessage.handle(
             "restore #{checkpoint.id} #{token}",
             chat(session_id, "1")
           ) =~ "Checkpoint Restored"

    assert File.read!(path) == "v1\n"
    File.write!(path, "v2\n")

    assert CheckpointStatusMessage.handle(
             "restore #{checkpoint.id} #{token}",
             chat(session_id, "1")
           ) =~ "nothing was restored"

    assert File.read!(path) == "v2\n"
  end

  @tag :tmp_dir
  test "another session's checkpoint is refused for diff, preview and restore", %{
    tmp_dir: tmp_dir
  } do
    owner = "channel-owner-#{System.unique_integer([:positive])}"
    other = "channel-other-#{System.unique_integer([:positive])}"
    path = Path.join(tmp_dir, "foreign.txt")
    File.write!(path, "owner-before\n")
    on_exit(fn -> Checkpoint.delete_all(owner) end)

    assert {:ok, checkpoint} = Checkpoint.create_filesystem(owner, [path], cwd: tmp_dir)
    File.write!(path, "owner-after\n")

    {:ok, %{confirm_token: token}} =
      Checkpoint.restore_preview(checkpoint.id, owner, caller: {:chat, @session_key, "1"})

    for args <- [
          "diff #{checkpoint.id}",
          "restore #{checkpoint.id}",
          "restore #{checkpoint.id} #{token}"
        ] do
      text = CheckpointStatusMessage.handle(args, chat(other))
      assert text == "Checkpoint not found in this chat's session: #{checkpoint.id}"
    end

    # Without a resolvable owner nothing is reachable either.
    assert CheckpointStatusMessage.handle("restore #{checkpoint.id} #{token}") =~
             "not found in this chat's session"

    assert File.read!(path) == "owner-after\n"
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

    diff_text = CheckpointStatusMessage.handle_rollback("diff #{checkpoint.id}", chat(session_id))

    assert diff_text =~ "Checkpoint Diff"
    assert diff_text =~ "Changed paths: 1"
    refute diff_text =~ path
    refute diff_text =~ "secret-before"
    refute diff_text =~ "secret-after"

    restore_prompt = CheckpointStatusMessage.handle_rollback(checkpoint.id, chat(session_id))

    assert restore_prompt =~ "Restore Preview"
    assert [token] = tokens_in(restore_prompt, "rollback", checkpoint.id)
    assert File.read!(path) == "secret-after\n"

    assert CheckpointStatusMessage.handle_rollback("#{checkpoint.id} confirm", chat(session_id)) =~
             "nothing was restored"

    assert File.read!(path) == "secret-after\n"

    restore_text =
      CheckpointStatusMessage.handle_rollback("#{checkpoint.id} #{token}", chat(session_id))

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
