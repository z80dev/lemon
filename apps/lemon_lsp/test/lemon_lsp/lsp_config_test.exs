defmodule LemonLsp.ConfigTest do
  use ExUnit.Case, async: false

  alias LemonCore.Config
  alias LemonCore.Config.ValidationError
  alias LemonLsp.Servers

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    home = Path.join(tmp, "home")
    project = Path.join(tmp, "project")
    File.mkdir_p!(Path.join(home, ".lemon"))
    File.mkdir_p!(Path.join(project, ".lemon"))
    old_home = System.get_env("HOME")
    System.put_env("HOME", home)

    on_exit(fn ->
      if old_home, do: System.put_env("HOME", old_home), else: System.delete_env("HOME")
    end)

    %{global: Path.join(home, ".lemon/config.toml"), project: project}
  end

  test "project overrides global fields and preserves unspecified fields", ctx do
    File.write!(ctx.global, """
    [runtime.tools.lsp.servers.clangd]
    command = "/bin/cat"
    args = ["global"]
    root_markers = ["custom.root"]
    env = { LSP_TEST = "global" }
    initialization_options = { index = true }
    """)

    write_project(ctx, """
    [runtime.tools.lsp.servers.clangd]
    args = ["project", "--stdio"]
    env = { LSP_TEST = "project" }
    """)

    assert {:ok, command} = Servers.resolve_command(:clangd, ctx.project)
    assert command.executable == "/bin/cat"
    assert command.args == ["project", "--stdio"]
    assert command.env == %{"LSP_TEST" => "project"}
    assert command.initialization_options == %{"index" => true}
    assert command.server.root_markers == ["custom.root"]
  end

  test "disabled servers disappear from every lookup", ctx do
    write_project(ctx, """
    [runtime.tools.lsp.servers.clangd]
    disabled = true
    """)

    refute Enum.any?(Servers.list(ctx.project), &(&1.id == :clangd))
    assert {:error, :unknown_lsp_server} = Servers.get(:clangd, ctx.project)
    assert {:error, :unknown_lsp_server} = Servers.resolve_command(:clangd, ctx.project)
    assert Servers.language_id("file.c", ctx.project) == "plaintext"
  end

  test "custom servers use string ids and normalized file types", ctx do
    for id <- ["my_language", "my-language"] do
      write_project(ctx, """
      [runtime.tools.lsp.servers.#{id}]
      command = "/bin/cat"
      file_types = ["NEWLANG"]
      language_id = "new-language"
      args = ["--stdio"]
      """)

      assert {:ok, server} = Servers.get(id, ctx.project)
      assert server.id == id
      assert server.extensions == [".newlang"]
      assert Servers.language_id("file.NEWLANG", ctx.project) == "new-language"
      assert {:ok, ^id} = Servers.validate(id, ctx.project)
      assert {:ok, %{args: ["--stdio"]}} = Servers.resolve_command(id, ctx.project)
    end
  end

  test "invalid field types are rejected by the config validator", ctx do
    for {field, value} <- [
          {"command", "23"},
          {"args", "\"--stdio\""},
          {"extensions", "[42]"},
          {"root_markers", "false"},
          {"language_id", "false"},
          {"initialization_options", "[]"},
          {"env", "{ TOKEN = 42 }"},
          {"disabled", "\"true\""}
        ] do
      write_project(ctx, "[runtime.tools.lsp.servers.clangd]\n#{field} = #{value}\n")

      assert_raise ValidationError, ~r/runtime.tools.lsp.servers.clangd.#{field}/, fn ->
        Config.reload(ctx.project)
      end
    end
  end

  test "custom servers require command and extensions", ctx do
    write_project(ctx, "[runtime.tools.lsp.servers.incomplete]\nargs = []\n")

    assert_raise ValidationError, ~r/custom servers require command and extensions/, fn ->
      Config.reload(ctx.project)
    end
  end

  test "idle timeout requires a non-negative integer", ctx do
    for value <- ["-1", "\"short\""] do
      write_project(ctx, "[runtime.tools.lsp]\nidle_timeout_ms = #{value}\n")

      assert_raise ValidationError, ~r/runtime.tools.lsp.idle_timeout_ms/, fn ->
        Config.reload(ctx.project)
      end
    end
  end

  defp write_project(ctx, text) do
    File.write!(Path.join(ctx.project, ".lemon/config.toml"), text)
    LemonCore.ConfigCache.invalidate(ctx.project)
  end
end
