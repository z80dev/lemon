defmodule CodingAgent.Tools.SendFileTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.SendFile

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # root = <tmp>/a/b so "../../" from the root lands on <tmp> itself.
    root = Path.join([tmp_dir, "a", "b"])
    File.mkdir_p!(root)
    File.write!(Path.join(tmp_dir, "secret.png"), "secret")
    File.write!(Path.join(tmp_dir, "secret.txt"), "secret")
    %{root: root, outside: tmp_dir}
  end

  defp key(channel) do
    LemonCore.SessionKey.channel_peer(%{
      agent_id: "default",
      channel_id: channel,
      account_id: "bot",
      peer_kind: :dm,
      peer_id: "12345"
    })
  end

  defp send(channel, cwd, params, opts \\ []) do
    tool = SendFile.tool(cwd, Keyword.put(opts, :session_key, key(channel)))
    assert tool.name == "send_file"
    tool.execute.("call", params, nil, nil)
  end

  defp text(result), do: LemonAgent.get_text(result)

  defp assert_policy_error(result) do
    assert result.details == %{error: true}
    assert text(result) =~ "must stay within the active workspace/project roots"
  end

  describe "containment" do
    for channel <- ["telegram", "discord"] do
      @channel channel

      test "#{channel}: ../../etc/hosts is a definite policy error", %{root: root} do
        assert_policy_error(send(@channel, root, %{"path" => "../../etc/hosts"}))
      end

      test "#{channel}: relative traversal to an existing outside file is refused", %{
        root: root
      } do
        assert_policy_error(send(@channel, root, %{"path" => "../../secret.png"}))
      end

      test "#{channel}: absolute path outside the roots is refused", %{
        root: root,
        outside: outside
      } do
        assert_policy_error(send(@channel, root, %{"path" => Path.join(outside, "secret.png")}))
      end

      test "#{channel}: a symlink inside the root that points outside is refused", %{
        root: root,
        outside: outside
      } do
        File.ln_s!(Path.join(outside, "secret.png"), Path.join(root, "link.png"))
        assert_policy_error(send(@channel, root, %{"path" => "link.png"}))
      end

      test "#{channel}: a symlinked directory escaping the root is refused", %{
        root: root,
        outside: outside
      } do
        File.ln_s!(outside, Path.join(root, "escape"))
        assert_policy_error(send(@channel, root, %{"path" => "escape/secret.png"}))
      end

      test "#{channel}: workspace-prefixed traversal is refused", %{root: root} do
        workspace = Path.join(root, "ws")
        File.mkdir_p!(workspace)

        assert_policy_error(
          send(@channel, root, %{"path" => "workspace/../../../secret.png"},
            workspace_dir: workspace
          )
        )
      end

      test "#{channel}: a run without a cwd or workspace can send nothing", %{outside: outside} do
        assert_policy_error(send(@channel, nil, %{"path" => Path.join(outside, "secret.png")}))
        assert_policy_error(send(@channel, nil, %{"path" => "secret.png"}))
      end
    end
  end

  describe "positive controls" do
    test "telegram queues an image under cwd with its real path", %{root: root} do
      image = Path.join(root, "chart.png")
      File.write!(image, "PNG")

      result = send("telegram", root, %{"path" => "chart.png", "caption" => "Latest"})

      assert text(result) =~ "Queued file for Telegram delivery"
      {:ok, real} = CodingAgent.WorkspaceReads.realpath(image)

      assert %{auto_send_files: [%{path: ^real, filename: "chart.png", caption: "Latest"}]} =
               result.details
    end

    test "discord queues any file, absolute or via workspace prefix", %{root: root} do
      workspace = Path.join(root, "ws")
      File.mkdir_p!(Path.join(workspace, "out"))
      report = Path.join(root, "report.txt")
      File.write!(report, "ok")
      File.write!(Path.join([workspace, "out", "data.csv"]), "a,b")

      absolute = send("discord", root, %{"path" => report, "filename" => "x/../shown.txt"})
      assert %{auto_send_files: [%{filename: "shown.txt"}]} = absolute.details

      prefixed =
        send("discord", root, %{"path" => "workspace/out/data.csv"}, workspace_dir: workspace)

      assert %{auto_send_files: [%{filename: "data.csv"}]} = prefixed.details
    end

    test "a symlink that stays inside the root is allowed", %{root: root} do
      File.write!(Path.join(root, "real.png"), "PNG")
      File.ln_s!(Path.join(root, "real.png"), Path.join(root, "alias.png"))

      result = send("telegram", root, %{"path" => "alias.png"})
      assert %{auto_send_files: [%{filename: "real.png"}]} = result.details
    end
  end

  describe "channel policy" do
    test "telegram accepts images only", %{root: root} do
      File.write!(Path.join(root, "notes.txt"), "x")
      result = send("telegram", root, %{"path" => "notes.txt"})
      assert result.details == %{error: true}
      assert text(result) =~ "images only"
    end

    test "non-channel sessions are refused and not offered the tool", %{root: root} do
      File.write!(Path.join(root, "report.txt"), "ok")
      main = LemonCore.SessionKey.main("default")

      assert SendFile.channel(main) == nil
      assert SendFile.channel(nil) == nil
      assert SendFile.channel(key("telegram")) == "telegram"

      result =
        SendFile.tool(root, session_key: main).execute.("c", %{"path" => "report.txt"}, nil, nil)

      assert result.details == %{error: true}
    end

    test "missing files are reported as not found", %{root: root} do
      result = send("discord", root, %{"path" => "nope.txt"})
      assert result.details == %{error: true}
      assert text(result) =~ "File not found"
    end
  end
end
