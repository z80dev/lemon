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

  defp log_entries(log) do
    log |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
  end

  test "rejects runInTerminal and forwards startDebugging to its owner", %{
    adapter: adapter,
    cwd: cwd,
    log: log
  } do
    client = start_client!(adapter, cwd)
    {:ok, _} = Client.request(client, "launch", %{"program" => "x", "fakeMode" => "reverse"})

    assert_receive {:dap, ^client, {:reverse_request, "runInTerminal"}}, 5_000
    assert_receive {:dap, ^client, {:start_debugging, request}}, 5_000
    assert request["arguments"]["request"] == "launch"
    assert :ok = Client.respond(client, request, :ok)
    assert_receive {:dap, ^client, {:event, "initialized", _}}, 5_000

    # A later response proves the adapter has consumed and logged both answers.
    {:ok, seq} = Client.request(client, "threads")
    assert_receive {:dap, ^client, {:response, ^seq, _}}, 5_000
    responses = Enum.filter(log_entries(log), &Map.has_key?(&1, "reverse_response"))

    assert [
             %{"reverse_response" => "runInTerminal", "success" => false, "message" => rit},
             %{"reverse_response" => "startDebugging", "success" => true, "message" => nil}
           ] = responses

    assert rit =~ "runInTerminal is not supported"
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

  test "remote connection is ready before requests and receives frames on the client owner", %{
    adapter: adapter,
    cwd: cwd
  } do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, port} = :inet.port(listener)
    adapter = Map.merge(adapter, %{connect_mode: :remote, host: "127.0.0.1", port: port})
    client = start_client!(adapter, cwd)
    assert :sys.get_state(client, 1_000).ready?
    assert Client.os_pid(client) == nil

    {:ok, socket} = :gen_tcp.accept(listener, 1_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    body = Jason.encode!(%{"type" => "event", "event" => "initialized", "body" => %{}})
    :ok = :gen_tcp.send(socket, ["Content-Length: #{byte_size(body)}\r\n\r\n", body])
    assert_receive {:dap, ^client, {:event, "initialized", %{}}}, 1_000
  end

  test "socket handshake keeps status responsive and transfers the connection before readiness",
       %{
         adapter: adapter,
         cwd: cwd
       } do
    adapter = waiting_adapter(adapter, :socket)
    owner = self()

    starter =
      spawn(fn ->
        receive do
          :start ->
            result = Client.start_link(adapter: adapter, cwd: cwd, owner: owner)
            send(owner, {:client_started, result})

            receive do
              :stop -> :ok
            end
        end
      end)

    on_exit(fn -> Process.exit(starter, :kill) end)
    :erlang.trace(starter, true, [:procs])
    send(starter, :start)
    assert_receive {:trace, ^starter, :spawn, client, _initial_call}, 1_000
    :erlang.trace(starter, false, [:procs])

    on_exit(fn -> Client.stop(client) end)
    state = :sys.get_state(client, 1_000)
    refute state.ready?
    assert %Task{} = state.startup_task
    assert is_integer(Client.os_pid(client))
    assert {:status, ^client, _, _} = :sys.get_status(client, 1_000)
    assert {:error, "debug adapter is still connecting"} = Client.request(client, "threads")
    assert :ok = Client.cancel(client, 1)
    refute_received {:client_started, _}

    {:ok, port} = :inet.port(state.listener)
    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
    on_exit(fn -> :gen_tcp.close(socket) end)
    assert_receive {:client_started, {:ok, ^client}}, 1_000
    assert :sys.get_state(client, 1_000).ready?

    body = Jason.encode!(%{"type" => "event", "event" => "initialized", "body" => %{}})
    :ok = :gen_tcp.send(socket, ["Content-Length: #{byte_size(body)}\r\n\r\n", body])
    assert_receive {:dap, ^client, {:event, "initialized", %{}}}, 1_000
  end

  for mode <- [:socket, :socket_server] do
    @mode mode
    test "stop cancels a pending #{@mode} handshake and closes owned resources", %{
      adapter: adapter,
      cwd: cwd
    } do
      {:ok, client} =
        GenServer.start_link(Client,
          adapter: waiting_adapter(adapter, @mode),
          cwd: cwd,
          owner: self()
        )

      on_exit(fn -> Client.stop(client) end)
      state = :sys.get_state(client, 1_000)
      refute state.ready?
      assert {:status, ^client, _, _} = :sys.get_status(client, 1_000)
      worker = state.startup_task.pid
      ref = Process.monitor(worker)
      client_ref = Process.monitor(client)

      assert :ok = Client.stop(client)
      assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 1_000
      assert_receive {:DOWN, ^client_ref, :process, ^client, :normal}, 1_000
      assert Port.info(state.port) == nil

      if state.listener do
        assert Port.info(state.listener) == nil
      end
    end
  end

  test "adapter exit during handshake reports startup failure without killing the caller", %{
    adapter: adapter,
    cwd: cwd
  } do
    adapter = %{
      adapter
      | connect_mode: :socket,
        args: ["-c", "import sys; print('startup failed', flush=True); sys.exit(3)"]
    }

    assert {:error, {:shutdown, reason}} = Client.start_link(adapter: adapter, cwd: cwd)
    assert reason =~ "exited (code 3)"
    assert reason =~ "startup failed"
  end

  test "connection worker death terminates startup and closes the adapter", %{
    adapter: adapter,
    cwd: cwd
  } do
    token = make_ref()

    {:ok, client} =
      GenServer.start_link(Client,
        adapter: waiting_adapter(adapter, :socket),
        cwd: cwd,
        owner: self(),
        startup_notify: {self(), token}
      )

    on_exit(fn -> Client.stop(client) end)
    state = :sys.get_state(client, 1_000)
    ref = Process.monitor(client)
    Process.exit(state.startup_task.pid, :kill)
    assert_receive {^token, {:error, "debug adapter connection worker stopped"}}, 1_000
    assert_receive {:DOWN, ^ref, :process, ^client, :normal}, 1_000
    assert Port.info(state.port) == nil
    assert Port.info(state.listener) == nil
  end

  defp waiting_adapter(adapter, mode) do
    %{adapter | connect_mode: mode, args: ["-c", "import time; time.sleep(3600)"]}
  end
end
