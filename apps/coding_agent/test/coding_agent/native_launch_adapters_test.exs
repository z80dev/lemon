defmodule CodingAgent.NativeLaunchAdaptersTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{ACPTerminalExecutor, Debug.Client}
  alias CodingAgent.Tools.{LspDiagnostics, LspFormatter}
  alias LemonCore.{ACPClientBridge, NativeProcess, ProcessGroup}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    previous = Application.fetch_env(:lemon_core, :native_process_ledger)
    :ok = NativeProcess.configure!(Path.join(dir, "native.dets"))
    ledger = Process.whereis(NativeProcess)

    on_exit(fn ->
      if Process.alive?(ledger), do: GenServer.stop(ledger)

      case previous do
        {:ok, value} -> Application.put_env(:lemon_core, :native_process_ledger, value)
        :error -> Application.delete_env(:lemon_core, :native_process_ledger)
      end
    end)

    :ok
  end

  test "ACP missing-client refusal is distinguished from dispatched work", %{tmp_dir: dir} do
    assert {:error, :acp_terminal_create_failed} =
             ACPTerminalExecutor.execute("true", dir,
               run_id: LemonCore.Id.run_id(),
               timeout: 1_000
             )

    assert [{_, record, %{}}] = NativeProcess.snapshot()
    assert record.backend == :unsupported
    assert record.launch_classification == :rejected
    refute record.capacity_held
    refute record.termination_confirmed
  end

  test "ACP records uncertainty before dispatch and a protocol error cannot erase it", %{
    tmp_dir: dir
  } do
    run_id = LemonCore.Id.run_id()
    :ok = ACPClientBridge.register(run_id)
    on_exit(fn -> ACPClientBridge.unregister(run_id) end)

    task =
      Task.async(fn ->
        ACPTerminalExecutor.execute("true", dir, run_id: run_id, timeout: 2_000)
      end)

    assert_receive {:acp_client_request, %{method: "terminal/create"} = request}, 1_000
    assert [{_, %{backend: :unsupported, capacity_held: true}, %{}}] = NativeProcess.snapshot()
    send(request.reply_to, {:acp_client_response, request.ref, %{"error" => %{"code" => -1}}})
    assert {:error, :acp_terminal_create_failed} = Task.await(task)
    assert [{_, %{backend: :unsupported, capacity_held: true}, %{}}] = NativeProcess.snapshot()
  end

  test "debug launch and attach errors retain uncertainty alongside the local adapter proof", %{
    tmp_dir: dir
  } do
    python =
      System.find_executable("python3") || flunk("python3 is required for the fake adapter")

    adapter = %{
      name: "fake",
      command: python,
      args: [Path.expand("../support/fake_dap_adapter.py", __DIR__), Path.join(dir, "dap.jsonl")],
      connect_mode: :stdio
    }

    {:ok, client} = Client.start_link(adapter: adapter, cwd: dir)
    on_exit(fn -> Client.stop(client) end)

    assert [{_, %{backend: :local, workload_identity: identity}, _}] = NativeProcess.snapshot()
    assert ProcessGroup.valid_identity?(identity)

    for command <- ["launch", "attach"] do
      assert {:ok, seq} = Client.request(client, command, %{"fakeMode" => "fail_launch"})
      assert_receive {:dap, ^client, {:response, ^seq, %{"success" => false}}}, 5_000
    end

    assert Enum.count(NativeProcess.snapshot(), fn {_, record, _} ->
             record.backend == :unsupported and record.capacity_held
           end) == 2

    Client.stop(client)
    assert {:error, _} = Client.request(client, "launch", %{})

    assert Enum.count(NativeProcess.snapshot(), fn {_, record, _} ->
             record.backend == :unsupported
           end) == 2
  end

  test "a dead JavaScript host cannot release detached kernel ownership", %{tmp_dir: dir} do
    runtime = System.find_executable("node") || flunk("node is required for the JS kernel")

    slot =
      start_supervised!(
        {CodingAgent.Eval.Kernel,
         key: {__MODULE__, make_ref()}, language: "js", runtime: runtime, cwd: dir}
      )

    assert {:ok, %{ref: ref}} = CodingAgent.Eval.Kernel.run(slot, "1 + 1")
    assert_receive {:lemon_eval, ^ref, {:result, _}}, 5_000
    state = :sys.get_state(slot)
    kernel = state.kernel_group
    assert kernel.pgid != state.os_pid

    # Prevent both EOF handling in the kernel and normal cleanup in the slot,
    # modelling abrupt teardown rather than the cooperative shutdown path.
    :ok = :sys.suspend(slot)

    try do
      kill = Enum.find(["/bin/kill", "/usr/bin/kill"], &File.regular?/1)
      assert {_, 0} = System.cmd(kill, ["-STOP", Integer.to_string(kernel.root_pid)])

      on_exit(fn -> ProcessGroup.signal_workload_group(kernel, :sigkill) end)

      rows = NativeProcess.snapshot()

      assert {local_id, %{backend: :local, workload_identity: host}, _} =
               Enum.find(rows, fn {_, record, _} -> record.backend == :local end)

      assert {:ok, _} = ProcessGroup.signal_workload_group(host, :sigkill)

      rows =
        Enum.reduce_while(1..100, rows, fn _, _ ->
          rows = NativeProcess.snapshot()

          if Enum.any?(rows, fn {id, record, _} ->
               id == local_id and record.termination_confirmed
             end) do
            {:halt, rows}
          else
            Process.sleep(20)
            {:cont, rows}
          end
        end)

      assert Enum.any?(rows, fn {id, record, _} ->
               id == local_id and record.termination_confirmed and not record.capacity_held
             end)

      assert {:alive, _} = ProcessGroup.workload_group_status(kernel)

      assert Enum.any?(rows, fn {_, record, _} ->
               record.backend == :unsupported and record.capacity_held and
                 not record.termination_confirmed
             end)
    after
      ProcessGroup.signal_workload_group(kernel, :sigkill)
      :sys.resume(slot)
    end
  end

  test "diagnostics and formatter keep bounded BashExecutor execution while tracking launches", %{
    tmp_dir: dir
  } do
    bin = Path.join(dir, "bin")
    File.mkdir_p!(bin)
    previous_path = System.fetch_env!("PATH")
    System.put_env("PATH", bin <> ":" <> previous_path)
    on_exit(fn -> System.put_env("PATH", previous_path) end)

    for name <- ["go", "gofmt"] do
      path = Path.join(bin, name)
      File.write!(path, "#!/bin/sh\nprintf '%070000d' 0\nexit 1\n")
      File.chmod!(path, 0o755)
    end

    File.write!(Path.join(dir, "go.mod"), "module fixture\n")
    path = Path.join(dir, "main.go")
    File.write!(path, "package main\n")

    assert {:ok, diagnostics} =
             LspDiagnostics.diagnose_file(path, dir, diagnostics_timeout_ms: 5_000)

    assert diagnostics.command_exit_status == 1
    assert byte_size(diagnostics.raw_output) <= 64_000
    assert {:error, message} = LspFormatter.format_file(path, cwd: dir, timeout_ms: 5_000)
    assert message =~ "formatter exited with status 1"
    assert byte_size(message) < 9_000
    assert File.read!(path) == "package main\n"

    rows = NativeProcess.snapshot()
    assert length(rows) == 2

    assert Enum.all?(rows, fn {_, record, _} ->
             record.backend == :local and ProcessGroup.valid_identity?(record.workload_identity)
           end)
  end
end
