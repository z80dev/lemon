defmodule LemonGateway.Tools.DiscordSendFileTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Tools.DiscordSendFile

  @moduletag :tmp_dir

  test "queues file from cwd for discord sessions", %{tmp_dir: tmp_dir} do
    file_path = Path.join(tmp_dir, "report.txt")
    File.write!(file_path, "ok")

    tool = DiscordSendFile.tool(tmp_dir, session_key: discord_session_key())

    result =
      tool.execute.(
        "call_1",
        %{"path" => "report.txt", "caption" => "artifact"},
        nil,
        nil
      )

    assert AgentCore.get_text(result) =~ "Queued file for Discord delivery"

    assert %{auto_send_files: [file]} = result.details
    assert file.path == file_path
    assert file.filename == "report.txt"
    assert file.caption == "artifact"
  end

  test "rejects non-discord sessions", %{tmp_dir: tmp_dir} do
    file_path = Path.join(tmp_dir, "report.txt")
    File.write!(file_path, "ok")

    tool = DiscordSendFile.tool(tmp_dir, session_key: LemonCore.SessionKey.main("default"))

    result =
      tool.execute.(
        "call_1",
        %{"path" => "report.txt"},
        nil,
        nil
      )

    assert AgentCore.get_text(result) =~ "only available for Discord channel sessions"
    assert %{error: true} = result.details
  end

  test "allows resolving file from workspace_dir fallback", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    file_path = Path.join(workspace_dir, "discord_file_test.txt")
    File.write!(file_path, "ok")

    tool =
      DiscordSendFile.tool(
        tmp_dir,
        session_key: discord_session_key(),
        workspace_dir: workspace_dir
      )

    result =
      tool.execute.(
        "call_1",
        %{"path" => "discord_file_test.txt", "filename" => "delivered.txt"},
        nil,
        nil
      )

    assert %{auto_send_files: [file]} = result.details
    assert file.path == file_path
    assert file.filename == "delivered.txt"
  end

  defp discord_session_key do
    LemonCore.SessionKey.channel_peer(%{
      agent_id: "default",
      channel_id: "discord",
      account_id: "bot",
      peer_kind: :group,
      peer_id: "12345",
      sub_id: "67890"
    })
  end
end
