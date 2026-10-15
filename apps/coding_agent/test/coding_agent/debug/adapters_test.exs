defmodule CodingAgent.Debug.AdaptersTest do
  use ExUnit.Case, async: false

  alias CodingAgent.Debug.Adapters

  @moduletag :tmp_dir

  test "new adapters retain extension selection and explicit overrides", %{tmp_dir: tmp} do
    previous = System.get_env("PATH")

    for name <- ["js-debug-adapter", "codelldb", "netcoredbg", "rdbg"] do
      path = Path.join(tmp, name)
      File.write!(path, "#!/bin/sh\nexit 0\n")
      File.chmod!(path, 0o755)
    end

    System.put_env("PATH", tmp <> ":" <> previous)
    on_exit(fn -> System.put_env("PATH", previous) end)

    for {extension, name, mode} <- [
          {".ts", "js-debug", :socket_server},
          {".cs", "netcoredbg", :stdio},
          {".rb", "rdbg", :socket_server}
        ] do
      assert {:ok, adapter} =
               Adapters.select_launch(Path.join(tmp, "program" <> extension), tmp, nil, :file)

      assert adapter.name == name
      assert adapter.connect_mode == mode
    end

    assert {:ok, adapter} =
             Adapters.select_launch(Path.join(tmp, "program.rs"), tmp, "codelldb", :file)

    assert adapter.name == "codelldb"
    assert adapter.args == ["--port", "{port}"]
    assert {:ok, remote} = Adapters.select_attach("rdbg", 1234)
    assert remote.connect_mode == :remote
    assert remote.command == nil
  end
end
