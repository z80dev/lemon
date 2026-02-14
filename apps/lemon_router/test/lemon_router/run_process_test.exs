defmodule LemonRouter.RunProcessTest do
  @moduledoc """
  Tests for LemonRouter.RunProcess.

  Note: These are lightweight tests for the public API.
  Full integration testing with gateway should be done separately.
  """
  use ExUnit.Case, async: false

  alias LemonRouter.{RunProcess, SessionKey}

  defmodule TestOutboxAPI do
    @moduledoc false
    use Agent

    def start_link(opts) do
      notify_pid = opts[:notify_pid]
      Agent.start_link(fn -> %{calls: [], notify_pid: notify_pid} end, name: __MODULE__)
    end

    def calls, do: Agent.get(__MODULE__, fn s -> Enum.reverse(s.calls) end)

    def send_message(_token, chat_id, text, opts_or_reply_to \\ nil, parse_mode \\ nil) do
      record({:send, chat_id, text, opts_or_reply_to, parse_mode})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 101}}}
    end

    def edit_message_text(_token, chat_id, message_id, text, opts \\ nil) do
      record({:edit, chat_id, message_id, text, opts})
      {:ok, %{"ok" => true}}
    end

    def delete_message(_token, chat_id, message_id) do
      record({:delete, chat_id, message_id})
      {:ok, %{"ok" => true}}
    end

    defp record(call) do
      Agent.update(__MODULE__, fn s -> %{s | calls: [call | s.calls]} end)
      notify_pid = Agent.get(__MODULE__, & &1.notify_pid)
      if is_pid(notify_pid), do: send(notify_pid, {:outbox_api_call, call})
      :ok
    end
  end

  defmodule TestScheduler do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      notify_pid = opts[:notify_pid]
      GenServer.start_link(__MODULE__, %{notify_pid: notify_pid}, name: __MODULE__)
    end

    def submit(%LemonGateway.Types.Job{} = job) do
      GenServer.cast(__MODULE__, {:submit, job})
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast({:submit, job}, state) do
      if is_pid(state.notify_pid), do: send(state.notify_pid, {:test_scheduler_submit, job})
      {:noreply, state}
    end
  end

  setup do
    # Ensure PubSub is running for LemonCore.Bus.
    if is_nil(Process.whereis(LemonCore.PubSub)) do
      case start_supervised({Phoenix.PubSub, name: LemonCore.PubSub}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    # Ensure registries are running
    start_if_needed(LemonRouter.RunRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.RunRegistry)
    end)

    start_if_needed(LemonRouter.SessionRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.SessionRegistry)
    end)

    start_if_needed(LemonRouter.CoalescerRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.CoalescerRegistry)
    end)

    start_if_needed(LemonRouter.CoalescerSupervisor, fn ->
      DynamicSupervisor.start_link(strategy: :one_for_one, name: LemonRouter.CoalescerSupervisor)
    end)

    start_if_needed(LemonRouter.ToolStatusRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.ToolStatusRegistry)
    end)

    start_if_needed(LemonRouter.ToolStatusSupervisor, fn ->
      DynamicSupervisor.start_link(strategy: :one_for_one, name: LemonRouter.ToolStatusSupervisor)
    end)

    :ok
  end

  defp start_if_needed(name, start_fn) do
    if is_nil(Process.whereis(name)) do
      {:ok, _} = start_fn.()
    end
  end

  # Create a minimal job struct for testing
  defp make_test_job(run_id, meta \\ %{}) do
    %LemonGateway.Types.Job{
      scope: nil,
      run_id: run_id,
      session_key: nil,
      user_msg_id: 1,
      text: "test",
      queue_mode: :collect,
      engine_hint: "echo",
      meta: meta
    }
  end

  describe "start_link/1" do
    test "starts successfully with valid args" do
      run_id = "run_#{System.unique_integer()}"
      session_key = SessionKey.main("test-agent")
      job = make_test_job(run_id)

      result =
        RunProcess.start_link(%{
          run_id: run_id,
          session_key: session_key,
          job: job
        })

      # Process should start successfully (even if it completes quickly)
      assert {:ok, pid} = result
      assert is_pid(pid)
    end

    test "registers session_key -> run_id only when the gateway run starts" do
      run_id = "run_#{System.unique_integer()}"
      session_key = SessionKey.main("test-agent")

      job = make_test_job(run_id)

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false
               })

      # Not registered until :run_started
      assert [] == Registry.lookup(LemonRouter.SessionRegistry, session_key)

      event =
        LemonCore.Event.new(
          :run_started,
          %{run_id: run_id, session_key: session_key, engine: "echo"},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), event)

      assert eventually(fn ->
               case Registry.lookup(LemonRouter.SessionRegistry, session_key) do
                 [{_pid, %{run_id: ^run_id}}] -> true
                 _ -> false
               end
             end)

      GenServer.stop(pid)
    end

    test "single-flight contention does not cancel the new run; it retries registration until released" do
      run_id1 = "run_#{System.unique_integer()}"
      run_id2 = "run_#{System.unique_integer()}"
      session_key = SessionKey.main("test-agent")

      job1 = make_test_job(run_id1)
      job2 = make_test_job(run_id2)

      assert {:ok, pid1} =
               RunProcess.start_link(%{
                 run_id: run_id1,
                 session_key: session_key,
                 job: job1,
                 submit_to_gateway?: false
               })

      ev1 =
        LemonCore.Event.new(
          :run_started,
          %{run_id: run_id1, session_key: session_key, engine: "echo"},
          %{run_id: run_id1, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id1), ev1)

      assert eventually(fn ->
               case Registry.lookup(LemonRouter.SessionRegistry, session_key) do
                 [{_pid, %{run_id: ^run_id1}}] -> true
                 _ -> false
               end
             end)

      assert {:ok, pid2} =
               RunProcess.start_link(%{
                 run_id: run_id2,
                 session_key: session_key,
                 job: job2,
                 submit_to_gateway?: false
               })

      ev2 =
        LemonCore.Event.new(
          :run_started,
          %{run_id: run_id2, session_key: session_key, engine: "echo"},
          %{run_id: run_id2, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id2), ev2)

      # pid2 stays alive (the run is not cancelled).
      assert eventually(fn -> Process.alive?(pid2) end)

      # Still held by pid1 until it stops/unregisters.
      assert [{_pid, %{run_id: ^run_id1}}] =
               Registry.lookup(LemonRouter.SessionRegistry, session_key)

      GenServer.stop(pid1)

      assert eventually(fn ->
               case Registry.lookup(LemonRouter.SessionRegistry, session_key) do
                 [{_pid, %{run_id: ^run_id2}}] -> true
                 _ -> false
               end
             end)

      GenServer.stop(pid2)
    end
  end

  defp eventually(fun, timeout_ms \\ 500) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        do_eventually(fun, deadline)
      end
    end
  end

  describe "abort/2" do
    test "abort by non-existent run_id returns :ok" do
      # Abort on non-existent run should be safe
      assert :ok = RunProcess.abort("non-existent-run", :test_abort)
    end
  end

  describe ":submit_to_gateway retry/backoff" do
    test "retries until scheduler becomes available and submits the job once" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")
      job = make_test_job(run_id)

      assert Process.whereis(TestScheduler) == nil

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 gateway_scheduler: TestScheduler
               })

      assert eventually(fn ->
               state = :sys.get_state(pid)
               state.gateway_submit_attempt > 0
             end)

      refute_receive {:test_scheduler_submit, _job}, 20

      {:ok, _scheduler_pid} = start_supervised({TestScheduler, [notify_pid: self()]})

      assert_receive {:test_scheduler_submit, %LemonGateway.Types.Job{run_id: ^run_id}}, 1_500
      refute_receive {:test_scheduler_submit, _job}, 300

      GenServer.stop(pid)
    end

    test "does not submit after abort while waiting for scheduler" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")
      job = make_test_job(run_id)

      assert Process.whereis(TestScheduler) == nil

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 gateway_scheduler: TestScheduler
               })

      assert eventually(fn ->
               state = :sys.get_state(pid)
               state.gateway_submit_attempt > 0
             end)

      assert :ok = RunProcess.abort(pid, :test_abort)

      assert eventually(fn ->
               state = :sys.get_state(pid)
               state.aborted == true
             end)

      {:ok, _scheduler_pid} = start_supervised({TestScheduler, [notify_pid: self()]})

      refute_receive {:test_scheduler_submit, %LemonGateway.Types.Job{run_id: ^run_id}}, 400

      GenServer.stop(pid)
    end
  end

  describe "telegram final message resume indexing" do
    test "indexes the bot final message id so replies can resume the right engine/session" do
      {:ok, _} = start_supervised({TestOutboxAPI, [notify_pid: self()]})

      {:ok, _} =
        start_supervised(
          {LemonGateway.Telegram.Outbox,
           [bot_token: "token", api_mod: TestOutboxAPI, edit_throttle_ms: 0, use_markdown: false]}
        )

      run_id = "run_#{System.unique_integer([:positive])}"

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "botx",
          peer_kind: :dm,
          peer_id: "12345"
        })

      store_key = {"botx", 12_345, nil, 101}
      _ = LemonCore.Store.delete(:telegram_msg_resume, store_key)

      job =
        make_test_job(run_id, %{
          progress_msg_id: 111,
          user_msg_id: 222
        })

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false
               })

      completed_event =
        LemonCore.Event.new(
          :run_completed,
          %{
            completed: %{
              ok: true,
              answer: "Final answer",
              resume: %{engine: "codex", value: "thread_abc"}
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      # RunProcess stops after completion; give it a moment to tear down.
      assert eventually(fn -> not Process.alive?(pid) end)

      assert_receive {:outbox_api_call,
                      {:send, 12_345, "Final answer", %{reply_to_message_id: 222}, nil}},
                     1_000

      assert eventually(fn ->
               case LemonCore.Store.get(:telegram_msg_resume, store_key) do
                 %LemonGateway.Types.ResumeToken{engine: "codex", value: "thread_abc"} -> true
                 _ -> false
               end
             end)

      refute_receive {:outbox_api_call, {:delete, 12_345, _}}, 200
    end
  end

  describe "generated image tracking" do
    test "tracks image file_change paths from completed engine actions" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")
      job = make_test_job(run_id)

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false
               })

      action_event =
        LemonCore.Event.new(
          :engine_action,
          %{
            phase: :completed,
            ok: true,
            action: %{
              kind: "file_change",
              detail: %{
                changes: [
                  %{path: "artifacts/chart.png", kind: "added"},
                  %{path: "notes.txt", kind: "added"},
                  %{path: "artifacts/old.jpg", kind: "deleted"}
                ]
              }
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), action_event)

      assert eventually(fn ->
               state = :sys.get_state(pid)
               state.generated_image_paths == ["artifacts/chart.png"]
             end)

      GenServer.stop(pid)
    end

    test "tracks explicit auto_send_files from tool result metadata" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")
      job = %{make_test_job(run_id) | cwd: "/tmp/project"}

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false
               })

      action_event =
        LemonCore.Event.new(
          :engine_action,
          %{
            phase: :completed,
            ok: true,
            action: %{
              kind: "tool",
              detail: %{
                result_meta: %{
                  auto_send_files: [
                    %{path: "workspace/image.png", filename: "image.png", caption: "Generated"}
                  ]
                }
              }
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), action_event)

      assert eventually(fn ->
               state = :sys.get_state(pid)

               state.requested_send_files == [
                 %{path: "workspace/image.png", filename: "image.png", caption: "Generated"}
               ]
             end)

      GenServer.stop(pid)
    end
  end

  describe "SessionKey" do
    test "main/1 generates correct format" do
      key = SessionKey.main("my-agent")
      assert is_binary(key)
      assert String.starts_with?(key, "agent:my-agent:")
    end

    test "channel_peer/1 generates correct format" do
      key =
        SessionKey.channel_peer(%{
          agent_id: "my-agent",
          channel_id: "telegram",
          account_id: "bot123",
          peer_kind: :dm,
          peer_id: "user456"
        })

      assert is_binary(key)
      assert String.contains?(key, "telegram")
      assert String.contains?(key, "bot123")
    end
  end
end
