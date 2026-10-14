defmodule CodingAgent.Debug.ClientTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Debug.Client

  @fake_adapter Path.expand("../../support/fake_dap_adapter.py", __DIR__)
  @python System.find_executable("python3")

  if is_nil(@python), do: @moduletag(skip: "python3 is required for the fake DAP adapter")

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    log = Path.join(tmp_dir, "requests.jsonl")

    adapter = %{
      name: "fake",
      command: @python,
      args: [@fake_adapter, log],
      connect_mode: :stdio
    }

    %{adapter: adapter, log: log, cwd: tmp_dir}
  end

  defp start_client!(adapter, cwd) do
    {:ok, client} = Client.start_link(adapter: adapter, cwd: cwd)

    on_exit(fn -> Client.stop(client) end)
    client
  end

  defp await_response(client, seq) do
    assert_receive {:dap, ^client, {:response, ^seq, response}}, 5_000
    response
  end

  defp log_entries(log) do
    log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  test "correlates responses by request seq and forwards events", %{adapter: adapter, cwd: cwd} do
    client = start_client!(adapter, cwd)

    {:ok, seq} = Client.request(client, "initialize", %{"clientID" => "lemon"})
    assert %{"success" => true, "body" => body} = await_response(client, seq)
    assert body["supportsConfigurationDoneRequest"] == true

    {:ok, launch_seq} =
      Client.request(client, "launch", %{"program" => "x", "stopOnEntry" => true})

    assert_receive {:dap, ^client, {:event, "process", %{"systemProcessId" => pid}}}, 5_000
    assert is_integer(pid)
    assert_receive {:dap, ^client, {:event, "initialized", _}}, 5_000

    {:ok, done_seq} = Client.request(client, "configurationDone", %{})
    assert %{"success" => true} = await_response(client, done_seq)
    assert %{"success" => true} = await_response(client, launch_seq)

    assert_receive {:dap, ^client, {:event, "stopped", %{"reason" => "entry", "threadId" => 1}}},
                   5_000

    {:ok, bad_seq} = Client.request(client, "bogus", nil)

    assert %{"success" => false, "message" => "unsupported request bogus"} =
             await_response(client, bad_seq)
  end

  test "rejects runInTerminal and startDebugging reverse requests", %{
    adapter: adapter,
    cwd: cwd,
    log: log
  } do
    client = start_client!(adapter, cwd)
    {:ok, _} = Client.request(client, "launch", %{"program" => "x", "fakeMode" => "reverse"})

    assert_receive {:dap, ^client, {:reverse_request, "runInTerminal"}}, 5_000
    assert_receive {:dap, ^client, {:reverse_request, "startDebugging"}}, 5_000
    assert_receive {:dap, ^client, {:event, "initialized", _}}, 5_000

    reverse_responses = fn ->
      Enum.filter(log_entries(log), &Map.has_key?(&1, "reverse_response"))
    end

    assert eventually(fn -> length(reverse_responses.()) == 2 end)
    responses = reverse_responses.()

    assert [
             %{"reverse_response" => "runInTerminal", "success" => false, "message" => rit},
             %{"reverse_response" => "startDebugging", "success" => false, "message" => sd}
           ] = responses

    assert rit =~ "runInTerminal is not supported"
    assert sd =~ "startDebugging"
  end

  test "reports adapter exit with captured stderr", %{adapter: adapter, cwd: cwd} do
    {:ok, client} = Client.start_link(adapter: adapter, cwd: cwd)
    ref = Process.monitor(client)
    {:ok, _} = Client.request(client, "launch", %{"program" => "x", "fakeMode" => "crash"})

    assert_receive {:dap, ^client, {:exit, reason}}, 5_000
    assert reason =~ "exited (code 3)"
    assert reason =~ "fatal adapter error"
    assert_receive {:DOWN, ^ref, :process, ^client, :normal}, 5_000
  end

  test "stop kills the adapter process tree including the debuggee", %{adapter: adapter, cwd: cwd} do
    client = start_client!(adapter, cwd)
    adapter_pid = Client.os_pid(client)
    {:ok, _} = Client.request(client, "launch", %{"program" => "x"})
    assert_receive {:dap, ^client, {:event, "process", %{"systemProcessId" => debuggee}}}, 5_000

    assert os_alive?(adapter_pid)
    assert os_alive?(debuggee)

    :ok = Client.stop(client)

    assert eventually(fn -> not os_alive?(adapter_pid) and not os_alive?(debuggee) end)
  end

  test "a missing adapter executable fails to start with a clear error", %{cwd: cwd} do
    Process.flag(:trap_exit, true)

    adapter = %{
      name: "missing",
      command: "/nonexistent/lemon-fake-dap",
      args: [],
      connect_mode: :stdio
    }

    assert {:error, {:shutdown, message}} = Client.start_link(adapter: adapter, cwd: cwd)
    assert message =~ "cannot start debug adapter /nonexistent/lemon-fake-dap"
  end

  defp os_alive?(pid) when is_integer(pid) do
    {_, status} = System.cmd("kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)
    status == 0
  end

  defp eventually(fun, attempts \\ 50) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(100) && eventually(fun, attempts - 1)
    end
  end
end
