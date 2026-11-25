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
      start_supervised!(LemonCore.TaskSupervisor.child_spec(name: @supervisor))
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

    # The drain is answered by the event worker, never blocked by the poll.
    tag = make_ref()
    assert {:noreply, paused} = Transport.handle_call(:drain_pause, {self(), tag}, polling)
    assert_receive {^tag, :ok}
    {%Task{ref: drain_ref}, {:drain_flush, _from}} = paused.event_task
    assert_receive {^drain_ref, drained}
    assert {:noreply, paused} = Transport.handle_info({drain_ref, drained}, paused)

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

  test "full and missing supervisors leave polling unstarted and release rejected lock claims" do
    tasks =
      start_supervised!(
        Supervisor.child_spec(
          LemonCore.TaskSupervisor.child_spec(max_children: 1),
          id: :saturated_poll_tasks
        )
      )

    assert {:ok, _blocker} =
             LemonCore.TaskSupervisor.start_child(tasks, fn ->
               receive do
                 :release -> :ok
               end
             end)

    state =
      RuntimeState.new(%{
        token: self(),
        api_mod: BlockingAPI,
        offset: 7,
        poll_interval_ms: 60_000
      })

    original = Process.whereis(@supervisor)
    Process.unregister(@supervisor)
    token = "rejected-lock-#{System.unique_integer([:positive])}"

    try do
      assert {:noreply, ^state} = Transport.handle_info(:poll, state)
      assert {:error, :locked} = PollerLock.acquire("missing", token)
      Process.register(tasks, @supervisor)
      assert {:noreply, ^state} = Transport.handle_info(:poll, state)
      assert {:error, :locked} = PollerLock.acquire("full", token)
      refute_receive {:poll_started, _, _}, 0
    after
      if Process.whereis(@supervisor) == tasks, do: Process.unregister(@supervisor)
      Process.register(original, @supervisor)
    end

    assert :ok = PollerLock.acquire("restored", token)
    assert :ok = PollerLock.release("restored", token)
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
          ["--erl", "+S 1:1"] ++ paths ++ ["-e", script],
          stderr_to_stdout: true
        )

      assert status == 0, output
      assert output =~ "{:error, :locked}"
    after
      PollerLock.release("first", token)
    end
  end

  defmodule VoiceAPI do
    @chat_id 650_650

    def chat_id, do: @chat_id

    def get_updates(token, _offset, _timeout) do
      if :persistent_term.get({__MODULE__, token}, false) do
        {:ok, %{"ok" => true, "result" => []}}
      else
        :persistent_term.put({__MODULE__, token}, true)
        {:ok, %{"ok" => true, "result" => [voice_update()]}}
      end
    end

    defp voice_update do
      %{
        "update_id" => 1,
        "message" => %{
          "message_id" => 10,
          "date" => 1,
          "chat" => %{"id" => @chat_id, "type" => "private"},
          "from" => %{"id" => 7, "is_bot" => false, "first_name" => "z"},
          "voice" => %{"file_id" => "voice-1", "file_size" => 3, "mime_type" => "audio/ogg"}
        }
      }
    end

    def get_file(_token, _file_id),
      do: {:ok, %{"ok" => true, "result" => %{"file_path" => "v.ogg"}}}

    def download_file(_token, _path), do: {:ok, "ogg"}
    def send_message(_token, _chat_id, _text, _opts, _parse_mode), do: {:ok, %{"ok" => true}}
  end

  defmodule SlowTranscriber do
    def transcribe(_request) do
      send(:persistent_term.get({__MODULE__, :owner}), {:transcribing, self()})

      receive do
        :release -> {:ok, "hello"}
      end
    end
  end

  test "allowlist updates and drain are answered while a voice note is transcribing" do
    token = "voice-#{System.unique_integer([:positive])}"
    :persistent_term.put({SlowTranscriber, :owner}, self())

    on_exit(fn ->
      :persistent_term.erase({SlowTranscriber, :owner})
      :persistent_term.erase({VoiceAPI, token})
    end)

    state =
      RuntimeState.new(%{
        token: token,
        account_id: "voice-test",
        api_mod: VoiceAPI,
        offset: 0,
        poll_interval_ms: 60_000,
        allowed_chat_ids: [VoiceAPI.chat_id()],
        voice_transcription: true,
        voice_transcriber: SlowTranscriber,
        voice_transcription_api_key: "test-key",
        voice_transcription_provider: "openai_transcribe",
        voice_transcription_model: "m",
        voice_transcription_base_url: nil,
        voice_max_bytes: 1_000,
        deny_unbound_chats: false
      })

    {:ok, server} = :proc_lib.start_link(__MODULE__, :start_loop, [state])
    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    send(server, :poll)
    assert_receive {:transcribing, transcriber}, 2_000

    assert :ok = GenServer.call(server, {:update_allowlist, :add, 99}, 1_000)
    assert :ok = GenServer.call(server, :drain_pause, 1_000)
    assert 99 in :sys.get_state(server, 1_000).allowed_chat_ids
    assert Process.alive?(transcriber)
    send(transcriber, :release)
  end

  defmodule SlowIdentityAPI do
    def get_me(token) do
      send(:persistent_term.get({__MODULE__, token}), {:get_me, self()})

      receive do
        :release -> {:ok, %{"ok" => true, "result" => %{"id" => 5, "username" => "slow_bot"}}}
      end
    end

    def get_updates(token, _offset, _timeout) do
      send(:persistent_term.get({__MODULE__, token}), :polled)
      {:ok, %{"ok" => true, "result" => []}}
    end

    def set_my_commands(_token, _commands), do: {:ok, %{"ok" => true}}
  end

  test "lock retry starts in a task: allowlist and drain are answered while getMe blocks" do
    token = "slow-identity-#{System.unique_integer([:positive])}"
    :persistent_term.put({SlowIdentityAPI, token}, self())
    on_exit(fn -> :persistent_term.erase({SlowIdentityAPI, token}) end)

    # Another runtime holds the token, so start-up goes through the retry path.
    holder = spawn(fn -> Process.sleep(:infinity) end)

    lock =
      {PollerLock,
       "telegram-poller-" <> Base.encode16(:crypto.hash(:sha256, token), case: :lower)}

    :yes = :global.register_name(lock, holder)

    {:ok, server} =
      GenServer.start(Transport,
        config: %{
          bot_token: token,
          account_id: "slow-identity",
          api_mod: SlowIdentityAPI,
          allowed_chat_ids: [1],
          poll_interval_ms: 60_000,
          poller_lock_retry_ms: 20
        }
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    assert :sys.get_state(server, 1_000)[:awaiting_poller_lock]
    Process.exit(holder, :kill)

    assert_receive {:get_me, identity_task}, 2_000
    assert :ok = GenServer.call(server, {:update_allowlist, :add, 99}, 1_000)
    assert :ok = GenServer.call(server, :drain_pause, 1_000)
    send(identity_task, :release)

    started = wait_for_state(server, &Map.has_key?(&1, :bot_id))
    assert {started.bot_id, started.bot_username} == {5, "slow_bot"}
    assert started.allowed_chat_ids == [1, 99]
    assert started.drain_paused?
    refute_receive :polled, 100
  end

  defp wait_for_state(server, fun, attempts \\ 100) do
    state = :sys.get_state(server, 1_000)

    cond do
      fun.(state) ->
        state

      attempts == 0 ->
        flunk("transport did not reach the expected state: #{inspect(state)}")

      true ->
        receive do
        after
          10 -> wait_for_state(server, fun, attempts - 1)
        end
    end
  end
end
