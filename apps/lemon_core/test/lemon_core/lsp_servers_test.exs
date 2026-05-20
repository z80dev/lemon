defmodule LemonCore.LspServersTest do
  use ExUnit.Case, async: false

  alias LemonCore.LspServers

  describe "list/0" do
    test "exposes redacted language server metadata" do
      servers = LspServers.list()

      assert length(servers) == 6
      assert Enum.any?(servers, &(&1.id == :elixir_ls))
      assert Enum.any?(servers, &(&1.id == :typescript_language_server))
      assert Enum.any?(servers, &(&1.id == :pyright))
      assert Enum.any?(servers, &(&1.id == :rust_analyzer))
      assert Enum.any?(servers, &(&1.id == :gopls))
      assert Enum.any?(servers, &(&1.id == :clangd))

      for server <- servers do
        assert server.protocol == :lsp_stdio
        assert server.supervised == true
        assert server.running == false
        assert is_boolean(server.available)
        assert is_binary(server.command)
        assert is_integer(server.args_count)
        assert is_binary(server.install_hint)
        refute Map.has_key?(server, :executable_path)
      end
    end
  end

  describe "validate/1" do
    test "normalizes known server ids without creating atoms" do
      assert LspServers.validate(:elixir_ls) == {:ok, :elixir_ls}
      assert LspServers.validate("elixir-ls") == {:ok, :elixir_ls}

      assert LspServers.validate("TYPESCRIPT_LANGUAGE_SERVER") ==
               {:ok, :typescript_language_server}

      assert LspServers.validate("rust-analyzer") == {:ok, :rust_analyzer}
      assert LspServers.validate("unknown-server") == {:error, :unknown_lsp_server}
    end
  end

  describe "diagnostics/0" do
    test "returns redacted registry diagnostics" do
      diagnostics = LspServers.diagnostics()

      assert diagnostics.count == 6
      assert diagnostics.mode == :registry_only
      assert diagnostics.protocol == :lsp_stdio
      assert diagnostics.available_count + diagnostics.missing_count == 6
      assert diagnostics.cleanup.includes_executable_paths == false
      assert diagnostics.cleanup.includes_workspace_roots == false
      assert diagnostics.cleanup.includes_file_contents == false
      assert diagnostics.cleanup.includes_diagnostics_output == false
    end
  end

  test "redacts configured executable paths to command basenames" do
    previous = System.get_env("LEMON_LSP_PYRIGHT_COMMAND")

    on_exit(fn ->
      if previous do
        System.put_env("LEMON_LSP_PYRIGHT_COMMAND", previous)
      else
        System.delete_env("LEMON_LSP_PYRIGHT_COMMAND")
      end
    end)

    System.put_env("LEMON_LSP_PYRIGHT_COMMAND", "/private/bin/pyright-langserver")

    assert {:ok, server} = LspServers.get(:pyright)
    assert server.configured == true
    assert server.command == "pyright-langserver"
    refute inspect(server) =~ "/private/bin"
  end

  test "resolves command paths only through the runtime API" do
    cat = System.find_executable("cat")

    if cat do
      previous = System.get_env("LEMON_LSP_ELIXIR_LS_COMMAND")

      on_exit(fn ->
        if previous do
          System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", previous)
        else
          System.delete_env("LEMON_LSP_ELIXIR_LS_COMMAND")
        end
      end)

      System.put_env("LEMON_LSP_ELIXIR_LS_COMMAND", cat)

      assert {:ok, command} = LspServers.resolve_command(:elixir_ls)
      assert command.executable == cat
      assert command.command == "cat"
      assert command.env == %{"ELS_MODE" => "language_server"}
      assert command.server.command == "cat"
      refute Map.has_key?(command.server, :executable_path)
    end
  end
end
