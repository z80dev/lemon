defmodule LemonRouter.RunProcessTest do
  alias Elixir.LemonRouter, as: LemonRouter

  @moduledoc """
  Tests for Elixir.LemonRouter.RunProcess.

  Note: These are lightweight tests for the public API.
  Full integration testing with gateway should be done separately.
  """
  use ExUnit.Case, async: false

  alias LemonCore.{RunRequest, SessionKey}
  alias LemonCore.ResumeToken
  alias Elixir.LemonRouter.RunProcess

  defmodule RunProcessTestOutboxAPI do
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

  defmodule RunProcessTestTelegramPlugin do
    @moduledoc false

    def id, do: "telegram"

    def meta do
      %{
        name: "Test Telegram",
        capabilities: %{
          edit_support: true,
          chunk_limit: 4096
        }
      }
    end

    def deliver(payload) do
      pid = :persistent_term.get({__MODULE__, :notify_pid}, nil)
      if is_pid(pid), do: send(pid, {:delivered, payload})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 101}}}
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

  defmodule TestRunOrchestrator do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      notify_pid = opts[:notify_pid]
      GenServer.start_link(__MODULE__, %{notify_pid: notify_pid, count: 0}, name: __MODULE__)
    end

    def submit(%RunRequest{} = request) do
      GenServer.call(__MODULE__, {:submit, request})
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:submit, request}, _from, state) do
      next = state.count + 1

      if is_pid(state.notify_pid) do
        send(state.notify_pid, {:test_run_orchestrator_submit, request, next})
      end

      {:reply, {:ok, "run_retry_#{next}"}, %{state | count: next}}
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
    start_if_needed(Elixir.LemonRouter.RunRegistry, fn ->
      Registry.start_link(keys: :unique, name: Elixir.LemonRouter.RunRegistry)
    end)

    start_if_needed(Elixir.LemonRouter.SessionRegistry, fn ->
      Registry.start_link(keys: :unique, name: Elixir.LemonRouter.SessionRegistry)
    end)

    start_if_needed(Elixir.LemonRouter.CoalescerRegistry, fn ->
      Registry.start_link(keys: :unique, name: Elixir.LemonRouter.CoalescerRegistry)
    end)

    start_if_needed(Elixir.LemonRouter.CoalescerSupervisor, fn ->
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        name: Elixir.LemonRouter.CoalescerSupervisor
      )
    end)

    start_if_needed(Elixir.LemonRouter.ToolStatusRegistry, fn ->
      Registry.start_link(keys: :unique, name: Elixir.LemonRouter.ToolStatusRegistry)
    end)

    start_if_needed(Elixir.LemonRouter.ToolStatusSupervisor, fn ->
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        name: Elixir.LemonRouter.ToolStatusSupervisor
      )
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
      run_id: run_id,
      session_key: nil,
      prompt: "test",
      queue_mode: :collect,
      engine_id: "echo",
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
      assert [] == Registry.lookup(Elixir.LemonRouter.SessionRegistry, session_key)

      event =
        LemonCore.Event.new(
          :run_started,
          %{run_id: run_id, session_key: session_key, engine: "echo"},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), event)

      assert eventually(fn ->
               case Registry.lookup(Elixir.LemonRouter.SessionRegistry, session_key) do
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
               case Registry.lookup(Elixir.LemonRouter.SessionRegistry, session_key) do
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
               Registry.lookup(Elixir.LemonRouter.SessionRegistry, session_key)

      GenServer.stop(pid1)

      assert eventually(fn ->
               case Registry.lookup(Elixir.LemonRouter.SessionRegistry, session_key) do
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

  describe "run watchdog timeout" do
    test "synthesizes run_completed and exits when a started run never completes" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")
      job = make_test_job(run_id)

      LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session_key))

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false,
                 run_watchdog_timeout_ms: 50
               })

      started_event =
        LemonCore.Event.new(
          :run_started,
          %{run_id: run_id, session_key: session_key, engine: "echo"},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), started_event)

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{
                         completed: %{ok: false, error: {:run_idle_watchdog_timeout, 50}}
                       },
                       meta: %{run_id: ^run_id, session_key: ^session_key, synthetic: true}
                     },
                     1_500

      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "activity extends watchdog timeout" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")
      job = make_test_job(run_id)

      LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session_key))

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false,
                 run_watchdog_timeout_ms: 80
               })

      started_event =
        LemonCore.Event.new(
          :run_started,
          %{run_id: run_id, session_key: session_key, engine: "echo"},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), started_event)

      Process.sleep(40)

      delta_event =
        LemonCore.Event.new(
          :delta,
          %{seq: 1, text: "still working"},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), delta_event)

      refute_receive %LemonCore.Event{type: :run_completed}, 50

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{
                         completed: %{ok: false, error: {:run_idle_watchdog_timeout, 80}}
                       },
                       meta: %{run_id: ^run_id, session_key: ^session_key, synthetic: true}
                     },
                     1_500

      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "telegram run enters keepalive confirmation window before timeout" do
      run_id = "run_#{System.unique_integer([:positive])}"

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "default",
          peer_kind: :group,
          peer_id: "12345",
          thread_id: "777"
        })

      job = make_test_job(run_id)

      LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session_key))

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false,
                 run_watchdog_timeout_ms: 40,
                 run_watchdog_confirm_timeout_ms: 120
               })

      started_event =
        LemonCore.Event.new(
          :run_started,
          %{run_id: run_id, session_key: session_key, engine: "echo"},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), started_event)

      assert eventually(
               fn ->
                 st = :sys.get_state(pid)
                 st.run_watchdog_awaiting_confirmation? == true
               end,
               1_000
             )

      RunProcess.keep_alive(run_id, :continue)

      assert eventually(
               fn ->
                 st = :sys.get_state(pid)
                 st.run_watchdog_awaiting_confirmation? == false
               end,
               1_000
             )

      RunProcess.keep_alive(run_id, :cancel)

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{completed: %{ok: false, error: :user_requested}},
                       meta: %{run_id: ^run_id, session_key: ^session_key, synthetic: true}
                     },
                     1_500

      assert eventually(fn -> not Process.alive?(pid) end)
    end
  end

  describe "zero-answer assistant retries" do
    test "auto-retries once with retry context in prompt" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")

      job =
        %{make_test_job(run_id, %{origin: :channel}) | prompt: "Collect the latest status report"}

      {:ok, _} =
        start_supervised(
          {__MODULE__.TestRunOrchestrator, [notify_pid: self()]}
        )

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false,
                 run_orchestrator: __MODULE__.TestRunOrchestrator
               })

      completed_event =
        LemonCore.Event.new(
          :run_completed,
          %{
            completed: %{
              ok: false,
              error: {:assistant_error, "HTTP 400: "},
              answer: ""
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      assert_receive {:test_run_orchestrator_submit, %RunRequest{} = retry_request, 1}, 1_000
      assert retry_request.session_key == session_key
      assert retry_request.prompt =~ "Retry notice:"
      assert retry_request.prompt =~ "check for partially completed work"
      assert retry_request.prompt =~ "Original request:"
      assert retry_request.prompt =~ "Collect the latest status report"
      assert retry_request.meta[:zero_answer_retry_attempt] == 1
      assert retry_request.meta[:zero_answer_retry_of_run] == run_id
      assert retry_request.meta[:zero_answer_retry_reason] =~ "HTTP 400"

      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "does not auto-retry when there is non-empty answer text" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")
      job = %{make_test_job(run_id, %{origin: :channel}) | prompt: "Do work"}

      {:ok, _} =
        start_supervised(
          {__MODULE__.TestRunOrchestrator, [notify_pid: self()]}
        )

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false,
                 run_orchestrator: __MODULE__.TestRunOrchestrator
               })

      completed_event =
        LemonCore.Event.new(
          :run_completed,
          %{
            completed: %{
              ok: false,
              error: {:assistant_error, "HTTP 400: "},
              answer: "partial output"
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      refute_receive {:test_run_orchestrator_submit, %RunRequest{}, _}, 300
      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "does not auto-retry when retry limit is already reached" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")

      job =
        %{
          make_test_job(run_id, %{origin: :channel, zero_answer_retry_attempt: 1})
          | prompt: "Do work"
        }

      {:ok, _} =
        start_supervised(
          {__MODULE__.TestRunOrchestrator, [notify_pid: self()]}
        )

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false,
                 run_orchestrator: __MODULE__.TestRunOrchestrator
               })

      completed_event =
        LemonCore.Event.new(
          :run_completed,
          %{
            completed: %{
              ok: false,
              error: {:assistant_error, "HTTP 400: "},
              answer: ""
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      refute_receive {:test_run_orchestrator_submit, %RunRequest{}, _}, 300
      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "does not auto-retry when assistant error is context overflow" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")
      job = %{make_test_job(run_id, %{origin: :channel}) | prompt: "Do work"}

      {:ok, _} =
        start_supervised(
          {__MODULE__.TestRunOrchestrator, [notify_pid: self()]}
        )

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false,
                 run_orchestrator: __MODULE__.TestRunOrchestrator
               })

      completed_event =
        LemonCore.Event.new(
          :run_completed,
          %{
            completed: %{
              ok: false,
              error:
                {:assistant_error,
                 "Codex error: %{\\\"error\\\" => %{\\\"code\\\" => \\\"context_length_exceeded\\\"}}"},
              answer: ""
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      refute_receive {:test_run_orchestrator_submit, %RunRequest{}, _}, 300
      assert eventually(fn -> not Process.alive?(pid) end)
    end
  end

  describe "context overflow recovery" do
    test "context_length_exceeded clears generic chat-state resume for non-telegram sessions" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")

      _ =
        LemonCore.Store.put_chat_state(session_key, %{
          last_engine: "codex",
          last_resume_token: "thread_old",
          updated_at: System.system_time(:millisecond)
        })

      job = make_test_job(run_id, %{origin: :channel})

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
              ok: false,
              error: %{
                "error" => %{
                  "code" => "context_length_exceeded",
                  "message" => "Your input exceeds the context window of this model."
                }
              }
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)
      assert eventually(fn -> LemonCore.Store.get_chat_state(session_key) == nil end)
    end
  end

  describe "final answer fanout delivery" do
    test "delivers final answer once per unique fanout route" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
      end)

      :persistent_term.put({__MODULE__.RunProcessTestTelegramPlugin, :notify_pid}, self())

      existing = LemonChannels.Registry.get_plugin("telegram")
      _ = LemonChannels.Registry.unregister("telegram")
      :ok = LemonChannels.Registry.register(__MODULE__.RunProcessTestTelegramPlugin)

      on_exit(fn ->
        _ =
          :persistent_term.erase({__MODULE__.RunProcessTestTelegramPlugin, :notify_pid})

        if is_pid(Process.whereis(LemonChannels.Registry)) do
          _ = LemonChannels.Registry.unregister("telegram")

          if is_atom(existing) and not is_nil(existing) do
            _ = LemonChannels.Registry.register(existing)
          end
        end
      end)

      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")

      fanout_routes = [
        %{channel_id: "telegram", account_id: "default", peer_kind: :dm, peer_id: "111"},
        %{channel_id: "telegram", account_id: "default", peer_kind: :dm, peer_id: "111"},
        %{channel_id: "telegram", account_id: "default", peer_kind: :dm, peer_id: "222"}
      ]

      job = make_test_job(run_id, %{fanout_routes: fanout_routes})

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
              answer: "Fanout answer"
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        meta: %{run_id: ^run_id, fanout: true} = meta_a
                      } = payload_a},
                     3_000

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        meta: %{run_id: ^run_id, fanout: true} = meta_b
                      } = payload_b},
                     3_000

      refute_receive {:delivered,
                      %LemonChannels.OutboundPayload{meta: %{run_id: ^run_id, fanout: true}}},
                     500

      assert meta_a[:fanout_index] in [1, 2]
      assert meta_b[:fanout_index] in [1, 2]
      assert meta_a[:fanout_index] != meta_b[:fanout_index]

      assert payload_a.content == "Fanout answer"
      assert payload_b.content == "Fanout answer"

      peer_ids =
        [payload_a.peer.id, payload_b.peer.id]
        |> Enum.sort()

      assert peer_ids == ["111", "222"]
    end
  end

  describe "telegram final message resume indexing" do
    test "indexes the bot final message id so replies can resume the right engine/session" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
      end)

      :persistent_term.put({__MODULE__.RunProcessTestTelegramPlugin, :notify_pid}, self())

      existing = LemonChannels.Registry.get_plugin("telegram")
      _ = LemonChannels.Registry.unregister("telegram")
      :ok = LemonChannels.Registry.register(__MODULE__.RunProcessTestTelegramPlugin)

      on_exit(fn ->
        _ =
          :persistent_term.erase({__MODULE__.RunProcessTestTelegramPlugin, :notify_pid})

        if is_pid(Process.whereis(LemonChannels.Registry)) do
          _ = LemonChannels.Registry.unregister("telegram")

          if is_atom(existing) and not is_nil(existing) do
            _ = LemonChannels.Registry.register(existing)
          end
        end
      end)

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

      assert eventually(fn ->
               case LemonCore.Store.get(:telegram_msg_resume, store_key) do
                 %ResumeToken{engine: "codex", value: "thread_abc"} -> true
                 _ -> false
               end
             end)
    end
  end

  describe "telegram context overflow recovery" do
    test "context_length_exceeded clears persisted resume state for the topic/session" do
      run_id = "run_#{System.unique_integer([:positive])}"

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "botx",
          peer_kind: :group,
          peer_id: "12345",
          thread_id: "777"
        })

      selected_key = {"botx", 12_345, 777}
      index_key = {"botx", 12_345, 777, 9_001}
      pending_compaction_key = {"botx", 12_345, 777}
      stale_resume = %ResumeToken{engine: "codex", value: "thread_old"}

      _ = LemonCore.Store.delete(:telegram_pending_compaction, pending_compaction_key)

      _ =
        LemonCore.Store.put_chat_state(session_key, %{
          last_engine: "codex",
          last_resume_token: "thread_old",
          updated_at: System.system_time(:millisecond)
        })

      _ = LemonCore.Store.put(:telegram_selected_resume, selected_key, stale_resume)
      _ = LemonCore.Store.put(:telegram_msg_session, index_key, session_key <> ":sub:old")
      _ = LemonCore.Store.put(:telegram_msg_resume, index_key, stale_resume)

      job = make_test_job(run_id, %{progress_msg_id: 111, user_msg_id: 222})

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
              ok: false,
              error: %{
                "error" => %{
                  "code" => "context_length_exceeded",
                  "message" => "Your input exceeds the context window of this model."
                }
              }
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)
      assert eventually(fn -> LemonCore.Store.get_chat_state(session_key) == nil end)
      assert LemonCore.Store.get(:telegram_selected_resume, selected_key) == nil
      assert LemonCore.Store.get(:telegram_msg_session, index_key) == nil
      assert LemonCore.Store.get(:telegram_msg_resume, index_key) == nil

      assert eventually(fn ->
               case LemonCore.Store.get(:telegram_pending_compaction, pending_compaction_key) do
                 %{reason: "overflow", session_key: ^session_key, set_at_ms: ts}
                 when is_integer(ts) ->
                   true

                 _ ->
                   false
               end
             end)
    end

    test "HTTP 413 payload-too-large errors clear persisted resume state for the topic/session" do
      run_id = "run_#{System.unique_integer([:positive])}"

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "botx",
          peer_kind: :group,
          peer_id: "12345",
          thread_id: "777"
        })

      selected_key = {"botx", 12_345, 777}
      index_key = {"botx", 12_345, 777, 9_002}
      pending_compaction_key = {"botx", 12_345, 777}
      stale_resume = %ResumeToken{engine: "codex", value: "thread_old"}

      _ = LemonCore.Store.delete(:telegram_pending_compaction, pending_compaction_key)

      _ =
        LemonCore.Store.put_chat_state(session_key, %{
          last_engine: "codex",
          last_resume_token: "thread_old",
          updated_at: System.system_time(:millisecond)
        })

      _ = LemonCore.Store.put(:telegram_selected_resume, selected_key, stale_resume)
      _ = LemonCore.Store.put(:telegram_msg_session, index_key, session_key <> ":sub:old")
      _ = LemonCore.Store.put(:telegram_msg_resume, index_key, stale_resume)

      job = make_test_job(run_id, %{progress_msg_id: 111, user_msg_id: 222})

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
              ok: false,
              error: "{:assistant_error, \"HTTP 413: Request Entity Too Large\"}"
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)
      assert eventually(fn -> LemonCore.Store.get_chat_state(session_key) == nil end)
      assert LemonCore.Store.get(:telegram_selected_resume, selected_key) == nil
      assert LemonCore.Store.get(:telegram_msg_session, index_key) == nil
      assert LemonCore.Store.get(:telegram_msg_resume, index_key) == nil

      assert eventually(fn ->
               case LemonCore.Store.get(:telegram_pending_compaction, pending_compaction_key) do
                 %{reason: "overflow", session_key: ^session_key, set_at_ms: ts}
                 when is_integer(ts) ->
                   true

                 _ ->
                   false
               end
             end)
    end

    test "marks pending compaction before overflow when input_tokens approaches threshold" do
      run_id = "run_#{System.unique_integer([:positive])}"

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "botx",
          peer_kind: :group,
          peer_id: "12345",
          thread_id: "777"
        })

      pending_compaction_key = {"botx", 12_345, 777}
      old_telegram_env = Application.get_env(:lemon_channels, :telegram)

      Application.put_env(:lemon_channels, :telegram, %{
        compaction: %{
          enabled: true,
          context_window_tokens: 1_000,
          reserve_tokens: 100,
          trigger_ratio: 0.95
        }
      })

      on_exit(fn ->
        if is_nil(old_telegram_env) do
          Application.delete_env(:lemon_channels, :telegram)
        else
          Application.put_env(:lemon_channels, :telegram, old_telegram_env)
        end
      end)

      _ = LemonCore.Store.delete(:telegram_pending_compaction, pending_compaction_key)

      job = make_test_job(run_id, %{progress_msg_id: 111, user_msg_id: 222})

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
              answer: "done",
              usage: %{input_tokens: 950, output_tokens: 50}
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)

      assert eventually(fn ->
               case LemonCore.Store.get(:telegram_pending_compaction, pending_compaction_key) do
                 %{
                   reason: "near_limit",
                   input_tokens: 950,
                   threshold_tokens: threshold,
                   context_window_tokens: 1_000,
                   session_key: ^session_key
                 }
                 when is_integer(threshold) and threshold <= 950 ->
                   true

                 _ ->
                   false
               end
             end)
    end

    test "marks pending compaction before overflow when usage input is reported as :input" do
      run_id = "run_#{System.unique_integer([:positive])}"

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "botx",
          peer_kind: :group,
          peer_id: "12345",
          thread_id: "777"
        })

      pending_compaction_key = {"botx", 12_345, 777}
      old_telegram_env = Application.get_env(:lemon_channels, :telegram)

      Application.put_env(:lemon_channels, :telegram, %{
        compaction: %{
          enabled: true,
          context_window_tokens: 1_000,
          reserve_tokens: 100,
          trigger_ratio: 0.95
        }
      })

      on_exit(fn ->
        if is_nil(old_telegram_env) do
          Application.delete_env(:lemon_channels, :telegram)
        else
          Application.put_env(:lemon_channels, :telegram, old_telegram_env)
        end
      end)

      _ = LemonCore.Store.delete(:telegram_pending_compaction, pending_compaction_key)

      job = make_test_job(run_id, %{progress_msg_id: 111, user_msg_id: 222})

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
              answer: "done",
              usage: %{input: 950, output: 50}
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)

      assert eventually(fn ->
               case LemonCore.Store.get(:telegram_pending_compaction, pending_compaction_key) do
                 %{
                   reason: "near_limit",
                   input_tokens: 950,
                   threshold_tokens: threshold,
                   context_window_tokens: 1_000,
                   session_key: ^session_key
                 }
                 when is_integer(threshold) and threshold <= 950 ->
                   true

                 _ ->
                   false
               end
             end)
    end

    test "counts cached input tokens toward preemptive compaction threshold" do
      run_id = "run_#{System.unique_integer([:positive])}"

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "botx",
          peer_kind: :group,
          peer_id: "12345",
          thread_id: "777"
        })

      pending_compaction_key = {"botx", 12_345, 777}
      old_telegram_env = Application.get_env(:lemon_channels, :telegram)

      Application.put_env(:lemon_channels, :telegram, %{
        compaction: %{
          enabled: true,
          context_window_tokens: 1_000,
          reserve_tokens: 100,
          trigger_ratio: 0.95
        }
      })

      on_exit(fn ->
        if is_nil(old_telegram_env) do
          Application.delete_env(:lemon_channels, :telegram)
        else
          Application.put_env(:lemon_channels, :telegram, old_telegram_env)
        end
      end)

      _ = LemonCore.Store.delete(:telegram_pending_compaction, pending_compaction_key)

      job = make_test_job(run_id, %{progress_msg_id: 111, user_msg_id: 222})

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
              answer: "done",
              usage: %{input_tokens: 200, cached_input_tokens: 750, output_tokens: 50}
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)

      assert eventually(fn ->
               case LemonCore.Store.get(:telegram_pending_compaction, pending_compaction_key) do
                 %{
                   reason: "near_limit",
                   input_tokens: 950,
                   threshold_tokens: threshold,
                   context_window_tokens: 1_000,
                   session_key: ^session_key
                 }
                 when is_integer(threshold) and threshold <= 950 ->
                   true

                 _ ->
                   false
               end
             end)
    end
  end

  describe "usage-missing fallback compaction marking" do
    test "marks pending compaction via char-based estimate when usage is nil" do
      run_id = "run_#{System.unique_integer([:positive])}"

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "botx",
          peer_kind: :group,
          peer_id: "12345",
          thread_id: "777"
        })

      pending_compaction_key = {"botx", 12_345, 777}
      old_telegram_env = Application.get_env(:lemon_channels, :telegram)

      # context_window=100, reserve=10, trigger_ratio=0.9 → threshold=min(90,90)=90
      # A prompt with 400 chars → 400/4 = 100 estimated tokens → 100 >= 90 → should mark
      Application.put_env(:lemon_channels, :telegram, %{
        compaction: %{
          enabled: true,
          context_window_tokens: 100,
          reserve_tokens: 10,
          trigger_ratio: 0.9
        }
      })

      on_exit(fn ->
        if is_nil(old_telegram_env) do
          Application.delete_env(:lemon_channels, :telegram)
        else
          Application.put_env(:lemon_channels, :telegram, old_telegram_env)
        end
      end)

      _ = LemonCore.Store.delete(:pending_compaction, session_key)
      _ = LemonCore.Store.delete(:telegram_pending_compaction, pending_compaction_key)

      # Create a job with a long prompt (400 chars → ~100 estimated tokens)
      long_prompt = String.duplicate("a", 400)

      job = %LemonGateway.Types.Job{
        run_id: run_id,
        session_key: session_key,
        prompt: long_prompt,
        queue_mode: :collect,
        engine_id: "echo",
        meta: %{progress_msg_id: 111, user_msg_id: 222}
      }

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false
               })

      # Send completed event with NO usage data
      completed_event =
        LemonCore.Event.new(
          :run_completed,
          %{
            completed: %{
              ok: true,
              answer: "done"
              # no usage field
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)

      # Should have set the generic pending_compaction marker via char estimate
      assert eventually(fn ->
               case LemonCore.Store.get(:pending_compaction, session_key) do
                 %{
                   reason: "near_limit",
                   input_tokens: estimated,
                   token_source: "char_estimate",
                   session_key: ^session_key
                 }
                 when is_integer(estimated) and estimated >= 90 ->
                   true

                 _ ->
                   false
               end
             end)

      # Clean up
      _ = LemonCore.Store.delete(:pending_compaction, session_key)
      _ = LemonCore.Store.delete(:telegram_pending_compaction, pending_compaction_key)
    end

    test "does not mark when char estimate is below threshold" do
      run_id = "run_#{System.unique_integer([:positive])}"

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "botx",
          peer_kind: :group,
          peer_id: "12345",
          thread_id: "888"
        })

      old_telegram_env = Application.get_env(:lemon_channels, :telegram)

      # context_window=1000, reserve=100, trigger_ratio=0.9 → threshold=min(900,900)=900
      # A prompt with 20 chars → 20/4 = 5 estimated tokens → 5 < 900 → should NOT mark
      Application.put_env(:lemon_channels, :telegram, %{
        compaction: %{
          enabled: true,
          context_window_tokens: 1_000,
          reserve_tokens: 100,
          trigger_ratio: 0.9
        }
      })

      on_exit(fn ->
        if is_nil(old_telegram_env) do
          Application.delete_env(:lemon_channels, :telegram)
        else
          Application.put_env(:lemon_channels, :telegram, old_telegram_env)
        end
      end)

      _ = LemonCore.Store.delete(:pending_compaction, session_key)

      job = %LemonGateway.Types.Job{
        run_id: run_id,
        session_key: session_key,
        prompt: "short prompt",
        queue_mode: :collect,
        engine_id: "echo",
        meta: %{progress_msg_id: 111, user_msg_id: 222}
      }

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
              answer: "done"
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)

      # Short prompt → below threshold → no marker
      Process.sleep(100)
      assert LemonCore.Store.get(:pending_compaction, session_key) == nil
    end

    test "does not mark when completion payload omits explicit ok=true" do
      run_id = "run_#{System.unique_integer([:positive])}"

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "botx",
          peer_kind: :group,
          peer_id: "12345",
          thread_id: "999"
        })

      old_telegram_env = Application.get_env(:lemon_channels, :telegram)

      Application.put_env(:lemon_channels, :telegram, %{
        compaction: %{
          enabled: true,
          context_window_tokens: 100,
          reserve_tokens: 10,
          trigger_ratio: 0.9
        }
      })

      on_exit(fn ->
        if is_nil(old_telegram_env) do
          Application.delete_env(:lemon_channels, :telegram)
        else
          Application.put_env(:lemon_channels, :telegram, old_telegram_env)
        end
      end)

      _ = LemonCore.Store.delete(:pending_compaction, session_key)

      job = %LemonGateway.Types.Job{
        run_id: run_id,
        session_key: session_key,
        prompt: String.duplicate("a", 400),
        queue_mode: :collect,
        engine_id: "echo",
        meta: %{progress_msg_id: 111, user_msg_id: 222}
      }

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
              answer: "done"
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)
      Process.sleep(100)
      assert LemonCore.Store.get(:pending_compaction, session_key) == nil
    end
  end

  describe "estimate_input_tokens_from_prompt/1" do
    test "returns char-based estimate for valid prompt" do
      state = %{job: %LemonGateway.Types.Job{prompt: String.duplicate("a", 400)}}
      assert RunProcess.estimate_input_tokens_from_prompt(state) == 100
    end

    test "returns nil when prompt is nil" do
      state = %{job: %LemonGateway.Types.Job{prompt: nil}}
      assert RunProcess.estimate_input_tokens_from_prompt(state) == nil
    end

    test "returns nil when job is missing" do
      state = %{job: nil}
      assert RunProcess.estimate_input_tokens_from_prompt(state) == nil
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
