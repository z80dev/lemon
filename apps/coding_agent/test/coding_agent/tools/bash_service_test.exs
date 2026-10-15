defmodule CodingAgent.Tools.BashServiceTest do
  use ExUnit.Case, async: false

  alias CodingAgent.InternalUrls.ProcessProtocol
  alias CodingAgent.ProcessManager
  alias CodingAgent.Tools.{Bash, KillProcess}
  alias LemonAgent.Types.AgentToolResult

  @moduletag :tmp_dir

  setup %{tmp_dir: cwd} do
    owner = "service-#{System.unique_integer([:positive])}"
    opts = [session_id: owner, session_pid: self()]

    File.write!(
      Path.join(cwd, "server.sh"),
      "printf 'READY\\n'\nread value\nprintf '%s\\n' \"$value\"\n"
    )

    on_exit(fn ->
      for {id, %{owner: ^owner}} <- ProcessManager.list() do
        ProcessManager.kill(id, :sigkill)
      end
    end)

    {:ok, cwd: cwd, opts: opts}
  end

  test "service identity is registered before external launch", %{cwd: cwd, opts: opts} do
    owner = self()
    service = %{name: "atomic", project: cwd, generation: 1}

    assert {:ok, id} =
             ProcessManager.exec(
               command: "read value",
               cwd: cwd,
               owner: opts[:session_id],
               owner_pid: self(),
               service: service,
               before_start: fn ->
                 send(
                   owner,
                   {:registered_before_start,
                    CodingAgent.Tools.Bash.Service.resolve("atomic", cwd, opts)}
                 )
               end
             )

    assert_receive {:registered_before_start, ^id}
  end

  test "log readiness sees a partial line without waiting for a newline", %{cwd: cwd, opts: opts} do
    result =
      Bash.execute(
        "partial",
        %{
          "command" => "printf READY; read value",
          "name" => "partial",
          "ready" => %{"log" => "READY", "timeout_s" => 1}
        },
        nil,
        nil,
        cwd,
        opts
      )

    refute result.is_error
    assert text(result) =~ "READY"
  end

  test "log readiness, name inspection, restart and stop", %{cwd: cwd, opts: opts} do
    params = %{"command" => "bash server.sh", "name" => "web", "ready" => %{"log" => "REA[D]Y"}}
    first = Bash.execute("start", params, nil, nil, cwd, opts)
    assert %AgentToolResult{is_error: false, details: %{process_id: old}} = first
    assert first.details.service.ready
    assert text(ProcessProtocol.read("proc://", nil, cwd, opts)) =~ "(web)"
    assert text(ProcessProtocol.read("proc://web", nil, cwd, opts)) =~ "READY"
    assert text(ProcessProtocol.read("proc://web", nil, cwd, opts)) =~ "READY"

    second = Bash.execute("restart", params, nil, nil, cwd, opts)
    assert %AgentToolResult{is_error: false, details: %{process_id: new}} = second
    refute old == new
    assert {:ok, %{status: :killed}} = ProcessManager.poll(old)

    assert %AgentToolResult{} =
             KillProcess.execute(
               "stop",
               %{"process_id" => "web", "signal" => "kill"},
               nil,
               nil,
               cwd,
               opts
             )
  end

  test "session and project names are isolated", %{cwd: cwd, opts: opts} do
    params = %{"command" => "bash server.sh", "name" => "same"}

    assert %AgentToolResult{details: %{process_id: first}} =
             Bash.execute("s1", params, nil, nil, cwd, opts)

    foreign = Keyword.put(opts, :session_id, "foreign")
    assert {:error, _} = ProcessProtocol.read("proc://same", nil, cwd, foreign)
    other = Path.join(cwd, "other")
    File.mkdir!(other)
    assert {:error, _} = ProcessProtocol.read("proc://same", nil, other, opts)
    assert {:ok, %{status: :running}} = ProcessManager.poll(first)
  end

  test "readiness timeout and early exit include recent output", %{cwd: cwd, opts: opts} do
    params = %{
      "command" => "bash server.sh",
      "name" => "slow",
      "ready" => %{"log" => "NEVER", "timeout_s" => 0.1}
    }

    result = Bash.execute("timeout", params, nil, nil, cwd, opts)
    assert result.is_error
    assert result.details.service.timed_out
    assert text(result) =~ "READY"
    assert {:ok, %{status: :running}} = ProcessManager.poll(result.details.process_id)

    exited =
      Bash.execute(
        "exit",
        %{"command" => "echo failed; exit 7", "name" => "bad", "ready" => %{"log" => "NEVER"}},
        nil,
        nil,
        cwd,
        opts
      )

    assert exited.is_error
    assert text(exited) =~ "failed"
    assert text(exited) =~ "exit code 7"
  end

  test "TCP readiness accepts on loopback and combines probes with OR", %{cwd: cwd, opts: opts} do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)

    python =
      System.find_executable("python3") || raise "python3 required for loopback service fixture"

    File.write!(
      Path.join(cwd, "tcp.py"),
      "import socket, sys\ns = socket.socket()\ns.bind(('127.0.0.1', int(sys.argv[1])))\ns.listen()\nwhile True:\n c, _ = s.accept()\n c.close()\n"
    )

    result =
      Bash.execute(
        "tcp",
        %{
          "command" => "#{python} tcp.py #{port}",
          "name" => "tcp",
          "ready" => %{"port" => port, "log" => "never emitted", "timeout_s" => 5}
        },
        nil,
        nil,
        cwd,
        opts
      )

    refute result.is_error
    assert result.details.service.ready
  end

  test "rejects malformed specs before launch", %{cwd: cwd, opts: opts} do
    for extra <- [
          %{"name" => "../bad"},
          %{"name" => "ok", "ready" => %{"log" => "["}},
          %{"name" => "ok", "ready" => %{"port" => 0}},
          %{"name" => "ok", "ready" => %{}},
          %{"ready" => %{"log" => "x"}},
          %{"name" => "ok", "timeout" => 10}
        ] do
      assert {:error, _} =
               Bash.execute(
                 "invalid",
                 Map.put(extra, "command", "touch launched"),
                 nil,
                 nil,
                 cwd,
                 opts
               )
    end

    refute File.exists?(Path.join(cwd, "launched"))
  end

  defp text(result), do: Enum.map_join(result.content, "\n", & &1.text)
end
