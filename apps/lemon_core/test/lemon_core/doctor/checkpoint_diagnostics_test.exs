defmodule LemonCore.Doctor.CheckpointDiagnosticsTest do
  use ExUnit.Case, async: true

  alias LemonCore.Doctor.CheckpointDiagnostics

  test "summarizes checkpoints without raw session ids or paths" do
    tmp_dir = tmp_dir()
    on_exit(fn -> File.rm_rf!(tmp_dir) end)

    File.mkdir_p!(tmp_dir)

    File.write!(
      Path.join(tmp_dir, "chk_a.json"),
      Jason.encode!(%{
        id: "chk_a",
        session_id: "agent:secret-session",
        timestamp: "2026-05-15T10:00:00Z",
        metadata: %{
          kind: "filesystem",
          tool: "write",
          action: "write",
          path_count: 2
        },
        state: %{
          filesystem: %{
            files: [
              %{path: "/private/path/a.txt", content_b64: Base.encode64("secret")}
            ]
          }
        }
      })
    )

    File.write!(Path.join(tmp_dir, "bad.json"), "not json")

    summary = CheckpointDiagnostics.summary(checkpoint_dir: tmp_dir, limit: 5)

    assert summary.exists == true
    assert summary.count == 1
    assert summary.filesystem_count == 1
    assert summary.invalid_count == 1
    assert summary.oldest == "2026-05-15T10:00:00Z"
    assert summary.newest == "2026-05-15T10:00:00Z"
    assert summary.cleanup.embeds_file_contents_in_support_bundle == false
    assert summary.cleanup.includes_raw_paths == false
    assert summary.cleanup.includes_raw_session_ids == false

    assert [
             %{
               checkpoint_id: "chk_a",
               session_hash: session_hash,
               kind: "filesystem",
               tool: "write",
               action: "write",
               path_count: 2,
               rollback: rollback
             }
           ] = summary.recent

    assert is_binary(session_hash)
    assert rollback.tui_diff == "/checkpoint diff chk_a"
    assert rollback.tui_restore == "/checkpoint restore chk_a"
    assert rollback.control_plane_diff =~ ~s("method":"checkpoint.diff")
    assert rollback.control_plane_diff =~ ~s("checkpointId":"chk_a")
    assert rollback.control_plane_restore =~ ~s("method":"checkpoint.restore")
    assert rollback.control_plane_restore =~ ~s("checkpointId":"chk_a")
    refute inspect(summary) =~ "agent:secret-session"
    refute inspect(summary) =~ "/private/path/a.txt"
    refute inspect(summary) =~ "secret"
  end

  defp tmp_dir do
    Path.join(
      System.tmp_dir!(),
      "lemon_checkpoint_diagnostics_test_#{System.unique_integer([:positive])}"
    )
  end
end
