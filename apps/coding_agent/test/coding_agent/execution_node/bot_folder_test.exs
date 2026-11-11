defmodule CodingAgent.ExecutionNode.BotFolderTest do
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.{BotFolder, HostIO, Worker}
  alias LemonCore.{ExecutionContext, ProfileStore}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.get_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, home_state_dir: Path.join(tmp, ".lemon"))
    on_exit(fn ->
      if previous, do: Application.put_env(:lemon_core, :paths, previous),
        else: Application.delete_env(:lemon_core, :paths)
    end)
    %{state: %Worker{name: "folder-test", default_cwd: tmp},
      opts: [default_cwd: tmp, allowed_roots: [tmp]]}
  end

  test "worker derives a private folder and trusted config root", %{state: state} do
    assert {:ok, request, opts} = Worker.execution_request(args(), state, "folder")
    assert {:ok, paths} = ProfileStore.paths("folder-test")
    assert request.cwd == paths["files"]
    assert request.execution_context.workspace_scope.root == request.cwd
    assert opts.bot_folder_root == request.cwd
    assert opts.config_cwd == state.default_cwd
    assert Bitwise.band(File.stat!(request.cwd).mode, 0o777) == 0o700
  end

  test "mode rejects explicit cwd, invalid id and unknown mode", %{state: state} do
    for request <- [Map.put(args(), "cwd", state.default_cwd),
                    put_in(args(), ["meta", "profile_id"], "../escape"),
                    Map.put(args(), "cwdMode", "other")] do
      assert {:error, :invalid_cwd} = Worker.execution_request(request, state, "folder")
    end
  end

  test "old requests do not gain trusted folder authority", %{state: state} do
    request = args() |> Map.delete("cwdMode")
      |> put_in(["meta", "bot_folder_root"], state.default_cwd)
    assert {:ok, execution, opts} = Worker.execution_request(request, state, "folder")
    assert execution.cwd == state.default_cwd
    refute Map.has_key?(opts, :bot_folder_root)
    refute Map.has_key?(opts, :config_cwd)
  end

  test "folder refuses symlink roots", %{tmp_dir: tmp} do
    assert {:ok, paths} = ProfileStore.paths("folder-test")
    File.mkdir_p!(paths["home"])
    File.ln_s!(tmp, paths["files"])
    assert {:error, :invalid_cwd} = BotFolder.ensure("folder-test")
  end

  test "profile file RPCs use the folder but preserve absolute paths and roots", ctx do
    assert {:ok, root} = BotFolder.ensure("folder-test")
    File.write!(Path.join(root, "report.txt"), "report")
    File.write!(Path.join(ctx.tmp_dir, "outside.txt"), "outside")
    File.mkdir_p!(Path.join(ctx.tmp_dir, "different"))
    assert {:ok, _} = HostIO.handle("node.fs.stat", %{"profileId" => "folder-test", "path" => "report.txt"}, ctx.opts)
    assert {:error, :path_not_allowed} = HostIO.handle("node.fs.stat", %{"profileId" => "folder-test", "path" => "../config.toml"}, ctx.opts)
    assert {:ok, _} = HostIO.handle("node.fs.stat", %{"profileId" => "folder-test", "path" => Path.join(ctx.tmp_dir, "outside.txt")}, ctx.opts)
    assert {:error, :invalid_request} = HostIO.handle("node.fs.stat", %{"profileId" => "../escape", "path" => "report.txt"}, ctx.opts)
    assert {:error, :path_not_allowed} = HostIO.handle("node.fs.stat", %{"profileId" => "folder-test", "path" => "report.txt"}, allowed_roots: [Path.join(ctx.tmp_dir, "different")])
  end

  test "profile write and mkdir create the private folder", ctx do
    assert {:ok, _} =
             HostIO.handle("node.fs.mkdir",
               %{"profileId" => "folder-test", "path" => "inputs"}, ctx.opts)

    assert {:ok, _} =
             HostIO.handle("node.fs.write",
               %{"profileId" => "folder-test", "path" => "inputs/upload",
                 "dataBase64" => Base.encode64("attachment")}, ctx.opts)

    assert {:ok, paths} = ProfileStore.paths("folder-test")
    assert File.read!(Path.join(paths["files"], "inputs/upload")) == "attachment"
    assert Bitwise.band(File.stat!(paths["files"]).mode, 0o777) == 0o700

    assert {:ok, _} =
             HostIO.handle("node.fs.read",
               %{"profileId" => "folder-test", "path" => "inputs/upload"}, ctx.opts)

    assert {:ok, _} =
             HostIO.handle("node.fs.list",
               %{"profileId" => "folder-test", "path" => "inputs"}, ctx.opts)
  end

  test "Bot-written project policy is not loaded as destination config", %{state: state} do
    assert {:ok, request, opts} = Worker.execution_request(args(), state, "folder")
    File.mkdir_p!(Path.join(request.cwd, ".lemon"))
    File.write!(Path.join(request.cwd, ".lemon/config.toml"), """
    [profiles.folder-test.tool_policy]
    deny = ["read"]
    """)

    policy = CodingAgent.Executor.SessionRunner.execution_tool_policy(request, request.cwd, opts)
    assert LemonCore.ToolPolicy.allowed?(policy, "read")

    untrusted = CodingAgent.Executor.SessionRunner.execution_tool_policy(request, request.cwd)
    refute LemonCore.ToolPolicy.allowed?(untrusted, "read")
  end

  defp args do
    {:ok, context} = ExecutionContext.new(run_id: "folder", cwd: "/controller")
    {:ok, context} = ExecutionContext.for_remote(context, nil)
    {:ok, context} = ExecutionContext.encode(context)
    %{"version" => 2, "runId" => "folder", "prompt" => "work",
      "cwdMode" => "profile_files", "meta" => %{"profile_id" => "folder-test"},
      "executionContext" => context}
  end
end
