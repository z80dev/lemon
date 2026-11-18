defmodule CodingAgent.ExecutionNode.CredentialEnvTest do
  # Mutates the BEAM OS environment, so it cannot run concurrently.
  use ExUnit.Case, async: false

  alias CodingAgent.ExecutionNode.{CLI, HostCommand, ProcessService, PTY}
  alias LemonCore.Store

  @credentials %{
    "LEMON_NODE_OPERATOR_TOKEN" => "leak-operator",
    "LEMON_NODE_TOKEN" => "leak-node",
    "LEMON_SECRETS_MASTER_KEY" => "leak-master",
    "LEMON_OPENAI_API_KEY" => "leak-api"
  }

  defmodule CaptureSocket do
    def start_link(opts) do
      send(:persistent_term.get({__MODULE__, :test}), {:connect, opts[:connect_params]})
      {:error, :fixture_socket_unavailable}
    end
  end

  setup do
    saved = Map.new(Map.keys(@credentials), &{&1, System.get_env(&1)})
    original = Application.fetch_env(:lemon_core, :require_owned_loopback)

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)

      case original do
        {:ok, value} -> Application.put_env(:lemon_core, :require_owned_loopback, value)
        :error -> Application.delete_env(:lemon_core, :require_owned_loopback)
      end
    end)

    :ok
  end

  defp leak_credentials, do: System.put_env(@credentials)

  defp refute_leak(output) do
    for {name, value} <- @credentials do
      refute String.contains?(output, name), "child environment exposes #{name}"
      refute String.contains?(output, value), "child environment exposes #{name}'s value"
    end
  end

  defp run_cli(argv, root) do
    :persistent_term.put({CaptureSocket, :test}, self())

    CLI.run(
      argv ++ ["--name", "env-fixture", "--controller", "ws://127.0.0.1:4044/ws", "--cwd", root],
      configure_state: fn _ -> :ok end,
      ensure_all_started: fn _ ->
        # The runtime (and every child it could spawn) starts after the scrub.
        send(self(), {:runtime_env, System.get_env()})
        {:ok, []}
      end,
      socket_module: CaptureSocket,
      status_writer: fn _, _ -> :ok end,
      token_store_opts: [root: Path.join(root, "tokens")]
    )
  end

  @tag :tmp_dir
  test "node join consumes env pairing credentials and removes them from the BEAM env",
       %{tmp_dir: root} do
    leak_credentials()
    _ = run_cli(["--pair"], root)

    assert_received {:runtime_env, runtime_env}

    refute Map.has_key?(runtime_env, "LEMON_NODE_OPERATOR_TOKEN"),
           "runtime started with operator token"

    refute Map.has_key?(runtime_env, "LEMON_NODE_TOKEN"), "runtime started with node token"
    assert_receive {:connect, %{"role" => "operator", "auth" => auth}}, 5_000
    assert inspect(auth) =~ "leak-operator"
    assert System.get_env("LEMON_NODE_OPERATOR_TOKEN") == nil
    assert System.get_env("LEMON_NODE_TOKEN") == nil

    leak_credentials()
    _ = run_cli([], root)
    assert_receive {:connect, %{"auth" => %{"token" => "leak-node"}}}, 5_000
    assert System.get_env("LEMON_NODE_OPERATOR_TOKEN") == nil
    assert System.get_env("LEMON_NODE_TOKEN") == nil

    assert CLI.help() =~ "LEMON_NODE_OPERATOR_TOKEN"
    assert CLI.help() =~ "LEMON_NODE_TOKEN"
  end

  @tag :tmp_dir
  test "bash, process service, PTY, eval and host-command children never see credentials",
       %{tmp_dir: root} do
    leak_credentials()
    env_dump = "env; exit 0"

    for opts <- [[], [capture_streams: true], [env: %{"EXTRA" => "kept"}]] do
      assert {:ok, result} = CodingAgent.BashExecutor.execute(env_dump, root, opts)
      refute_leak(result.output)
      if opts[:env], do: assert(result.output =~ "EXTRA=kept")
    end

    store = :"#{__MODULE__}.store"
    server = :"#{__MODULE__}.service"

    start_supervised!(
      {Store,
       name: store,
       backend: LemonCore.Store.SqliteBackend,
       backend_opts: [path: Path.join(root, "receipts.sqlite3"), ephemeral_tables: []]}
    )

    start_supervised!({ProcessService, name: server, store: store})

    assert {:ok, receipt} =
             ProcessService.handle(
               "node.process.run",
               %{
                 "nodeId" => "process-node",
                 "processId" => "env",
                 "cwd" => root,
                 "argv" => ["/usr/bin/env"],
                 "stdinBase64" => "",
                 "timeoutMs" => 10_000,
                 "maxOutputBytes" => 1_048_576
               },
               server: server,
               node_id: "process-node",
               session_generation: 1,
               invoke_id: "env-invocation",
               owner: self(),
               default_cwd: root,
               allowed_roots: [root]
             )

    stdout = Base.decode64!(receipt["stdoutBase64"])
    assert stdout =~ "PATH="
    refute_leak(stdout)

    {:ok, pty} =
      PTY.start_link(self(), "pty-env", %{"cwd" => root, "cols" => 200, "rows" => 24},
        default_cwd: root,
        allowed_roots: [root]
      )

    assert_receive {:node_pty, "pty-env", "ready", %{}}, 5_000

    assert :ok =
             PTY.command(pty, "input", %{
               "dataBase64" => Base.encode64("env; echo __DONE__; exit 0\n")
             })

    pty_output = pty_output(pty, "")
    assert pty_output =~ "__DONE__"
    refute_leak(pty_output)

    assert {:ok, %{output: host_output}} = host_command("/usr/bin/env")
    assert host_output =~ "LC_ALL=C"
    refute_leak(host_output)

    python = System.find_executable("python3")

    slot =
      start_supervised!(
        {CodingAgent.Eval.Kernel, key: make_ref(), language: "py", cwd: root, runtime: python}
      )

    assert {:ok, %{ref: ref}} =
             CodingAgent.Eval.Kernel.run(
               slot,
               "import os\nprint('\\n'.join(f'{k}={v}' for k, v in os.environ.items()) + '\\n__DONE__', flush=True)"
             )

    eval_output = eval_output(ref, "")
    assert String.contains?(eval_output, "PYTHONDONTWRITEBYTECODE=1")
    refute_leak(eval_output)
  end

  # Starts the real source launcher with credentials in its environment and
  # inspects the node VM (and every descendant) from outside, the way a
  # same-UID tool would: /proc/<pid>/environ on Linux, `ps -E` on macOS.
  @tag :tmp_dir
  @tag timeout: 600_000
  test "real launcher keeps tokens out of the node VM's initial environment",
       %{tmp_dir: root} do
    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true])

    {:ok, tcp_port} = :inet.port(listen)
    launcher = Path.expand("../../../../../bin/lemon", __DIR__)
    home = Path.join(root, "home")
    tmp = Path.join(root, "tmp")
    File.mkdir_p!(home)
    File.mkdir_p!(tmp)

    env =
      [
        {"HOME", home},
        {"TMPDIR", tmp},
        {"MIX_ENV", "dev"},
        {"LEMON_CONTROL_PLANE_PORT", free_port()},
        {"LEMON_CONTROL_PLANE_NODE_PORT", "0"},
        {"LEMON_GATEWAY_HEALTH_PORT", free_port()},
        {"LEMON_ROUTER_HEALTH_PORT", free_port()},
        {"MIX_HOME", System.get_env("MIX_HOME") || Path.join(System.user_home!(), ".mix")},
        {"HEX_HOME", System.get_env("HEX_HOME") || Path.join(System.user_home!(), ".hex")},
        {"LEMON_NODE_OPERATOR_TOKEN", "leak-operator-external"},
        {"LEMON_NODE_TOKEN", "leak-node-external"}
      ]
      |> Enum.map(fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)

    port =
      Port.open({:spawn_executable, launcher}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:cd, root},
        {:env, env},
        {:args,
         [
           "node",
           "join",
           "--name",
           "env-external",
           "--controller",
           "ws://127.0.0.1:#{tcp_port}/ws",
           "--pair",
           "--cwd",
           root
         ]}
      ])

    {:os_pid, vm_pid} = Port.info(port, :os_pid)

    try do
      # The worker dials the controller only after the handoff was consumed
      # and the runtime (with its bootstrap children) has started.
      # The pipe handoff delivered the operator token to the pairing request.
      assert websocket_first_text(listen) =~ "leak-operator-external", drain(port)
      assert handoff_residue(tmp) == [], "launcher left handoff state in TMPDIR"

      pids = [vm_pid | descendants(vm_pid)]
      assert length(pids) > 1, "expected VM bootstrap children"

      for pid <- pids do
        environ = process_environ(pid)
        assert environ =~ "TMPDIR=#{tmp}", "could not read environment of #{pid}"

        refute String.contains?(environ, "leak-operator-external"),
               "pid #{pid} exposes operator token"

        refute String.contains?(environ, "leak-node-external"), "pid #{pid} exposes node token"
      end
    after
      for pid <- [vm_pid | descendants(vm_pid)],
          do: System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)

      if Port.info(port), do: Port.close(port)
    end
  end

  @tag :tmp_dir
  @tag timeout: 600_000
  test "launcher paths that never exec the node VM leave nothing behind", %{tmp_dir: root} do
    launcher = Path.expand("../../../../../bin/lemon", __DIR__)
    tmp = Path.join(root, "tmp")
    File.mkdir_p!(tmp)

    env = [
      {"HOME", root},
      {"TMPDIR", tmp},
      {"MIX_ENV", "dev"},
      {"MIX_HOME", System.get_env("MIX_HOME") || Path.join(System.user_home!(), ".mix")},
      {"HEX_HOME", System.get_env("HEX_HOME") || Path.join(System.user_home!(), ".hex")},
      {"LEMON_NODE_OPERATOR_TOKEN", "leak-operator-external"},
      {"LEMON_NODE_TOKEN", "leak-node-external"}
    ]

    # Help, an option-parsing failure and a launcher preflight failure.
    for {args, extra} <- [
          {["node", "join", "--help"], []},
          {["node", "join", "--bogus-option"], []},
          {["node", "join", "--help"], [{"LEMON_CONTROL_PLANE_PORT", "0"}]}
        ] do
      {output, _status} =
        System.cmd(launcher, args, env: env ++ extra, cd: root, stderr_to_stdout: true)

      refute String.contains?(output, "leak-"), "#{inspect(args)} printed a credential"
      assert handoff_residue(tmp) == [], "#{inspect(args)} left handoff state"
    end
  end

  defp handoff_residue(tmp) do
    # Mix keeps its own lock/pubsub dirs in TMPDIR; nothing may hold a token.
    for path <- Path.wildcard(Path.join(tmp, "**/*"), match_dot: true),
        String.contains?(Path.basename(path), "lemon-node-cred") or
          (File.regular?(path) and File.read!(path) =~ "leak-"),
        do: path
  end

  # The node may probe the listener before the real WebSocket connection.
  defp websocket_first_text(listen) do
    {:ok, conn} = :gen_tcp.accept(listen, 240_000)

    case recv_until(conn, "") do
      {:ok, request} -> websocket_first_text(conn, request)
      {:error, :closed} -> websocket_first_text(listen)
    end
  end

  defp websocket_first_text(conn, request) do
    [_, key] = Regex.run(~r/sec-websocket-key:\s*(\S+)/i, request)

    accept =
      :crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11") |> Base.encode64()

    :ok =
      :gen_tcp.send(
        conn,
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" <>
          "Sec-WebSocket-Accept: #{accept}\r\n\r\n"
      )

    {:ok, <<_fin_op, 1::1, len7::7>>} = :gen_tcp.recv(conn, 2, 60_000)

    len =
      case len7 do
        126 -> with {:ok, <<n::16>>} <- :gen_tcp.recv(conn, 2, 60_000), do: n
        127 -> with {:ok, <<n::64>>} <- :gen_tcp.recv(conn, 8, 60_000), do: n
        n -> n
      end

    {:ok, mask} = :gen_tcp.recv(conn, 4, 60_000)
    {:ok, payload} = :gen_tcp.recv(conn, len, 60_000)
    mask_bytes = :binary.bin_to_list(mask)

    payload
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.map(fn {byte, i} -> Bitwise.bxor(byte, Enum.at(mask_bytes, rem(i, 4))) end)
    |> :binary.list_to_bin()
  end

  defp recv_until(conn, acc) do
    if String.contains?(acc, "\r\n\r\n") do
      {:ok, acc}
    else
      with {:ok, data} <- :gen_tcp.recv(conn, 0, 60_000), do: recv_until(conn, acc <> data)
    end
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    Integer.to_string(port)
  end

  defp process_environ(pid) do
    proc = "/proc/#{pid}/environ"

    if File.exists?(proc) do
      proc |> File.read!() |> String.replace(<<0>>, "\n")
    else
      {out, 0} = System.cmd("ps", ["-E", "-ww", "-o", "command=", "-p", Integer.to_string(pid)])
      out
    end
  end

  defp descendants(pid) do
    {out, 0} = System.cmd("ps", ["-A", "-o", "pid=,ppid="])

    pairs =
      for line <- String.split(out, "\n", trim: true),
          [child, parent] = String.split(line),
          do: {String.to_integer(child), String.to_integer(parent)}

    walk([pid], pairs, [])
  end

  defp walk([], _pairs, acc), do: acc

  defp walk([pid | rest], pairs, acc) do
    children = for {child, ^pid} <- pairs, do: child
    walk(rest ++ children, pairs, acc ++ children)
  end

  defp drain(port, acc \\ "") do
    receive do
      {^port, {:data, data}} -> drain(port, acc <> data)
    after
      0 -> acc
    end
  end

  defp host_command(path) do
    with {:ok, output} <- HostCommand.run_executable(path, [], timeout_ms: 5_000),
         do: {:ok, %{output: output}}
  end

  defp pty_output(pid, acc) do
    receive do
      {:node_pty, "pty-env", "output", %{"dataBase64" => data}} ->
        PTY.ack(pid)
        pty_output(pid, acc <> Base.decode64!(data))

      {:node_pty, "pty-env", "exit", _} ->
        acc
    after
      5_000 -> flunk("PTY did not exit: #{acc}")
    end
  end

  defp eval_output(ref, acc) do
    if acc =~ "__DONE__" do
      acc
    else
      assert_receive {:lemon_eval, ^ref, {:output, chunk}}, 5_000
      eval_output(ref, acc <> chunk)
    end
  end
end
