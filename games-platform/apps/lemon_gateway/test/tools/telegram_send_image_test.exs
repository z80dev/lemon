defmodule LemonGateway.Tools.TelegramSendImageTest do
  use ExUnit.Case, async: true

  alias LemonGateway.Tools.TelegramSendImage

  @moduletag :tmp_dir

  test "queues image from cwd for telegram sessions", %{tmp_dir: tmp_dir} do
    image_path = Path.join(tmp_dir, "chart.png")
    File.write!(image_path, "PNG")

    tool = TelegramSendImage.tool(tmp_dir, session_key: telegram_session_key())

    result =
      tool.execute.(
        "call_1",
        %{"path" => "chart.png", "caption" => "Latest chart"},
        nil,
        nil
      )

    assert AgentCore.get_text(result) =~ "Queued image for Telegram delivery"

    assert %{auto_send_files: [file]} = result.details
    assert file.path == image_path
    assert file.filename == "chart.png"
    assert file.caption == "Latest chart"
  end

  test "rejects non-telegram sessions", %{tmp_dir: tmp_dir} do
    image_path = Path.join(tmp_dir, "chart.png")
    File.write!(image_path, "PNG")

    tool = TelegramSendImage.tool(tmp_dir, session_key: LemonCore.SessionKey.main("default"))

    result =
      tool.execute.(
        "call_1",
        %{"path" => "chart.png"},
        nil,
        nil
      )

    assert AgentCore.get_text(result) =~ "only available for Telegram channel sessions"
    assert %{error: true} = result.details
  end

  test "allows resolving image from workspace_dir fallback", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    image_path = Path.join(workspace_dir, "render.png")
    File.write!(image_path, "PNG")

    tool =
      TelegramSendImage.tool(
        tmp_dir,
        session_key: telegram_session_key(),
        workspace_dir: workspace_dir
      )

    result =
      tool.execute.(
        "call_1",
        %{"path" => "render.png"},
        nil,
        nil
      )

    assert %{auto_send_files: [file]} = result.details
    assert file.path == image_path
    assert file.filename == "render.png"
  end

  test "allows workspace-prefixed relative path", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    images_dir = Path.join(workspace_dir, "images")
    File.mkdir_p!(images_dir)
    image_path = Path.join(images_dir, "plot.png")
    File.write!(image_path, "PNG")

    tool =
      TelegramSendImage.tool(
        tmp_dir,
        session_key: telegram_session_key(),
        workspace_dir: workspace_dir
      )

    result =
      tool.execute.(
        "call_1",
        %{"path" => "workspace/images/plot.png"},
        nil,
        nil
      )

    assert %{auto_send_files: [file]} = result.details
    assert file.path == image_path
    assert file.filename == "plot.png"
  end

  test "allows absolute path inside allowed roots", %{tmp_dir: tmp_dir} do
    image_path = Path.join(tmp_dir, "absolute.png")
    File.write!(image_path, "PNG")

    tool = TelegramSendImage.tool(tmp_dir, session_key: telegram_session_key())

    result =
      tool.execute.(
        "call_1",
        %{"path" => image_path},
        nil,
        nil
      )

    assert %{auto_send_files: [file]} = result.details
    assert file.path == image_path
    assert file.filename == "absolute.png"
  end

  defp telegram_session_key do
    LemonCore.SessionKey.channel_peer(%{
      agent_id: "default",
      channel_id: "telegram",
      account_id: "bot",
      peer_kind: :dm,
      peer_id: "12345"
    })
  end
end
