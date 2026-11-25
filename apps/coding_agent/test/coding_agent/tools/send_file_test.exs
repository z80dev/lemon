defmodule CodingAgent.Tools.SendFileTest do
  # Not async: some tests swap the running gateway config's channel sections.
  use ExUnit.Case, async: false

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

  defp assert_symlink_refused(result) do
    assert result.details == %{error: true}
    assert text(result) =~ "Symlinks are not allowed"
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
        assert_symlink_refused(send(@channel, root, %{"path" => "link.png"}))
      end

      test "#{channel}: a symlinked directory escaping the root is refused", %{
        root: root,
        outside: outside
      } do
        File.ln_s!(outside, Path.join(root, "escape"))
        assert_symlink_refused(send(@channel, root, %{"path" => "escape/secret.png"}))
      end

      test "#{channel}: any `..` component is refused even when it stays inside", %{
        root: root
      } do
        File.mkdir_p!(Path.join(root, "sub"))
        File.write!(Path.join(root, "chart.png"), "PNG")
        workspace = Path.join(root, "ws")
        File.mkdir_p!(Path.join(workspace, "sub"))
        File.write!(Path.join(workspace, "chart.png"), "PNG")

        for path <- [
              "sub/../chart.png",
              "./sub/../chart.png",
              Path.join(root, "sub/../chart.png"),
              "workspace/sub/../chart.png",
              "#{root}/sub/.."
            ] do
          assert_policy_error(send(@channel, root, %{"path" => path}, workspace_dir: workspace))
        end
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
    test "telegram queues a private copy of an image under cwd", %{root: root} do
      image = Path.join(root, "chart.png")
      File.write!(image, "PNG")

      result = send("telegram", root, %{"path" => "chart.png", "caption" => "Latest"})

      assert text(result) =~ "Queued file for Telegram delivery"

      assert %{auto_send_files: [%{path: copy, filename: "chart.png", caption: "Latest"}]} =
               result.details

      refute copy == image
      assert File.read!(copy) == "PNG"
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

    test "symlinks below the root are refused even when they stay inside", %{root: root} do
      File.write!(Path.join(root, "real.png"), "PNG")
      File.ln_s!(Path.join(root, "real.png"), Path.join(root, "alias.png"))
      File.ln_s!("real.png", Path.join(root, "rel_alias.png"))
      File.mkdir_p!(Path.join(root, "img"))
      File.write!(Path.join(root, "img/pic.png"), "PNG")
      File.ln_s!(Path.join(root, "img"), Path.join(root, "imgdir"))

      for path <- ["alias.png", "rel_alias.png", Path.join(root, "alias.png"), "imgdir/pic.png"] do
        assert_symlink_refused(send("telegram", root, %{"path" => path}))
      end
    end
  end

  describe "deny rules and private copies" do
    test "the queued file keeps the validated bytes after the source changes", %{
      root: root,
      outside: outside
    } do
      source = Path.join(root, "report.txt")
      File.write!(source, "VALIDATED")

      assert %{auto_send_files: [file]} = send("discord", root, %{"path" => "report.txt"}).details
      refute file.path == source
      refute String.starts_with?(file.path, root <> "/")
      assert File.read!(file.path) == "VALIDATED"
      assert {:ok, %File.Stat{mode: mode}} = File.stat(Path.dirname(file.path))
      assert Bitwise.band(mode, 0o077) == 0

      File.write!(source, "CHANGED")
      assert File.read!(file.path) == "VALIDATED"

      File.rm!(source)
      File.ln_s!(Path.join(outside, "secret.txt"), source)
      assert File.read!(file.path) == "VALIDATED"
    end

    test "built-in secret names are refused, and aliases of them are symlinks", %{root: root} do
      File.write!(Path.join(root, ".env"), "API_KEY=1")
      File.mkdir_p!(Path.join(root, ".git"))
      File.write!(Path.join(root, ".git/config"), "[core]")

      for path <- [".env", ".git/config", Path.join(root, ".env")] do
        result = send("discord", root, %{"path" => path})
        assert result.details == %{error: true}
        assert text(result) =~ "Access denied"
      end

      # An innocuous name linking to a secret, and a secret name linking to an
      # innocuous file: neither is followed.
      File.ln_s!(Path.join(root, ".env"), Path.join(root, "alias.txt"))
      File.mkdir_p!(Path.join(root, "config"))
      File.write!(Path.join(root, "config/local.txt"), "ok")
      File.mkdir_p!(Path.join(root, "app"))
      File.ln_s!(Path.join(root, "config/local.txt"), Path.join(root, "app/.env"))

      assert_symlink_refused(send("discord", root, %{"path" => "alias.txt"}))

      result = send("discord", root, %{"path" => "app/.env"})
      assert result.details == %{error: true}
      assert text(result) =~ ~r/Access denied|Symlinks are not allowed/
    end

    test "the queued copy is registered for the session only", %{root: root} do
      File.write!(Path.join(root, "report.txt"), "ok")

      assert %{auto_send_files: [%{path: copy}]} =
               send("discord", root, %{"path" => "report.txt"}).details

      refute LemonCore.OutboundCopies.take(key("telegram"), copy)
      assert LemonCore.OutboundCopies.take(key("discord"), copy)
      refute LemonCore.OutboundCopies.take(key("discord"), copy)
    end

    test "configured files.deny_globs apply", %{root: root} do
      File.mkdir_p!(Path.join(root, "keys"))
      File.write!(Path.join(root, "keys/server.key"), "KEY")
      File.write!(Path.join(root, "notes.txt"), "notes")
      put_config(:discord, %{files: %{deny_globs: ["**/*.{pem,key}"]}})

      assert send("discord", root, %{"path" => "keys/server.key"}).details == %{error: true}
      assert %{auto_send_files: [_]} = send("discord", root, %{"path" => "notes.txt"}).details
    end
  end

  describe "size limits" do
    setup %{root: root} do
      File.write!(Path.join(root, "big.png"), String.duplicate("x", 10))
      File.write!(Path.join(root, "small.png"), "xx")
      :ok
    end

    defp assert_too_large(result, max) do
      assert result.details == %{error: true}
      assert text(result) =~ "File is too large. Max allowed is #{max} bytes."
    end

    test "discord honors channel-level max_upload_bytes", %{root: root} do
      put_config(:discord, %{max_upload_bytes: 4})
      assert_too_large(send("discord", root, %{"path" => "big.png"}), 4)
      assert %{auto_send_files: [_]} = send("discord", root, %{"path" => "small.png"}).details
    end

    test "discord enforces the stricter of max_upload_bytes and files.max_download_bytes", %{
      root: root
    } do
      put_config(:discord, %{max_upload_bytes: 100, files: %{max_download_bytes: "5"}})
      assert_too_large(send("discord", root, %{"path" => "big.png"}), 5)

      put_config(:discord, %{"max_upload_bytes" => "6", files: %{max_download_bytes: 100}})
      assert_too_large(send("discord", root, %{"path" => "big.png"}), 6)
    end

    test "telegram honors string-valued files.max_download_bytes", %{root: root} do
      put_config(:telegram, %{files: %{"max_download_bytes" => "4"}})
      assert_too_large(send("telegram", root, %{"path" => "big.png"}), 4)
      assert %{auto_send_files: [_]} = send("telegram", root, %{"path" => "small.png"}).details
    end

    test "invalid limits fall back to the channel default", %{root: root} do
      put_config(:telegram, %{files: %{max_download_bytes: "zero"}, max_upload_bytes: -1})
      assert %{auto_send_files: [_]} = send("telegram", root, %{"path" => "big.png"}).details
    end
  end

  # The test-mode full-replacement layer read by `LemonCore.GatewayConfig`.
  defp put_config(key, value) do
    env_key = :"Elixir.LemonGateway.Config"
    previous = Application.get_env(:lemon_gateway, env_key)
    Application.put_env(:lemon_gateway, env_key, Map.put(Map.new(previous || []), key, value))

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_gateway, env_key, previous),
        else: Application.delete_env(:lemon_gateway, env_key)
    end)
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
