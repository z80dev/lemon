defmodule LemonChannels.Adapters.Telegram.TransportAsyncPollTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Transport
  alias LemonChannels.Adapters.Telegram.Transport.RuntimeState
  alias LemonChannels.Telegram.PollerLock

  @supervisor LemonChannels.Adapters.Telegram.AsyncSupervisor

  test "Telegram outbound and transport contain no adapter retry or sleeps" do
    root = Path.expand("../../../../lib/lemon_channels/adapters/telegram", __DIR__)
    outbound = File.read!(Path.join(root, "outbound.ex"))
    transport = File.read!(Path.join(root, "transport.ex"))
    refute outbound =~ "with_retry"
    refute outbound =~ "Process.sleep"
    refute transport =~ "Process.sleep"
    refute transport =~ "Task.start("
  end

  def start_loop(state) do
    :proc_lib.init_ack({:ok, self()})
    :gen_server.enter_loop(Transport, [], state)
  end

  defmodule BlockingAPI do
    def get_updates(owner, offset, _timeout) do
      owner = if is_pid(owner), do: owner, else: :persistent_term.get({__MODULE__, owner})
      send(owner, {:poll_started, self(), offset})

      receive do
        {:finish, result} -> result
        :crash -> exit(:injected_poll_failure)
      end
    end
  end

  setup do
    unless Process.whereis(@supervisor) do
      start_supervised!({Task.Supervisor, name: @supervisor})
    end

    :ok
  end

  test "drain responds during the poll and discards its unconfirmed result" do
    state =
      RuntimeState.new(%{
        token: self(),
        api_mod: BlockingAPI,
        offset: 7,
        poll_interval_ms: 60_000
      })

    {:noreply, polling} = Transport.handle_info(:poll, state)
    assert_receive {:poll_started, worker, 7}

    assert {:reply, :ok, paused} =
             Transport.handle_call(:drain_pause, {self(), make_ref()}, polling)

    send(worker, {:finish, {:ok, %{"ok" => true, "result" => [%{"update_id" => 9}]}}})
    ref = polling.poll_task.ref
    assert_receive {^ref, result}
    assert {:noreply, finished} = Transport.handle_info({ref, result}, paused)
    assert finished.offset == 7
    assert finished.drain_paused?
    refute Map.has_key?(finished, :poll_task)
  end

  test "transport GenServer answers drain while a supervised API call is blocked" do
    token = "async-poll-test-#{System.unique_integer([:positive])}"
    :persistent_term.put({BlockingAPI, token}, self())
    on_exit(fn -> :persistent_term.erase({BlockingAPI, token}) end)

    state =
      RuntimeState.new(%{
        token: token,
        account_id: "test",
        api_mod: BlockingAPI,
        offset: 0,
        poll_interval_ms: 60_000
      })

    {:ok, server} = :proc_lib.start_link(__MODULE__, :start_loop, [state])
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    send(server, :poll)
    assert_receive {:poll_started, worker, 0}
    assert :ok = GenServer.call(server, :drain_pause, 1_000)
    assert Process.alive?(worker)
    send(worker, {:finish, {:ok, %{"ok" => true, "result" => []}}})
  end

  test "poll task failure clears the reference without killing the transport" do
    state =
      RuntimeState.new(%{
        token: self(),
        api_mod: BlockingAPI,
        offset: 0,
        poll_interval_ms: 60_000
      })

    {:noreply, polling} = Transport.handle_info(:poll, state)
    assert_receive {:poll_started, worker, 0}
    send(worker, :crash)
    ref = polling.poll_task.ref
    assert_receive {:DOWN, ^ref, :process, ^worker, reason}

    assert {:noreply, finished} =
             Transport.handle_info({:DOWN, ref, :process, worker, reason}, polling)

    refute Map.has_key?(finished, :poll_task)
  end

  test "init only defers bootstrap and never invokes the supplied API" do
    opts = [config: %{bot_token: "not-a-real-token", api_mod: BlockingAPI}]
    assert {:ok, ^opts, {:continue, :start}} = Transport.init(opts)
    refute_receive {:poll_started, _, _}, 0
  end

  test "token lock excludes another account and releases synchronously" do
    token = "lock-test-#{System.unique_integer([:positive])}"
    assert :ok = PollerLock.acquire("first", token)
    parent = self()

    contender =
      spawn_monitor(fn -> send(parent, {:lock_result, PollerLock.acquire("second", token)}) end)

    assert_receive {:lock_result, {:error, :locked}}
    {pid, ref} = contender
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    assert :ok = PollerLock.release("first", token)
    assert :ok = PollerLock.acquire("second", token)
    assert :ok = PollerLock.release("second", token)
  end

  test "a separate OS process cannot acquire the same token lock" do
    token = "os-lock-test-#{System.unique_integer([:positive])}"
    assert :ok = PollerLock.acquire("first", token)

    try do
      script =
        "{:ok, _} = Task.Supervisor.start_link(name: LemonChannels.Adapters.Telegram.AsyncSupervisor); IO.inspect(LemonChannels.Telegram.PollerLock.acquire(\"other-account\", #{inspect(token)}))"

      paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end)

      {output, status} =
        System.cmd(
          System.find_executable("elixir"),
          ["--erl", "+S 1:1"] ++ paths ++ ["-e", script], stderr_to_stdout: true)

      assert status == 0, output
      assert output =~ "{:error, :locked}"
    after
      PollerLock.release("first", token)
    end
  end
end
