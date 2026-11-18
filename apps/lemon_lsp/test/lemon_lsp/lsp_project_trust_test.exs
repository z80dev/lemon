defmodule LemonLsp.ProjectTrustTest do
  @moduledoc """
  Language-server executables are operator authority. A repository's
  `.lemon/config.toml` cannot add a server command, re-enable an operator-
  disabled server or change its argv/environment. Each case asks the real
  server manager to start a session and checks that a marker script never ran.
  """
  use ExUnit.Case, async: false

  alias LemonLsp.{ServerManager, Servers}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    global = Path.join(tmp, "home/.lemon/config.toml")
    project = Path.join(tmp, "project")
    File.mkdir_p!(Path.dirname(global))
    File.mkdir_p!(Path.join(project, ".lemon"))
    saved_paths = Application.get_env(:lemon_core, :paths)
    Application.put_env(:lemon_core, :paths, global_config: global)

    on_exit(fn ->
      if saved_paths,
        do: Application.put_env(:lemon_core, :paths, saved_paths),
        else: Application.delete_env(:lemon_core, :paths)
    end)

    marker = Path.join(tmp, "evil-lsp.ran")
    script = Path.join(tmp, "evil-lsp")
    File.write!(script, "#!/bin/sh\n: > \"#{marker}\"\nsleep 5\n")
    File.chmod!(script, 0o700)

    %{global: global, project: project, script: script, marker: marker}
  end

  defp configure(ctx, global, project) do
    File.write!(ctx.global, global)
    File.write!(Path.join(ctx.project, ".lemon/config.toml"), project)
    LemonCore.ConfigCache.invalidate(ctx.project)
  end

  defp start(ctx, id) do
    result = ServerManager.start_session(id, cwd: ctx.project)

    with {:ok, %{session_id: session_id}} <- result do
      ServerManager.stop_session(session_id)
    end

    Process.sleep(200)
    result
  end

  test "a project-defined server command is never started", ctx do
    configure(ctx, "", """
    [runtime.tools.lsp.servers.evil]
    command = "#{ctx.script}"
    extensions = [".evil"]
    """)

    assert {:error, :unknown_lsp_server} = Servers.resolve_command("evil", ctx.project)
    start(ctx, "evil")
    refute File.exists?(ctx.marker)
  end

  test "a project cannot re-enable or repoint an operator-disabled builtin", ctx do
    configure(
      ctx,
      """
      [runtime.tools.lsp.servers.clangd]
      disabled = true
      """,
      """
      [runtime.tools.lsp.servers.clangd]
      disabled = false
      command = "#{ctx.script}"
      env = { LD_PRELOAD = "#{ctx.script}" }
      """
    )

    assert {:error, :unknown_lsp_server} = Servers.resolve_command(:clangd, ctx.project)
    start(ctx, :clangd)
    refute File.exists?(ctx.marker)
  end

  test "a project may disable a server but not change its argv", ctx do
    configure(
      ctx,
      """
      [runtime.tools.lsp.servers.clangd]
      command = "/bin/cat"
      args = ["--operator"]
      """,
      """
      [runtime.tools.lsp.servers.clangd]
      args = ["--project"]
      """
    )

    assert {:ok, command} = Servers.resolve_command(:clangd, ctx.project)
    assert command.executable == "/bin/cat"
    assert command.args == ["--operator"]

    configure(
      ctx,
      """
      [runtime.tools.lsp.servers.clangd]
      command = "/bin/cat"
      """,
      """
      [runtime.tools.lsp.servers.clangd]
      disabled = true
      """
    )

    assert {:error, :unknown_lsp_server} = Servers.resolve_command(:clangd, ctx.project)
  end
end
