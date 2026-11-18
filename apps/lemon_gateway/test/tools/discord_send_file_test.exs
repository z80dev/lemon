defmodule LemonGateway.Tools.DiscordSendFileTest do
  # Not async: one test swaps the running gateway config's `:discord` section.
  use ExUnit.Case, async: false

  alias LemonGateway.Tools.DiscordSendFile

  @moduletag :tmp_dir

  test "queues a private copy of a file from cwd for discord sessions", %{tmp_dir: tmp_dir} do
    file_path = Path.join(tmp_dir, "report.txt")
    File.write!(file_path, "ok")

    result = run(tmp_dir, %{"path" => "report.txt", "caption" => "artifact"})

    assert LemonAgent.get_text(result) =~ "Queued file for Discord delivery"

    assert %{auto_send_files: [file]} = result.details
    assert file.path != file_path
    assert File.read!(file.path) == "ok"
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

    assert LemonAgent.get_text(result) =~ "only available for Discord channel sessions"
    assert %{error: true} = result.details
  end

  test "allows resolving file from workspace_dir fallback", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    file_path = Path.join(workspace_dir, "discord_file_test.txt")
    File.write!(file_path, "ok")

    result =
      run(tmp_dir, %{"path" => "discord_file_test.txt", "filename" => "delivered.txt"},
        workspace_dir: workspace_dir
      )

    assert %{auto_send_files: [file]} = result.details
    assert file.path != file_path
    assert File.read!(file.path) == "ok"
    assert file.filename == "delivered.txt"
  end

  describe "containment" do
    setup %{tmp_dir: tmp_dir} do
      root = Path.join(tmp_dir, "root")
      outside = Path.join(tmp_dir, "outside")
      File.mkdir_p!(root)
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret.txt"), "OUTSIDE_SECRET")
      %{root: root, outside: outside}
    end

    test "refuses ../ traversal out of the root", %{root: root, outside: outside} do
      for path <- ["../outside/secret.txt", "workspace/../../outside/secret.txt"] do
        result = run(root, %{"path" => path}, workspace_dir: Path.join(root, "workspace"))
        assert_refused(result, outside)
      end
    end

    test "refuses relative paths through in-root symlinks", %{root: root, outside: outside} do
      File.ln_s!(outside, Path.join(root, "linkdir"))
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "link.txt"))

      for path <- ["linkdir/secret.txt", "link.txt"] do
        assert_refused(run(root, %{"path" => path}), outside)
      end
    end

    test "refuses an absolute path naming an in-root symlink", %{root: root, outside: outside} do
      File.ln_s!(outside, Path.join(root, "linkdir"))
      File.ln_s!(Path.join(outside, "secret.txt"), Path.join(root, "link.txt"))

      for path <- [Path.join(root, "link.txt"), Path.join(root, "linkdir/secret.txt")] do
        assert_refused(run(root, %{"path" => path}), outside)
      end

      assert_refused(run(root, %{"path" => Path.join(outside, "secret.txt")}), outside)
    end

    test "refuses built-in secret names", %{root: root, outside: outside} do
      File.write!(Path.join(root, ".env"), "API_KEY=1")
      File.mkdir_p!(Path.join(root, ".git"))
      File.write!(Path.join(root, ".git/config"), "[core]")

      for path <- [".env", ".git/config", Path.join(root, ".env")] do
        result = run(root, %{"path" => path})
        assert_refused(result, outside)
        assert LemonAgent.get_text(result) =~ "Access denied"
      end
    end

    test "configured files.deny_globs apply", %{root: root, outside: outside} do
      File.mkdir_p!(Path.join(root, "keys"))
      File.write!(Path.join(root, "keys/server.key"), "KEY")
      File.write!(Path.join(root, "notes.txt"), "notes")
      put_discord_config(%{files: %{deny_globs: ["**/*.{pem,key}"]}})

      assert_refused(run(root, %{"path" => "keys/server.key"}), outside)
      assert %{auto_send_files: [_]} = run(root, %{"path" => "notes.txt"}).details
    end

    test "configured ** globs cover directory names containing newlines", %{
      root: root,
      outside: outside
    } do
      dir = Path.join(root, "keys\nprod")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "server.key"), "KEY")
      put_discord_config(%{files: %{deny_globs: ["**/*.key"]}})

      assert_refused(run(root, %{"path" => "keys\nprod/server.key"}), outside)
      assert_refused(run(root, %{"path" => Path.join(dir, "server.key")}), outside)
    end

    test "the queued file keeps the validated bytes after the source changes", %{
      root: root,
      outside: outside
    } do
      source = Path.join(root, "report.txt")
      File.write!(source, "VALIDATED")

      assert %{auto_send_files: [file]} = run(root, %{"path" => "report.txt"}).details
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
  end

  defp run(root, params, opts \\ []) do
    tool = DiscordSendFile.tool(root, Keyword.put(opts, :session_key, discord_session_key()))
    tool.execute.("call_1", params, nil, nil)
  end

  defp assert_refused(result, outside) do
    assert %{error: true} = result.details
    refute Map.has_key?(result.details, :auto_send_files)
    refute LemonAgent.get_text(result) =~ outside
  end

  defp put_discord_config(discord) do
    case Process.whereis(LemonGateway.Config) do
      pid when is_pid(pid) ->
        previous = :sys.get_state(LemonGateway.Config)
        :sys.replace_state(LemonGateway.Config, &Map.put(&1, :discord, discord))
        on_exit(fn -> :sys.replace_state(LemonGateway.Config, fn _ -> previous end) end)

      nil ->
        previous = Application.get_env(:lemon_gateway, :discord)
        Application.put_env(:lemon_gateway, :discord, discord)

        on_exit(fn ->
          if previous,
            do: Application.put_env(:lemon_gateway, :discord, previous),
            else: Application.delete_env(:lemon_gateway, :discord)
        end)
    end
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
