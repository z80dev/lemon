defmodule LemonLsp.SessionEnvTest do
  # Mutates the BEAM OS environment, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias LemonLsp.ServerManager

  @secrets %{
    "LEMON_CONTROL_PLANE_OPERATOR_TOKEN" => "leak-operator",
    "LEMON_SECRETS_MASTER_KEY" => "leak-master",
    "LEMON_NODE_TOKEN" => "leak-node",
    "RELEASE_COOKIE" => "leak-cookie"
  }

  setup do
    tmp_dir = Path.join(System.tmp_dir!(), "lsp_env_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp_dir)
    names = ["LEMON_LSP_ELIXIR_LS_COMMAND", "LEMON_LSP_PYRIGHT_COMMAND" | Map.keys(@secrets)]
    saved = Map.new(names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      File.rm_rf!(tmp_dir)
    end)

    {:ok, tmp_dir: tmp_dir}
  end

  # elixir_ls carries its own server env (ELS_MODE); pyright carries none.
  for {server, command_env, kept} <- [
        {:elixir_ls, "LEMON_LSP_ELIXIR_LS_COMMAND", ["ELS_MODE=language_server"]},
        {:pyright, "LEMON_LSP_PYRIGHT_COMMAND", []}
      ] do
    test "#{server} servers never inherit Lemon secrets", %{tmp_dir: tmp_dir} do
      dump = Path.join(tmp_dir, "env-#{unquote(server)}")
      script = Path.join(tmp_dir, "server-#{unquote(server)}")

      File.write!(script, """
      #!/bin/sh
      env > #{dump}.tmp && mv #{dump}.tmp #{dump}
      sleep 30
      """)

      File.chmod!(script, 0o755)
      System.put_env(unquote(command_env), script)
      System.put_env(@secrets)
      session_id = "lsp-env-#{unquote(server)}-#{System.unique_integer([:positive])}"
      on_exit(fn -> ServerManager.stop_session(session_id) end)

      assert {:ok, _session} =
               ServerManager.start_session(unquote(server), cwd: tmp_dir, session_id: session_id)

      env = wait_for_dump(dump, 100)
      assert env =~ "PATH="
      for expected <- unquote(kept), do: assert(env =~ expected)

      for {name, value} <- @secrets do
        refute env =~ value, "#{unquote(server)} server inherited #{name}"
      end
    end
  end

  defp wait_for_dump(path, 0), do: flunk("server never wrote #{path}")

  defp wait_for_dump(path, tries) do
    case File.read(path) do
      {:ok, content} when content != "" ->
        content

      _ ->
        Process.sleep(50)
        wait_for_dump(path, tries - 1)
    end
  end
end
