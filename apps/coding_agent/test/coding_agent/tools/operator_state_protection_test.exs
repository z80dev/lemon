defmodule CodingAgent.Tools.OperatorStateProtectionTest do
  # Mutates the Lemon home layout (app env), LEMON_AGENT_DIR and PATH.
  use ExUnit.Case, async: false

  alias CodingAgent.ToolRegistry
  alias CodingAgent.Tools.{AnchoredEdit, Edit, FsCheckpoint, Patch, Write}
  alias LemonAgent.Types.{AgentTool, AgentToolResult}
  alias LemonAi.Types.TextContent
  alias LemonCore.ToolPolicy

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    home = Path.join(tmp_dir, "home")
    state = Path.join(home, ".lemon")
    agent = Path.join(state, "agent")
    workspace = Path.join(agent, "workspace")
    toolchain = Path.join(tmp_dir, "toolchain")

    for dir <- [
          workspace,
          Path.join(agent, "extensions"),
          Path.join(state, "cron_memory"),
          toolchain
        ],
        do: File.mkdir_p!(dir)

    File.write!(Path.join(state, "config.toml"), "[runtime]\n")
    File.write!(Path.join(agent, "mcp_project_trust.json"), "{}\n")
    File.write!(Path.join([state, "cron_memory", "job-a.md"]), "# job a\n")
    File.write!(Path.join([state, "cron_memory", "job-b.md"]), "# job b\n")

    # A post-edit checker found on PATH outside any project.
    checker = Path.join(toolchain, "prettier")
    File.write!(checker, "#!/bin/sh\nexit 0\n")
    File.chmod!(checker, 0o755)

    previous_paths = Application.get_env(:lemon_core, :paths)
    previous_agent_dir = System.get_env("LEMON_AGENT_DIR")
    previous_path = System.get_env("PATH")

    Application.put_env(:lemon_core, :paths, Keyword.put(previous_paths || [], :home_dir, home))
    System.put_env("LEMON_AGENT_DIR", agent)
    System.put_env("PATH", toolchain <> ":" <> (previous_path || ""))

    on_exit(fn ->
      if previous_paths,
        do: Application.put_env(:lemon_core, :paths, previous_paths),
        else: Application.delete_env(:lemon_core, :paths)

      if previous_agent_dir,
        do: System.put_env("LEMON_AGENT_DIR", previous_agent_dir),
        else: System.delete_env("LEMON_AGENT_DIR")

      if previous_path, do: System.put_env("PATH", previous_path)
    end)

    %{home: home, state: state, agent: agent, workspace: workspace, toolchain: toolchain}
  end

  describe "file tools" do
    test "write refuses the global config reached relative to the assistant workspace", ctx do
      config = Path.join(ctx.state, "config.toml")

      assert {:error, message} = write(ctx.workspace, "../../config.toml", "[evil]\n")
      assert message =~ "operator state"
      assert File.read!(config) == "[runtime]\n"
    end

    test "write refuses the secrets key file, extensions and kanban controller repos", ctx do
      for path <- [
            Path.join(ctx.state, "secrets_master_key"),
            Path.join([ctx.agent, "extensions", "evil.ex"]),
            Path.join([ctx.state, "kanban", "repos", "board", "config"]),
            Path.join([ctx.agent, "skill", "evil", "SKILL.md"]),
            Path.join([ctx.state, "nodes", "execution", "node-x.json"])
          ] do
        assert {:error, message} = write(ctx.workspace, path, "x"), path
        # Credential locations (the key file, node tokens) are refused by the
        # credential check, which runs first.
        assert message =~ ~r/operator state|Lemon credential file/
        refute File.exists?(path)
      end
    end

    test "write refuses agent state through a symlinked working directory", ctx do
      project = Path.join(ctx.home, "project")
      File.ln_s!(ctx.agent, project)

      assert {:error, message} = write(project, "settings.json", "{}")
      assert message =~ "operator state"
      refute File.exists?(Path.join(ctx.agent, "settings.json"))
    end

    test "write still works in the assistant workspace", ctx do
      assert %AgentToolResult{} = write(ctx.workspace, "notes.md", "hello\n")
      assert File.read!(Path.join(ctx.workspace, "notes.md")) == "hello\n"
    end

    test "edit and anchored edit refuse trust records", ctx do
      trust = Path.join(ctx.agent, "mcp_project_trust.json")

      assert {:error, message} =
               Edit.execute(
                 "edit",
                 %{"path" => trust, "old_text" => "{}", "new_text" => ~s({"x":1})},
                 nil,
                 nil,
                 ctx.workspace,
                 []
               )

      assert message =~ "operator state"

      assert {:error, message} =
               Edit.execute(
                 "edit",
                 %{
                   "path" => trust,
                   "snapshot" => AnchoredEdit.snapshot("{}\n"),
                   "edits" => [%{"start_line" => 1, "new_text" => ~s({"x":1})}]
                 },
                 nil,
                 nil,
                 ctx.workspace,
                 []
               )

      assert message =~ "operator state"
      assert File.read!(trust) == "{}\n"
    end

    test "patch refuses an extension under a home working directory", ctx do
      target = Path.join([ctx.agent, "extensions", "evil.ex"])

      patch = """
      *** Add File: .lemon/agent/extensions/evil.ex
      +defmodule Evil do end
      """

      assert {:error, message} =
               Patch.execute("patch", %{"patch_text" => patch}, nil, nil, ctx.home, [])

      assert message =~ "operator state"
      refute File.exists?(target)
    end

    test "archive writes refuse kanban controller repos", ctx do
      archive = Path.join([ctx.state, "kanban", "repos", "board.zip"])

      assert {:error, message} = write(ctx.workspace, archive <> ":HEAD", "evil")
      assert message =~ "operator state"
      refute File.exists?(archive)
    end

    test "ACP client writes are refused before the client is asked", ctx do
      run_id = "run_operator_state_acp_#{System.unique_integer([:positive])}"
      :ok = LemonCore.ACPClientBridge.register(run_id)
      config = Path.join(ctx.state, "config.toml")

      task =
        Task.async(fn ->
          Write.execute(
            "write",
            %{"path" => config, "content" => "[evil]\n"},
            nil,
            nil,
            ctx.workspace,
            run_id: run_id,
            acp_client_fs_write_text_file: true
          )
        end)

      refute_receive {:acp_client_request, %{method: "fs/write_text_file"}}, 500
      assert {:error, message} = Task.await(task)
      assert message =~ "operator state"
    end

    test "write refuses a hard link to operator state", ctx do
      config = Path.join(ctx.state, "config.toml")
      link = Path.join(ctx.workspace, "settings.toml")
      File.ln!(config, link)

      assert {:error, message} = write(ctx.workspace, "settings.toml", "[evil]\n")
      assert message =~ "hard links"
      assert File.read!(config) == "[runtime]\n"
    end

    test "write refuses a case variant of the state directory", ctx do
      assert {:error, message} =
               write(ctx.workspace, Path.join([ctx.home, ".LEMON", "Config.toml"]), "[evil]\n")

      assert message =~ "operator state"
      assert File.read!(Path.join(ctx.state, "config.toml")) == "[runtime]\n"
    end

    test "a .lemon directory inside the assistant workspace stays protected", ctx do
      target = Path.join([ctx.workspace, ".lemon", "skill", "evil", "SKILL.md"])

      assert {:error, message} = write(ctx.workspace, ".lemon/skill/evil/SKILL.md", "x")
      assert message =~ "operator state"
      refute File.exists?(target)
    end

    test "write local:// keeps the session's own scratch directory", ctx do
      session_id = "operator-state-local-#{System.unique_integer([:positive])}"

      assert %AgentToolResult{details: %{path: path}} =
               write(ctx.workspace, "local://notes.md", "scratch\n", session_id: session_id)

      assert String.starts_with?(path, ctx.agent)
      assert File.read!(path) == "scratch\n"
    end
  end

  describe "cron memory" do
    test "a cron run's grant admits only its own memory file", ctx do
      own = Path.join([ctx.state, "cron_memory", "job-a.md"])
      other = Path.join([ctx.state, "cron_memory", "job-b.md"])

      assert {:error, message} = write(ctx.workspace, own, "# tampered\n")
      assert message =~ "operator state"

      assert %AgentToolResult{} =
               write(ctx.workspace, own, "# job a\nfinding\n", operator_state_grant: own)

      assert File.read!(own) == "# job a\nfinding\n"

      assert {:error, _} = write(ctx.workspace, other, "# tampered\n", operator_state_grant: own)
      assert File.read!(other) == "# job b\n"

      config = Path.join(ctx.state, "config.toml")
      assert {:error, _} = write(ctx.workspace, config, "[evil]\n", operator_state_grant: config)
      assert File.read!(config) == "[runtime]\n"
    end
  end

  describe "toolchain directories" do
    test "write refuses ~/.local/bin, ~/bin and checker directories on PATH", ctx do
      for path <- [
            Path.join([ctx.home, ".local", "bin", "git"]),
            Path.join([ctx.home, "bin", "gh"]),
            Path.join(ctx.toolchain, "node")
          ] do
        assert {:error, message} = write(ctx.workspace, path, "#!/bin/sh\n"), path
        assert message =~ "operator state"
        refute File.exists?(path)
      end

      assert {:error, _} = write(ctx.workspace, Path.join(ctx.toolchain, "prettier"), "evil")
      assert File.read!(Path.join(ctx.toolchain, "prettier")) == "#!/bin/sh\nexit 0\n"
    end

    test "write refuses the configured git_path directory", ctx do
      git_dir = Path.join(ctx.home, "gitbin")
      git = Path.join(git_dir, "git")
      File.mkdir_p!(git_dir)
      File.write!(git, "#!/bin/sh\n")
      File.chmod!(git, 0o755)
      File.write!(Path.join(ctx.state, "config.toml"), "[runtime]\ngit_path = #{inspect(git)}\n")
      assert {:ok, ^git} = LemonCore.SafeGit.executable()

      assert {:error, message} = write(ctx.workspace, Path.join(git_dir, "git-upload-pack"), "x")
      assert message =~ "operator state"
    end
  end

  describe "checkpoint restore" do
    test "a checkpoint forged through write cannot restore operator state", ctx do
      session_id = "operator-state-#{System.unique_integer([:positive])}"
      on_exit(fn -> LemonCore.Checkpoint.delete_all(session_id) end)

      config = Path.join(ctx.state, "config.toml")
      id = "chk_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      forged = Path.join(LemonCore.Checkpoint.checkpoint_dir(), id <> ".json")

      write(ctx.workspace, forged, forged_checkpoint(id, session_id, config, "[evil]\n"))

      FsCheckpoint.execute(
        "restore",
        %{"action" => "restore", "checkpoint_id" => id},
        nil,
        nil,
        ctx.workspace,
        session_id: session_id
      )

      assert File.read!(config) == "[runtime]\n"
    end

    test "restore refuses operator-state roots in a checkpoint file", ctx do
      session_id = "operator-state-#{System.unique_integer([:positive])}"
      on_exit(fn -> LemonCore.Checkpoint.delete_all(session_id) end)

      config = Path.join(ctx.state, "config.toml")
      id = "chk_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      File.mkdir_p!(LemonCore.Checkpoint.checkpoint_dir())

      File.write!(
        Path.join(LemonCore.Checkpoint.checkpoint_dir(), id <> ".json"),
        forged_checkpoint(id, session_id, config, "[evil]\n")
      )

      assert {:error, message} =
               FsCheckpoint.execute(
                 "restore",
                 %{"action" => "restore", "checkpoint_id" => id},
                 nil,
                 nil,
                 ctx.workspace,
                 session_id: session_id
               )

      assert message =~ "operator state"
      assert File.read!(config) == "[runtime]\n"
    end

    test "restore refuses a root that contains operator state", ctx do
      session_id = "operator-state-#{System.unique_integer([:positive])}"
      on_exit(fn -> LemonCore.Checkpoint.delete_all(session_id) end)

      id = "chk_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
      File.mkdir_p!(LemonCore.Checkpoint.checkpoint_dir())

      # An empty directory snapshot of the home directory would remove ~/.lemon.
      checkpoint =
        ctx.home
        |> forged_checkpoint_map(id, session_id, %{
          path: ctx.home,
          exists: true,
          type: "directory",
          mode: 0o40755,
          entries: []
        })
        |> Jason.encode!()

      File.write!(Path.join(LemonCore.Checkpoint.checkpoint_dir(), id <> ".json"), checkpoint)

      assert {:error, message} =
               FsCheckpoint.execute(
                 "restore",
                 %{"action" => "restore", "checkpoint_id" => id},
                 nil,
                 nil,
                 ctx.workspace,
                 session_id: session_id
               )

      assert message =~ "operator state"
      assert File.read!(Path.join(ctx.state, "config.toml")) == "[runtime]\n"
    end
  end

  describe "review hardening" do
    test "explicit toolchain roots inside the assistant workspace stay protected", ctx do
      bin = Path.join(ctx.workspace, "toolchain")
      File.mkdir_p!(bin)
      checker = Path.join(bin, "black")
      File.write!(checker, "#!/bin/sh\n")
      File.chmod!(checker, 0o755)
      System.put_env("PATH", bin <> ":" <> System.get_env("PATH"))

      assert {:error, message} = write(ctx.workspace, "toolchain/black", "evil")
      assert message =~ "operator state"
      assert {:error, _} = write(ctx.workspace, "toolchain/gofmt", "evil")
      assert %AgentToolResult{} = write(ctx.workspace, "notes.md", "fine\n")
    end

    test "a checker's resolved target and its directory are protected", ctx do
      real_dir = Path.join([ctx.home, "lib", "node_modules", "prettier", "bin"])
      File.mkdir_p!(real_dir)
      real = Path.join(real_dir, "prettier.cjs")
      File.write!(real, "#!/bin/sh\n")
      File.chmod!(real, 0o755)
      link_dir = Path.join(ctx.home, "nodebin")
      File.mkdir_p!(link_dir)
      File.ln_s!(real, Path.join(link_dir, "prettier"))
      System.put_env("PATH", link_dir <> ":" <> System.get_env("PATH"))

      assert {:error, message} = write(ctx.workspace, real, "evil")
      assert message =~ "operator state"
      assert {:error, _} = write(ctx.workspace, Path.join(real_dir, "helper.cjs"), "evil")
      assert File.read!(real) == "#!/bin/sh\n"
    end

    test "operator-configured extension roots are protected", ctx do
      ext = Path.join(ctx.home, "my-extensions")
      File.mkdir_p!(ext)

      File.write!(
        Path.join(ctx.state, "config.toml"),
        "[runtime]\nextension_paths = [#{inspect(ext)}]\n"
      )

      assert {:error, message} = write(ctx.workspace, Path.join(ext, "evil.ex"), "x")
      assert message =~ "operator state"
    end

    test "a cron grant is exact: a case-distinct name is not granted", ctx do
      own = Path.join([ctx.state, "cron_memory", "job-a.md"])
      other = Path.join([ctx.state, "cron_memory", "JOB-A.md"])

      assert {:error, _} = write(ctx.workspace, other, "# x\n", operator_state_grant: own)
      assert File.read!(own) == "# job a\n"
    end

    test "local:// scratch keeps the hard-link refusal", ctx do
      session_id = "operator-state-alias-#{System.unique_integer([:positive])}"

      assert %AgentToolResult{details: %{path: path}} =
               write(ctx.workspace, "local://alias.md", "scratch\n", session_id: session_id)

      File.rm!(path)
      File.ln!(Path.join(ctx.state, "config.toml"), path)

      assert {:error, message} =
               write(ctx.workspace, "local://alias.md", "[evil]\n", session_id: session_id)

      assert message =~ "hard links"
      assert File.read!(Path.join(ctx.state, "config.toml")) == "[runtime]\n"
    end

    test "browser downloads refuse operator state under the project", ctx do
      tool =
        CodingAgent.Tools.BrowserDownload.tool(ctx.home,
          browser_request: fn _, _, _ -> flunk("download must not start") end
        )

      assert {:error, _} =
               tool.execute.(
                 "d",
                 %{"selector" => "#a", "path" => ".lemon/config.toml"},
                 nil,
                 fn _ -> :ok end
               )

      assert File.read!(Path.join(ctx.state, "config.toml")) == "[runtime]\n"
    end

    test "a registry-built browser_analyze refuses a media directory aliased into operator state",
         ctx do
      target = Path.join(ctx.state, "media")
      File.mkdir_p!(target)
      File.ln_s!(target, Path.join(ctx.workspace, "media-link"))

      request = fn "browser.screenshot", _args, _timeout ->
        {:ok,
         %{
           "url" => "https://example.test/",
           "contentType" => "image/png",
           "base64" => Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10>>)
         }}
      end

      resolution = %{requested: "auto", provider: "tern", reason: "test", checks: %{}}

      tool =
        ToolRegistry.get_tool(ctx.workspace, "browser_analyze",
          include_extensions: false,
          include_mcp: false,
          browser_provider_resolution: resolution,
          browser_request: request,
          tool_intent_recorder: CodingAgent.Test.ToolIntentRecorder.new(ctx.workspace),
          media_artifacts_dir: Path.join(ctx.workspace, "media-link")
        )
        |> elem(1)

      result =
        tool.execute.(
          "analyze",
          %{"path" => "shot.png", "provider" => "local_vision", "filename" => "evil"},
          nil,
          fn _ -> :ok end
        )

      assert {:error, message} = result
      assert message =~ "Refusing to modify"
      assert message =~ "Lemon operator state"
      assert File.ls!(target) == []
    end

    test "media artifacts honour the output guard and never write through aliases", ctx do
      alias LemonSkills.Tools.MediaCommon
      guard = &CodingAgent.Tools.OperatorState.check_mutation/1

      assert {:error, message} =
               MediaCommon.artifact_path(
                 %{"filename" => "x.png"},
                 ctx.home,
                 [media_artifacts_dir: Path.join(ctx.state, "media"), output_guard: guard],
                 "png",
                 "media"
               )

      assert message =~ "operator state"

      out = Path.join(ctx.workspace, "media")
      File.mkdir_p!(out)
      config = Path.join(ctx.state, "config.toml")
      File.ln!(config, Path.join(out, "hard.png"))
      File.ln_s!(config, Path.join(out, "soft.png"))

      for name <- ["hard.png", "soft.png"] do
        assert :ok = MediaCommon.write_artifact(Path.join(out, name), "png")
        assert File.read!(Path.join(out, name)) == "png"
      end

      assert File.read!(config) == "[runtime]\n"
    end
  end

  describe "bash" do
    test "a command naming operator state needs a one-time approval, even unreviewed", ctx do
      for command <- [
            "echo x >> ~/.lemon/config.toml",
            "echo x >> ${HOME}/.LEMON/config.toml",
            "cp evil \"$HOME/.local/bin/git\"",
            "cd ~ && sed -i '' s/a/b/ .lemon/agent/settings.json",
            "cat > #{ctx.agent}/extensions/evil.ex"
          ] do
        assert {:asked, request} = gated_bash(%{"command" => command}, ctx.workspace), command
        assert request.once_only == true
      end

      assert {:asked, _} =
               gated_bash(%{"command" => "touch x", "cwd" => ctx.agent}, ctx.workspace)

      assert {:asked, _} =
               gated_bash(
                 %{"command" => "cp evil \"$TARGET\"", "env" => %{"TARGET" => ctx.state}},
                 ctx.workspace
               )

      assert {:asked, _} = gated_bash(%{"command" => "echo x > ../settings.json"}, ctx.workspace)
    end

    test "an ordinary command stays unreviewed", ctx do
      assert :ran = gated_bash(%{"command" => "ls -la && cat notes.md"}, ctx.workspace)
    end
  end

  defp write(cwd, path, content, opts \\ []),
    do: Write.execute("write", %{"path" => path, "content" => content}, nil, nil, cwd, opts)

  defp gated_bash(params, cwd) do
    parent = self()

    tool = %AgentTool{
      name: "bash",
      label: "Run Command",
      description: "bash",
      parameters: %{"type" => "object", "properties" => %{}},
      execute: fn _id, _params, _signal, _update ->
        send(parent, :ran)
        %AgentToolResult{content: [%TextContent{text: "ran"}]}
      end
    }

    [{"bash", gated, :builtin}] =
      ToolRegistry.gate_tuples(
        [{"bash", tool, :builtin}],
        ToolPolicy.parse!(%{approval_mode: :yolo}),
        %{
          cwd: cwd,
          approval_request_fun: fn request ->
            send(parent, {:asked, request})
            {:ok, :denied}
          end
        }
      )

    gated.execute.("call", params, nil, nil)

    receive do
      {:asked, request} -> {:asked, request}
      :ran -> :ran
    after
      0 -> flunk("neither asked nor ran")
    end
  end

  defp forged_checkpoint(id, session_id, path, content) do
    path
    |> forged_checkpoint_map(id, session_id, %{
      path: path,
      exists: true,
      type: "regular",
      size: byte_size(content),
      mode: 0o100644,
      content_b64: Base.encode64(content)
    })
    |> Jason.encode!()
  end

  defp forged_checkpoint_map(path, id, session_id, snapshot) do
    %{
      id: id,
      session_id: session_id,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      state: %{filesystem: %{cwd: Path.dirname(path), roots: [path], files: [snapshot]}},
      context: %{},
      todos: [],
      metadata: %{kind: "filesystem", tool: "write"}
    }
  end
end
