defmodule LemonGateway.Tools.TelegramSendImageTest do
  # Not async: one test swaps the running gateway config's `:telegram` section.
  use ExUnit.Case, async: false

  alias LemonGateway.Tools.TelegramSendImage

  @moduletag :tmp_dir

  test "queues a private copy of an image from cwd for telegram sessions", %{tmp_dir: tmp_dir} do
    image_path = Path.join(tmp_dir, "chart.png")
    File.write!(image_path, "PNG")

    result = run(tmp_dir, %{"path" => "chart.png", "caption" => "Latest chart"})

    assert LemonAgent.get_text(result) =~ "Queued image for Telegram delivery"

    assert %{auto_send_files: [file]} = result.details
    assert file.path != image_path
    assert File.read!(file.path) == "PNG"
    assert Path.basename(file.path) == "chart.png"
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

    assert LemonAgent.get_text(result) =~ "only available for Telegram channel sessions"
    assert %{error: true} = result.details
  end

  test "rejects non-image files", %{tmp_dir: tmp_dir} do
    File.write!(Path.join(tmp_dir, "notes.txt"), "text")

    result = run(tmp_dir, %{"path" => "notes.txt"})
    assert LemonAgent.get_text(result) =~ "Unsupported image type"
    assert %{error: true} = result.details
  end

  test "allows resolving image from workspace_dir fallback", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    image_path = Path.join(workspace_dir, "render.png")
    File.write!(image_path, "PNG")

    result = run(tmp_dir, %{"path" => "render.png"}, workspace_dir: workspace_dir)

    assert %{auto_send_files: [file]} = result.details
    assert file.path != image_path
    assert File.read!(file.path) == "PNG"
    assert file.filename == "render.png"
  end

  test "allows workspace-prefixed relative path", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    images_dir = Path.join(workspace_dir, "images")
    File.mkdir_p!(images_dir)
    image_path = Path.join(images_dir, "plot.png")
    File.write!(image_path, "PNG")

    for path <- [
          "workspace/images/plot.png",
          "./workspace/images/plot.png",
          ".lemon/agent/workspace/images/plot.png"
        ] do
      result = run(tmp_dir, %{"path" => path}, workspace_dir: workspace_dir)

      assert %{auto_send_files: [file]} = result.details
      assert file.path != image_path
      assert File.read!(file.path) == "PNG"
      assert file.filename == "plot.png"
    end
  end

  test "allows absolute path inside allowed roots", %{tmp_dir: tmp_dir} do
    image_path = Path.join(tmp_dir, "absolute.png")
    File.write!(image_path, "PNG")

    result = run(tmp_dir, %{"path" => image_path})

    assert %{auto_send_files: [file]} = result.details
    assert file.path != image_path
    assert File.read!(file.path) == "PNG"
    assert file.filename == "absolute.png"
  end

  describe "containment" do
    setup %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "root")
      outside = Path.join(tmp_dir, "outside")
      File.mkdir_p!(root)
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.png"), "OUTSIDE_SECRET")
      %{root: root, outside: outside}
    end

    test "refuses ../ traversal out of the root", %{root: root, outside: outside} do
      for path <- ["../outside/secret.png", "workspace/../../outside/secret.png"] do
        result = run(root, %{"path" => path}, workspace_dir: Path.join(root, "workspace"))
        assert_refused(result, outside)
      end
    end

    test "refuses relative paths through in-root symlinks", %{root: root, outside: outside} do
      File.ln_s!(outside, Path.join(root, "linkdir"))
      File.ln_s!(Path.join(outside, "secret.png"), Path.join(root, "link.png"))

      for path <- ["linkdir/secret.png", "link.png"] do
        assert_refused(run(root, %{"path" => path}), outside)
      end
    end

    test "refuses an absolute path naming an in-root symlink", %{root: root, outside: outside} do
      File.ln_s!(outside, Path.join(root, "linkdir"))
      File.ln_s!(Path.join(outside, "secret.png"), Path.join(root, "link.png"))

      for path <- [Path.join(root, "link.png"), Path.join(root, "linkdir/secret.png")] do
        assert_refused(run(root, %{"path" => path}), outside)
      end

      assert_refused(run(root, %{"path" => Path.join(outside, "secret.png")}), outside)
    end

    test "refuses built-in secret names", %{root: root, outside: outside} do
      File.write!(Path.join(root, ".env.png"), "API_KEY=1")
      File.mkdir_p!(Path.join(root, ".git"))
      File.write!(Path.join(root, ".git/shot.png"), "PNG")

      for path <- [".env.png", ".git/shot.png", Path.join(root, ".git/shot.png")] do
        result = run(root, %{"path" => path})
        assert_refused(result, outside)
        assert LemonAgent.get_text(result) =~ "Access denied"
      end
    end

    test "configured files.deny_globs apply", %{root: root, outside: outside} do
      File.write!(Path.join(root, "secret1.png"), "PNG")
      File.write!(Path.join(root, "public.png"), "PNG")
      put_telegram_config(%{files: %{deny_globs: ["secret[0-9].png"]}})

      assert_refused(run(root, %{"path" => "secret1.png"}), outside)
      assert %{auto_send_files: [_]} = run(root, %{"path" => "public.png"}).details
    end

    test "the queued image keeps the validated bytes after the source changes", %{
      root: root,
      outside: outside
    } do
      source = Path.join(root, "chart.png")
      File.write!(source, "VALIDATED")

      assert %{auto_send_files: [file]} = run(root, %{"path" => "chart.png"}).details
      refute file.path == source
      refute String.starts_with?(file.path, root <> "/")
      assert File.read!(file.path) == "VALIDATED"
      assert {:ok, %File.Stat{mode: mode}} = File.stat(Path.dirname(file.path))
      assert Bitwise.band(mode, 0o077) == 0

      File.write!(source, "CHANGED")
      assert File.read!(file.path) == "VALIDATED"

      File.rm!(source)
      File.ln_s!(Path.join(outside, "secret.png"), source)
      assert File.read!(file.path) == "VALIDATED"
    end
  end

  defp run(root, params, opts \\ []) do
    tool = TelegramSendImage.tool(root, Keyword.put(opts, :session_key, telegram_session_key()))
    tool.execute.("call_1", params, nil, nil)
  end

  defp assert_refused(result, outside) do
    assert %{error: true} = result.details
    refute Map.has_key?(result.details, :auto_send_files)
    refute LemonAgent.get_text(result) =~ outside
  end

  defp put_telegram_config(telegram) do
    case Process.whereis(LemonGateway.Config) do
      pid when is_pid(pid) ->
        previous = :sys.get_state(LemonGateway.Config)
        :sys.replace_state(LemonGateway.Config, &Map.put(&1, :telegram, telegram))
        on_exit(fn -> :sys.replace_state(LemonGateway.Config, fn _ -> previous end) end)

      nil ->
        previous = Application.get_env(:lemon_gateway, :telegram)
        Application.put_env(:lemon_gateway, :telegram, telegram)

        on_exit(fn ->
          if previous,
            do: Application.put_env(:lemon_gateway, :telegram, previous),
            else: Application.delete_env(:lemon_gateway, :telegram)
        end)
    end
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
