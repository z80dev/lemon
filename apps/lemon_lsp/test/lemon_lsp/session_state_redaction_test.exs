defmodule LemonLsp.SessionStateRedactionTest do
  use ExUnit.Case, async: false

  alias LemonLsp.ServerManager

  @env "LEMON_LSP_ELIXIR_LS_COMMAND"

  setup do
    tmp_dir =
      Path.join(System.tmp_dir!(), "lsp_redaction_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp_dir, ".lemon"))
    secret = "lsp-secret-#{System.unique_integer([:positive])}-#{:erlang.phash2(make_ref())}"

    # Server initialization options are operator-only: the global config sets
    # them, a project `.lemon/config.toml` cannot.
    global_config = Path.join(tmp_dir, "global-config.toml")

    File.write!(global_config, """
    [runtime.tools.lsp]
    idle_timeout_ms = 0

    [runtime.tools.lsp.servers.elixir_ls]
    initialization_options = { token = "#{secret}" }
    """)

    previous_paths = Application.get_env(:lemon_core, :paths)

    Application.put_env(
      :lemon_core,
      :paths,
      Keyword.put(previous_paths || [], :global_config, global_config)
    )

    LemonCore.ConfigCache.invalidate(tmp_dir)

    record_path = Path.join(tmp_dir, "init_options.json")
    server_path = Path.join(tmp_dir, "fake_server.exs")
    File.write!(server_path, fake_server_script(record_path))
    File.chmod!(server_path, 0o755)

    previous = System.get_env(@env)
    System.put_env(@env, server_path)
    session_id = "lsp-redaction-test-#{System.unique_integer([:positive])}"

    on_exit(fn ->
      _ = ServerManager.stop_session(session_id)
      if previous, do: System.put_env(@env, previous), else: System.delete_env(@env)

      if is_nil(previous_paths),
        do: Application.delete_env(:lemon_core, :paths),
        else: Application.put_env(:lemon_core, :paths, previous_paths)

      File.rm_rf!(tmp_dir)
    end)

    if System.find_executable("elixir") do
      {:ok, tmp_dir: tmp_dir, session_id: session_id, secret: secret, record_path: record_path}
    else
      {:skip, "elixir executable is not on PATH"}
    end
  end

  test "initialization options never sit in session process state", ctx do
    assert {:ok, _} =
             ServerManager.start_session(:elixir_ls, cwd: ctx.tmp_dir, session_id: ctx.session_id)

    [{pid, _}] =
      Registry.lookup(
        LemonLsp.SessionRegistry,
        {:id, Process.whereis(ServerManager), ctx.session_id}
      )

    refute_secret(pid, ctx.secret)

    task =
      Task.async(fn ->
        ServerManager.initialize_session(ctx.session_id, %{}, timeout_ms: 20_000)
      end)

    assert wait_for_file(ctx.record_path, 15_000)
    assert File.read!(ctx.record_path) =~ ctx.secret

    refute_secret(pid, ctx.secret)

    assert {:ok, _} = ServerManager.stop_session(ctx.session_id)
    Task.shutdown(task, :brutal_kill)
  end

  defp refute_secret(pid, secret) do
    refute contains_secret?(:sys.get_state(pid), secret)
    refute inspect(:sys.get_status(pid), limit: :infinity, printable_limit: :infinity) =~ secret
  end

  defp wait_for_file(path, timeout) when timeout <= 0, do: File.exists?(path)

  defp wait_for_file(path, timeout) do
    if File.exists?(path) and File.read!(path) != "" do
      true
    else
      receive do
      after
        50 -> wait_for_file(path, timeout - 50)
      end
    end
  end

  defp contains_secret?(term, secret) when is_binary(term), do: String.contains?(term, secret)

  defp contains_secret?(term, secret) when is_tuple(term),
    do: term |> Tuple.to_list() |> contains_secret?(secret)

  defp contains_secret?(term, secret) when is_map(term),
    do:
      Enum.any?(term, fn {k, v} -> contains_secret?(k, secret) or contains_secret?(v, secret) end)

  defp contains_secret?([], _secret), do: false

  defp contains_secret?([head | tail], secret),
    do: contains_secret?(head, secret) or contains_secret?(tail, secret)

  defp contains_secret?(term, secret) when is_function(term) do
    {:env, env} = :erlang.fun_info(term, :env)
    contains_secret?(env, secret)
  end

  defp contains_secret?(_term, _secret), do: false

  defp fake_server_script(record_path) do
    ~S"""
    #!/usr/bin/env elixir
    :io.setopts(:standard_io, encoding: :latin1, binary: true)

    defmodule Fake do
      def read do
        case headers(nil) do
          nil -> nil
          len -> :stdio |> IO.binread(len) |> JSON.decode!()
        end
      end

      defp headers(len) do
        case IO.binread(:stdio, :line) do
          line when is_binary(line) ->
            case String.trim(line) do
              "" -> len
              "Content-Length: " <> n -> headers(String.to_integer(n))
              _ -> headers(len)
            end

          _ ->
            nil
        end
      end

      def loop(record) do
        case read() do
          nil ->
            :ok

          %{"method" => "initialize", "params" => params} ->
            File.write!(record, JSON.encode!(params["initializationOptions"]))
            loop(record)

          _ ->
            loop(record)
        end
      end
    end

    Fake.loop(RECORD_PATH)
    """
    |> String.replace("RECORD_PATH", inspect(record_path))
  end
end
