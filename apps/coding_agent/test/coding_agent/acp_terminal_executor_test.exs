defmodule CodingAgent.ACPTerminalExecutorTest do
  use ExUnit.Case, async: true
  alias CodingAgent.ACPTerminalExecutor
  alias LemonCore.ACPClientBridge

  setup do
    run_id = LemonCore.Id.run_id()
    :ok = ACPClientBridge.register(run_id)
    {:ok, run_id: run_id}
  end

  test "uses explicit shell argv and streams output while exit wait is pending", %{run_id: run_id} do
    parent = self()
    command = "printf 'hello'; exit 7"

    task =
      Task.async(fn ->
        ACPTerminalExecutor.execute(command, "/tmp",
          run_id: run_id,
          timeout: 2_000,
          env: %{"B_VAR" => "two", "A_VAR" => "one"},
          on_chunk: &send(parent, {:chunk, &1}),
          on_terminal: &send(parent, {:terminal, &1})
        )
      end)

    create = request("terminal/create")
    assert create.params["command"] == elem(CodingAgent.BashExecutor.get_shell_config(), 0)
    assert create.params["args"] == ["-c", command]
    assert create.params["cwd"] == "/tmp"

    assert create.params["env"] == [
             %{"name" => "A_VAR", "value" => "one"},
             %{"name" => "B_VAR", "value" => "two"}
           ]

    reply(create, %{"terminalId" => "native"})
    assert_receive {:terminal, "native"}
    wait = request("terminal/wait_for_exit")
    output = request("terminal/output")
    reply(output, %{"output" => "hello", "truncated" => false})
    assert_receive {:chunk, "hello"}
    reply(wait, %{"exitCode" => 7})
    {result, methods} = finish(task, %{"output" => "hello", "truncated" => false})

    assert {:ok, %{exit_code: 7, output: "hello", terminal_id: "native", cancelled: false}} =
             result

    assert List.last(methods) == "terminal/release"
  end

  test "timeout kills before taking final output and releases the client terminal", %{
    run_id: run_id
  } do
    task =
      Task.async(fn ->
        ACPTerminalExecutor.execute("sleep 10", "/tmp", run_id: run_id, timeout: 75)
      end)

    reply(request("terminal/create"), %{"terminalId" => "timeout"})
    _wait = request("terminal/wait_for_exit")
    {result, methods} = finish(task, %{"output" => "partial", "truncated" => false})
    assert {:ok, %{timed_out: true, cancelled: false, output: "partial"}} = result
    kill = Enum.find_index(methods, &(&1 == "terminal/kill"))
    assert kill != nil
    assert Enum.at(methods, kill + 1) == "terminal/output"
    assert List.last(methods) == "terminal/release"
  end

  test "allocation finishing after timeout is still killed and released", %{run_id: run_id} do
    task =
      Task.async(fn ->
        ACPTerminalExecutor.execute("sleep 10", "/tmp", run_id: run_id, timeout: 30)
      end)

    create = request("terminal/create")
    assert {:ok, %{timed_out: true}} = Task.await(task)
    reply(create, %{"terminalId" => "late"})
    kill = request("terminal/kill")
    assert kill.params["terminalId"] == "late"
    reply(kill, %{})
    reply(request("terminal/release"), %{})
  end

  test "client-discarded output never claims a complete local artifact", %{run_id: run_id} do
    task =
      Task.async(fn ->
        ACPTerminalExecutor.execute("lots", "/tmp", run_id: run_id, timeout: 2_000)
      end)

    reply(request("terminal/create"), %{"terminalId" => "truncated"})
    reply(request("terminal/wait_for_exit"), %{"exitCode" => 0})
    {result, _methods} = finish(task, %{"output" => "tail", "truncated" => true})

    assert {:ok, %{truncated: true, full_output_path: nil, client_output_truncated: true}} =
             result
  end

  test "fully retained large output spills privately without losing bytes", %{run_id: run_id} do
    task =
      Task.async(fn ->
        ACPTerminalExecutor.execute("large", "/tmp", run_id: run_id, timeout: 2_000)
      end)

    reply(request("terminal/create"), %{"terminalId" => "large"})
    reply(request("terminal/wait_for_exit"), %{"exitCode" => 0})
    output = String.duplicate("unicode λ\n", 10_000)
    {result, _methods} = finish(task, %{"output" => output, "truncated" => false})
    assert {:ok, %{truncated: true, full_output_path: path, output: visible}} = result
    on_exit(fn -> File.rm(path) end)
    assert File.read!(path) == output
    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert String.valid?(visible)
    assert byte_size(visible) <= 50_000
  end

  test "tool worker death does not orphan the native command", %{run_id: run_id} do
    worker =
      spawn(fn ->
        ACPTerminalExecutor.execute("sleep 10", "/tmp", run_id: run_id, timeout: 5_000)
      end)

    reply(request("terminal/create"), %{"terminalId" => "orphan"})
    _wait = request("terminal/wait_for_exit")
    Process.exit(worker, :kill)
    kill = request("terminal/kill")
    reply(kill, %{})
    # A polling snapshot may precede the final snapshot in the mailbox.
    release_after_outputs()
  end

  defp request(method) do
    assert_receive {:acp_client_request, %{method: ^method} = payload}, 1_000
    payload
  end

  defp reply(payload, result),
    do: send(payload.reply_to, {:acp_client_response, payload.ref, %{"result" => result}})

  defp finish(task, output, methods \\ []) do
    ref = task.ref

    receive do
      {:acp_client_request, payload} ->
        reply(payload, if(payload.method == "terminal/output", do: output, else: %{}))
        finish(task, output, methods ++ [payload.method])

      {^ref, result} ->
        Process.demonitor(ref, [:flush])
        {result, methods}
    after
      3_000 -> flunk("native terminal execution did not finish")
    end
  end

  defp release_after_outputs do
    receive do
      {:acp_client_request, payload} ->
        reply(payload, %{"output" => "", "truncated" => false})
        unless payload.method == "terminal/release", do: release_after_outputs()
    after
      3_000 -> flunk("native terminal was not released")
    end
  end
end
