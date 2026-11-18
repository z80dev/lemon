defmodule LemonCore.CrashLogRedactionTest do
  # Toggles the primary translator's SASL setting.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @secret "PRIVATE-T16F"

  defmodule Server do
    use GenServer

    def start(state), do: GenServer.start(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast({:raise, text}, _state), do: raise("model failed on #{text}")
    def handle_cast({:clause, text}, _state), do: clause(text)

    # Crashes while later messages are still queued.
    def handle_cast({:block_then_exit, test, text}, _state) do
      send(test, :blocked)
      Process.sleep(200)
      exit({:bad_answer, text})
    end

    def handle_cast({:exit, text}, _state), do: exit({:bad_answer, text})

    defp clause(:never), do: :ok
  end

  defmodule Machine do
    @behaviour :gen_statem

    def start(data), do: :gen_statem.start(__MODULE__, data, [])

    @impl true
    def callback_mode, do: :handle_event_function

    @impl true
    def init(data), do: {:ok, :idle, data, [{:state_timeout, 60_000, {:prompt, data.prompt}}]}

    @impl true
    def handle_event(:cast, {:clause, text}, _state, _data), do: clause(text)

    defp clause(:never), do: :ok
  end

  setup do
    # Also render proc_lib crash reports (message queues, dictionaries).
    %{filters: filters} = :logger.get_primary_config()
    {:logger_translator, {fun, config}} = List.keyfind(filters, :logger_translator, 0)

    :logger.update_primary_config(%{
      filters:
        List.keyreplace(
          filters,
          :logger_translator,
          0,
          {:logger_translator, {fun, %{config | sasl: true}}}
        )
    })

    on_exit(fn ->
      %{filters: now} = :logger.get_primary_config()

      :logger.update_primary_config(%{
        filters: List.keyreplace(now, :logger_translator, 0, {:logger_translator, {fun, config}})
      })
    end)

    :ok
  end

  test "is installed ahead of Elixir's translator" do
    ids = Enum.map(:logger.get_primary_config().filters, &elem(&1, 0))
    assert hd(ids) == :lemon_crash_log_redaction
  end

  test "exception message secret is not logged" do
    log = crash(fn pid -> GenServer.cast(pid, {:raise, @secret}) end)

    assert log =~ "GenServer"
    assert log =~ "RuntimeError (message redacted)"
    refute log =~ @secret
  end

  test "function-clause argument secret is not logged" do
    log = crash(fn pid -> GenServer.cast(pid, {:clause, @secret}) end)

    assert log =~ "no function clause matching"
    refute log =~ @secret
  end

  test "pending mailbox messages, last message and state are not logged" do
    log =
      crash(fn pid ->
        GenServer.cast(pid, {:block_then_exit, self(), @secret})
        assert_receive :blocked
        send(pid, {:pending, @secret})
        GenServer.cast(pid, {:queued, @secret})
      end)

    assert log =~ "Message Queue Length: 2"
    refute log =~ @secret
  end

  test "gen_statem queue, data, timeouts and argument secrets are not logged" do
    {:ok, pid} = Machine.start(%{prompt: @secret})
    ref = Process.monitor(pid)

    log =
      capture_log(fn ->
        :gen_statem.cast(pid, {:clause, @secret})
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
        Process.sleep(100)
      end)

    assert log =~ "gen_statem"
    refute log =~ @secret
  end

  test "task terminating reports drop the exception message" do
    log =
      capture_log(fn ->
        {:ok, pid} = Task.start(fn -> raise "task saw #{@secret}" end)
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
        Process.sleep(100)
      end)

    assert log =~ "Task"
    refute log =~ @secret
  end

  defp crash(fun) do
    {:ok, pid} = Server.start(%{prompt: @secret, messages: [@secret]})
    ref = Process.monitor(pid)

    capture_log(fn ->
      fun.(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 2_000
      Process.sleep(100)
    end)
  end
end
