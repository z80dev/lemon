defmodule LemonRouter.RunProcessTest do
  alias Elixir.LemonRouter, as: LemonRouter

  @moduledoc """
  Tests for Elixir.LemonRouter.RunProcess.

  Note: These are lightweight tests for the public API.
  """
  use ExUnit.Case, async: false

  alias Elixir.LemonRouter.RunProcess
  alias LemonChannels.Outbox.{Dedupe}
  alias LemonCore.RateLimiter
  alias LemonChannels.Telegram.{ResumeIndexStore, StateStore}
  alias LemonCore.{ChatStateStore, ResumeToken, RunRequest, SessionKey}
  alias LemonRouter.{EngineSessionClaim, PendingCompactionStore, TestExecutor}

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

  defmodule RunProcessToolStatusIntentDispatcherStub do
    @moduledoc false

    def dispatch(%LemonCore.DeliveryIntent{} = intent) do
      case :persistent_term.get({__MODULE__, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:dispatched_intent, intent})
        _ -> :ok
      end

      :ok
    end
  end

  defmodule RejectingExecutor do
    @behaviour CodingAgent.Executor.Behaviour

    def start_run(command, _opts, _sink) do
      send(command.meta.test_pid, {:executor_rejected, command.run_id})
      {:error, :temporary_failure}
    end

    def cancel(_ctx), do: :ok
    def steer(_ctx, _text), do: {:error, :unsupported}
    def redirect(_ctx, _text), do: {:error, :unsupported}
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

  defmodule RaisingArtifactTracker do
    @moduledoc false

    def track_generated_images(state, _action_event), do: state
    def track_requested_send_files(state, _action_event), do: state
    def finalize_meta(_state, _answer), do: raise("artifact finalize boom")
  end

  setup do
    previous = Application.fetch_env(:lemon_router, :test_executor)
    Application.put_env(:lemon_router, :test_executor, TestExecutor)

    on_exit(fn ->
      case previous do
        {:ok, executor} -> Application.put_env(:lemon_router, :test_executor, executor)
        :error -> Application.delete_env(:lemon_router, :test_executor)
      end
    end)

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

  # Create a minimal execution request for testing
  defp make_test_request(run_id, meta \\ %{}, attrs \\ %{}) do
    struct(
      %LemonCore.ExecutionCommand{
        run_id: run_id,
        session_key: nil,
        prompt: "test",
        conversation_key: {:session, "test:#{run_id}"},
        meta: Map.put(meta, :test_pid, self())
      },
      attrs
    )
  end

  describe "start_link/1" do
    test "starts successfully with valid args" do
      run_id = "run_#{System.unique_integer()}"
      session_key = SessionKey.main("test-agent-#{run_id}")
      job = make_test_request(run_id)

      result =
        RunProcess.start_link(%{
          run_id: run_id,
          session_key: session_key,
          execution_request: job
        })

      # Process should start successfully (even if it completes quickly)
      assert {:ok, pid} = result
      assert is_pid(pid)
      TestExecutor.complete(runner_for(run_id))
      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "uses normalized execution request session_key as authoritative state" do
      run_id = "run_#{System.unique_integer()}"
      request_session_key = SessionKey.main("request-agent")
      init_session_key = SessionKey.main("init-agent")

      request =
        make_test_request(run_id, %{}, %{
          session_key: request_session_key,
          conversation_key: {:session, request_session_key}
        })

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: init_session_key,
                 execution_request: request
               })

      assert eventually(fn ->
               {_phase, state} = :sys.get_state(pid)

               state.session_key == request_session_key and
                 state.execution_request.session_key == request_session_key and
                 state.conversation_key == {:session, request_session_key}
             end)

      TestExecutor.complete(runner_for(run_id))
      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "rejects legacy job-only initialization" do
      run_id = "run_#{System.unique_integer()}"
      session_key = SessionKey.main("test-agent-#{run_id}")
      previous = Process.flag(:trap_exit, true)

      job = %{
        run_id: run_id,
        session_key: session_key,
        prompt: "test"
      }

      on_exit(fn -> Process.flag(:trap_exit, previous) end)

      result =
        RunProcess.start_link(%{
          run_id: run_id,
          session_key: session_key,
          job: job
        })

      case result do
        {:error, reason} ->
          assert reason in [
                   {:invalid_execution_request, run_id},
                   {:shutdown, {:invalid_execution_request, run_id}}
                 ]

        other ->
          flunk("expected invalid execution request error, got: #{inspect(other)}")
      end
    end

    test "owns the session key until death without coordinator cleanup" do
      run_id = "run_#{System.unique_integer([:positive])}"
      request = make_test_request(run_id, %{}, %{session_key: "test:#{run_id}"})
      session_key = request.session_key

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 execution_request: request
               })

      assert [{^pid, %{run_id: ^run_id}}] =
               Registry.lookup(LemonRouter.SessionRegistry, session_key)

      _ = runner_for(run_id)
      Process.unlink(pid)
      monitor = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
      # Registry synchronizes dead-owner cleanup before attempting registration.
      assert {:ok, _} = Registry.register(LemonRouter.SessionRegistry, session_key, :replacement)
      Registry.unregister(LemonRouter.SessionRegistry, session_key)
    end

    test "rejects a second live owner atomically" do
      run_id = "run_#{System.unique_integer([:positive])}"
      request = make_test_request(run_id, %{}, %{session_key: "test:#{run_id}"})

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 execution_request: request
               })

      _ = runner_for(run_id)
      previous = Process.flag(:trap_exit, true)

      try do
        other_id = "run_#{System.unique_integer([:positive])}"

        assert {:error, :session_busy} =
                 RunProcess.start_link(%{
                   run_id: other_id,
                   execution_request: %{request | run_id: other_id}
                 })
      after
        GenServer.stop(pid)
        Process.flag(:trap_exit, previous)
      end
    end
  end

  defp eventually(fun, timeout_ms \\ 5_000) when is_function(fun, 0) do
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

  defp flush_answer_delta(run_pid, session_key, run_id, seq) do
    assert eventually(fn ->
             match?({_, %{run_id: ^run_id, saw_delta: true}}, :sys.get_state(run_pid))
           end)

    # Coalescers outlive runs, so a sequence number alone can match a previous
    # run and let the flush race the current run's delta.
    assert eventually(fn ->
             case Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, "telegram"}) do
               [{coalescer_pid, _}] ->
                 match?(
                   %{run_id: ^run_id, last_seq: ^seq, overflowed: false},
                   :sys.get_state(coalescer_pid)
                 )

               _ ->
                 false
             end
           end)

    LemonRouter.StreamCoalescer.flush(session_key, "telegram")
  end

  describe "abort/2" do
    test "abort by non-existent run_id returns :ok" do
      # Abort on non-existent run should be safe
      assert :ok = RunProcess.abort("non-existent-run", :test_abort)
    end

    test "aborted run waiting for its engine session synthesizes completion and exits" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent-#{run_id}")
      job = make_test_request(run_id)
      :ok = EngineSessionClaim.claim({:session, session_key})

      LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session_key))

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 execution_request: job
               })

      assert :ok = RunProcess.abort(pid, :test_abort)

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{completed: %{ok: false, error: :test_abort}},
                       meta: %{run_id: ^run_id, session_key: ^session_key, synthetic: true}
                     },
                     1_500

      assert eventually(fn -> not Process.alive?(pid) end)
    end
  end

  test "adopts a completion from another writer and does not republish it" do
    {run_id, session_key, pid} = start_started_run()
    monitor = Process.monitor(pid)
    :ok = LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(run_id))

    event =
      LemonCore.Event.new(
        :run_completed,
        LemonCore.Events.RunCompleted.new(%{
          completed: LemonCore.Events.Completion.new(%{ok: true, answer: "done"})
        }),
        %{run_id: run_id, session_key: session_key}
      )

    command = make_test_request(run_id, %{}, %{session_key: session_key})
    assert {:published, _} = LemonRouter.RunCompletion.finalize(command, event, [])

    assert_receive %LemonCore.Event{
      type: :run_completed,
      payload: %{completed: %{ok: true, answer: "done"}}
    }

    assert_receive %LemonCore.Event{
      type: :run_completed,
      payload: %{completed: %{ok: true, answer: "done"}}
    }

    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    refute_receive %LemonCore.Event{type: :run_completed}
  end

  describe "suspend_for_restart/3" do
    test "waits for an executing tool to finish, then stops cleanly" do
      {run_id, session_key, pid} = start_started_run()

      broadcast_action(run_id, session_key, "tool-1", :started)
      :ok = RunProcess.suspend_for_restart(pid, self(), :boundary)
      refute_receive {:restart_suspended, ^run_id, _, _}, 200

      broadcast_action(run_id, session_key, "tool-1", :completed)
      assert_receive {:restart_suspended, ^run_id, :clean, []}, 1_000

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{completed: %{ok: false, error: :runtime_restart}}
                     },
                     2_500

      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "forced suspension mid-tool reports the action as uncertain" do
      {run_id, session_key, pid} = start_started_run()

      broadcast_action(run_id, session_key, "tool-1", :started)
      broadcast_action(run_id, session_key, "note-1", :started, :note)
      :ok = RunProcess.suspend_for_restart(pid, self(), :now)

      assert_receive {:restart_suspended, ^run_id, :uncertain, ["bash: sleep 60"]}, 1_000
    end

    test "a run awaiting admission reports :not_started" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent-#{run_id}")

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 execution_request: make_test_request(run_id)
               })

      :ok = RunProcess.suspend_for_restart(pid, self())
      assert_receive {:restart_suspended, ^run_id, :not_started, []}, 1_000
    end
  end

  defp start_started_run do
    run_id = "run_#{System.unique_integer([:positive])}"
    session_key = SessionKey.main("test-agent-#{run_id}")
    LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session_key))

    assert {:ok, pid} =
             RunProcess.start_link(%{
               run_id: run_id,
               session_key: session_key,
               execution_request: make_test_request(run_id)
             })

    _ = runner_for(run_id)
    assert_receive %LemonCore.Event{type: :run_started}, 1_000
    {run_id, session_key, pid}
  end

  defp broadcast_action(run_id, _session_key, id, phase, kind \\ :tool) do
    TestExecutor.action(runner_for(run_id), %{
      id: id,
      kind: kind,
      title: "bash: sleep 60",
      phase: phase,
      ok: if(phase == :completed, do: true)
    })

    assert_receive %LemonCore.Event{type: :engine_action, payload: %{phase: ^phase}}, 1_000
  end

  defp runner_for(run_id) do
    Process.get({:runner, run_id}) ||
      receive do
        {:test_executor_started, ^run_id, runner, _owner} ->
          Process.put({:runner, run_id}, runner)
          on_exit(fn -> Process.exit(runner, :kill) end)
          runner
      after
        2_000 -> flunk("executor did not start for #{run_id}")
      end
  end

  defp execute_event(run_id, %LemonCore.Event{type: :delta, payload: payload}) do
    TestExecutor.delta(runner_for(run_id), payload.text)
    :ok
  end

  defp execute_event(run_id, %LemonCore.Event{type: :engine_action, payload: payload}) do
    action =
      %{id: "action-#{System.unique_integer([:positive])}", title: "Action"}
      |> Map.merge(payload.action)
      |> Map.merge(Map.take(payload, [:phase, :ok, :message, :level]))

    TestExecutor.action(runner_for(run_id), action)
    :ok
  end

  defp execute_event(run_id, %LemonCore.Event{type: :run_completed, payload: payload}) do
    fields = Map.take(payload.completed, [:ok, :answer, :error, :resume, :meta, :usage])
    TestExecutor.complete(runner_for(run_id), Map.put_new(fields, :ok, nil))
    :ok
  end

  defp start_admission(run_id, session_key, opts \\ []) do
    start_supervised!(
      {RunProcess,
       Map.merge(
         %{
           run_id: run_id,
           session_key: session_key,
           execution_request: make_test_request(run_id)
         },
         Map.new(opts)
       )}
    )
  end

  describe "admission and execution" do
    test "a definite executor rejection terminalizes exactly once without retrying" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main(run_id)
      :ok = LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session_key))
      start_admission(run_id, session_key, executor: RejectingExecutor)

      assert_receive {:executor_rejected, ^run_id}

      assert_receive %LemonCore.Event{
        type: :run_completed,
        meta: %{run_id: ^run_id, synthetic: true},
        payload: %{completed: %{ok: false, error: :temporary_failure}}
      }

      refute_receive {:executor_rejected, ^run_id}
      refute_received %LemonCore.Event{type: :run_completed}
    end

    test "session contention retries only until the submission deadline" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main(run_id)
      :ok = EngineSessionClaim.claim({:session, session_key})
      :ok = LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session_key))
      pid = start_admission(run_id, session_key, submit_deadline_ms: 300)

      assert {:submitting, %{submit_attempt: attempt, submit_last_error: :session_in_use}} =
               :sys.get_state(pid)

      assert attempt > 0

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       meta: %{
                         run_id: ^run_id,
                         synthetic: true,
                         failure_stage: :runtime_submission
                       },
                       payload: %{
                         completed: %{
                           ok: false,
                           error: %{
                             type: :runtime_submission_failed,
                             reason: :session_in_use,
                             attempts: attempts,
                             deadline_ms: 300
                           }
                         }
                       }
                     },
                     2_000

      assert attempts > 1
      refute_receive {:test_executor_started, ^run_id, _, _}
      refute_received %LemonCore.Event{type: :run_completed}
    end

    test "retries a busy engine session and starts the executor once when released" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main(run_id)
      key = {:session, session_key}
      :ok = EngineSessionClaim.claim(key)
      pid = start_admission(run_id, session_key)
      assert {:submitting, %{submit_attempt: attempt}} = :sys.get_state(pid)
      assert attempt > 0
      refute_receive {:test_executor_started, ^run_id, _, _}, 20
      :ok = EngineSessionClaim.release(key)
      runner = runner_for(run_id)
      assert {:running, %{executor_pid: ^runner, submit_attempt: 0}} = :sys.get_state(pid)
      refute_receive {:test_executor_started, ^run_id, _, _}
      TestExecutor.complete(runner)
    end

    test "projected child task actions attach to the existing task surface" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        RateLimiter.start_link([])
      end)

      start_if_needed(Dedupe, fn ->
        Dedupe.start_link([])
      end)

      start_if_needed(LemonChannels.PresentationState, fn ->
        LemonChannels.PresentationState.start_link([])
      end)

      :persistent_term.put({__MODULE__.RunProcessTestTelegramPlugin, :notify_pid}, self())

      existing = LemonChannels.Registry.get_plugin("telegram")
      _ = LemonChannels.Registry.unregister("telegram")
      :ok = LemonChannels.Registry.register(__MODULE__.RunProcessTestTelegramPlugin)

      on_exit(fn ->
        _ = :persistent_term.erase({__MODULE__.RunProcessTestTelegramPlugin, :notify_pid})

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

      job =
        make_test_request(run_id, %{
          progress_msg_id: 111,
          user_msg_id: 222
        })

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 execution_request: job
               })

      task_surface = {:status_task, "task_root_projected"}

      task_started =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_root_projected",
              kind: "subagent",
              title: "task(codex): review fix",
              detail: %{name: "task"}
            },
            phase: :started
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = execute_event(run_id, task_started)

      assert eventually(fn ->
               Registry.lookup(
                 LemonRouter.ToolStatusRegistry,
                 {session_key, "telegram", task_surface}
               ) != []
             end)

      projected_child =
        LemonCore.Event.new(
          :task_projected_child_action,
          %{
            engine: "codex",
            action: %{
              id: "taskproj:child_run_1:read_1",
              kind: "tool",
              title: "Read: AGENTS.md",
              detail: %{
                parent_tool_use_id: "task_root_projected",
                child_run_id: "child_run_1",
                task_id: "task-store-1"
              }
            },
            phase: :completed,
            ok: true,
            message: nil,
            level: nil
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), projected_child)

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] ->
                   state = :sys.get_state(status_pid)

                   Enum.any?(Map.values(state.actions), fn action ->
                     action[:detail][:parent_tool_use_id] == "task_root_projected" and
                       action[:title] == "Read: AGENTS.md"
                   end)

                 _ ->
                   false
               end
             end)

      LemonRouter.ToolStatusCoalescer.flush(session_key, "telegram", surface: task_surface)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: kind,
                        content: content,
                        meta: %{run_id: ^run_id}
                      }},
                     1_500

      assert kind in [:text, :edit]

      task_text =
        case content do
          %{text: text} -> text
          text when is_binary(text) -> text
        end

      assert String.contains?(task_text, "task(codex): review fix")
      assert String.contains?(task_text, "Read: AGENTS.md")

      refute eventually(
               fn ->
                 Registry.lookup(
                   LemonRouter.ToolStatusRegistry,
                   {session_key, "telegram", :status}
                 ) !=
                   []
               end,
               500
             )

      GenServer.stop(pid)
    end

    test "failed tool action metadata reaches session subscribers and status intents" do
      previous_dispatcher = Application.get_env(:lemon_router, :dispatcher)
      Application.put_env(:lemon_router, :dispatcher, RunProcessToolStatusIntentDispatcherStub)
      :persistent_term.put({RunProcessToolStatusIntentDispatcherStub, :test_pid}, self())

      on_exit(fn ->
        :persistent_term.erase({RunProcessToolStatusIntentDispatcherStub, :test_pid})

        if is_nil(previous_dispatcher) do
          Application.delete_env(:lemon_router, :dispatcher)
        else
          Application.put_env(:lemon_router, :dispatcher, previous_dispatcher)
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

      result_meta = %{
        error_type: :tool_task_timeout,
        tool_name: "slow_tool",
        timeout_ms: 123,
        exception: "RuntimeError",
        message: "timed out waiting for slow_tool"
      }

      LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session_key))

      job =
        make_test_request(
          run_id,
          %{progress_msg_id: 111, user_msg_id: 222},
          %{session_key: session_key, conversation_key: {:session, session_key}}
        )

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 execution_request: job
               })

      action_event =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            phase: :completed,
            ok: false,
            action: %{
              id: "tool_timeout_1",
              kind: "tool",
              title: "slow_tool",
              detail: %{
                name: "slow_tool",
                result: "Tool slow_tool timed out",
                result_meta: result_meta
              }
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = execute_event(run_id, action_event)

      assert_receive %LemonCore.Event{
                       type: :engine_action,
                       payload: %{
                         action: %{
                           detail: %{result_meta: ^result_meta}
                         }
                       }
                     },
                     1_000

      assert eventually(
               fn ->
                 case Registry.lookup(
                        LemonRouter.ToolStatusRegistry,
                        {session_key, "telegram"}
                      ) do
                   [{status_pid, _}] ->
                     state = :sys.get_state(status_pid)
                     action = Map.get(state.actions, "tool_timeout_1")
                     get_in(action, [:detail, :result_meta]) == result_meta

                   _ ->
                     false
                 end
               end,
               1_500
             )

      LemonRouter.ToolStatusCoalescer.flush(session_key, "telegram")

      assert_receive {:dispatched_intent,
                      %LemonCore.DeliveryIntent{
                        kind: :tool_status_snapshot,
                        body: %{tool_failures: [failure]}
                      }},
                     1_000

      assert failure == %{
               id: "tool_timeout_1",
               title: "slow_tool",
               kind: :tool,
               ok: false,
               error_type: :tool_task_timeout,
               tool_name: "slow_tool",
               timeout_ms: 123,
               exception: "RuntimeError",
               message: "timed out waiting for slow_tool"
             }

      GenServer.stop(pid)
    end
  end

  test "abort abandons session contention and prevents a later start" do
    run_id = "submission-#{System.unique_integer([:positive, :monotonic])}"
    session_key = SessionKey.main(run_id)
    key = {:session, session_key}
    :ok = EngineSessionClaim.claim(key)
    pid = start_admission(run_id, session_key)
    assert {:submitting, %{submit_attempt: attempt}} = :sys.get_state(pid)
    assert attempt > 0
    assert {:state_timeout, :submission_deadline} in active_timeouts(pid)
    assert {{:timeout, :submission_retry}, :submit} in active_timeouts(pid)
    ref = Process.monitor(pid)
    RunProcess.abort(pid, :test_abort)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    :ok = EngineSessionClaim.release(key)
    refute_receive {:test_executor_started, ^run_id, _, _}, 400
  end

  describe "run watchdog state machine" do
    setup do
      dispatcher = RunProcessToolStatusIntentDispatcherStub
      previous_dispatcher = Application.fetch_env(:lemon_router, :dispatcher)
      key = {dispatcher, :test_pid}
      previous_pid = :persistent_term.get(key, :unset)
      Application.put_env(:lemon_router, :dispatcher, dispatcher)
      :persistent_term.put(key, self())

      on_exit(fn ->
        case previous_dispatcher do
          {:ok, value} -> Application.put_env(:lemon_router, :dispatcher, value)
          :error -> Application.delete_env(:lemon_router, :dispatcher)
        end

        if previous_pid == :unset,
          do: :persistent_term.erase(key),
          else: :persistent_term.put(key, previous_pid)
      end)

      :ok
    end

    test "idle expiry synthesizes exactly one completion and stops normally" do
      {pid, run_id, session_key} = watchdog_run(run_watchdog_timeout_ms: 1)
      monitor = Process.monitor(pid)
      start_watchdog(pid, run_id, session_key)

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{
                         completed: %{
                           error: :run_idle_watchdog_timeout,
                           meta: %{cancelled: true, cancel_reason: :run_idle_watchdog_timeout}
                         }
                       },
                       meta: %{run_id: ^run_id}
                     },
                     1_500

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
      refute_received %LemonCore.Event{type: :run_completed, meta: %{run_id: ^run_id}}
    end

    test "unrelated events and metadata calls retain the original watchdog deadline" do
      {pid, run_id, session_key} = watchdog_run(run_watchdog_timeout_ms: 60_000)
      trace_timeouts(pid)
      start_watchdog(pid, run_id, session_key)
      assert {:running, data} = :sys.get_state(pid)
      assert_receive {:timeout_started, ^pid, {:state_timeout, 60_000, :idle, []}, :running}
      refute Map.has_key?(data, :run_watchdog_ref)
      refute Map.has_key?(data, :run_watchdog_confirmation_ref)
      refute Map.has_key?(data, :run_watchdog_awaiting_confirmation?)

      for _ <- 1..10 do
        send(pid, :unrelated)
        send(pid, LemonCore.Event.new(:router_probe, %{}, %{run_id: run_id}))
        RunProcess.keep_alive(pid, :unrecognized)
        assert %{session_key: ^session_key} = GenServer.call(pid, :get_metadata)
      end

      # The call barrier observes all earlier events and their timeout actions.
      assert {:running, ^data} = :sys.get_state(pid)
      assert {:state_timeout, :idle} in active_timeouts(pid)
      refute_received {:timeout_started, ^pid, {:state_timeout, _, _, _}, _}
    end

    test "actual output explicitly renews the idle state timeout" do
      {pid, run_id, session_key} = watchdog_run(run_watchdog_timeout_ms: 60_000)
      trace_timeouts(pid)
      start_watchdog(pid, run_id, session_key)
      assert {:running, _} = :sys.get_state(pid)
      assert_receive {:timeout_started, ^pid, {:state_timeout, 60_000, :idle, []}, :running}

      TestExecutor.delta(runner_for(run_id), "still working")

      assert_receive {:timeout_started, ^pid, {:state_timeout, 60_000, :idle, []}, :running}
      assert {:running, %{saw_delta: true}} = :sys.get_state(pid)
    end

    test "zero disables idle expiry without disabling cancellation" do
      {pid, run_id, session_key} = watchdog_run(run_watchdog_timeout_ms: 0)
      monitor = Process.monitor(pid)
      start_watchdog(pid, run_id, session_key)
      assert {:running, _} = :sys.get_state(pid)
      refute Enum.any?(active_timeouts(pid), &match?({:state_timeout, _}, &1))
      RunProcess.abort(pid, :test_abort)

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{completed: %{error: :test_abort}},
                       meta: %{run_id: ^run_id}
                     },
                     1_500

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    end

    test "confirmation expiry uses its own state timeout" do
      {pid, run_id, session_key} =
        watchdog_run(
          telegram?: true,
          run_watchdog_timeout_ms: 1,
          run_watchdog_confirm_timeout_ms: 1
        )

      monitor = Process.monitor(pid)
      trace_timeouts(pid)
      start_watchdog(pid, run_id, session_key)

      assert_receive {:dispatched_intent,
                      %LemonCore.DeliveryIntent{kind: :watchdog_prompt, run_id: ^run_id}}

      assert_receive {:timeout_started, ^pid, {:state_timeout, 1, :confirmation, []},
                      :confirming_idle}

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{
                         completed: %{
                           error: :run_idle_watchdog_timeout,
                           meta: %{cancel_reason: :run_idle_watchdog_timeout}
                         }
                       },
                       meta: %{run_id: ^run_id}
                     },
                     1_500

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
    end

    test "continue replaces confirmation expiry and cancel cannot revive the run" do
      {pid, run_id, session_key} =
        watchdog_run(
          telegram?: true,
          run_watchdog_timeout_ms: 1,
          run_watchdog_confirm_timeout_ms: 60_000
        )

      monitor = Process.monitor(pid)
      trace_timeouts(pid)
      start_watchdog(pid, run_id, session_key)

      assert_receive {:dispatched_intent,
                      %LemonCore.DeliveryIntent{kind: :watchdog_prompt, run_id: ^run_id}}

      assert {:confirming_idle, _} = :sys.get_state(pid)
      assert_receive {:timeout_started, ^pid, {:state_timeout, 1, :idle, []}, :running}
      assert {:state_timeout, :confirmation} in active_timeouts(pid)

      # Queue all decisions first so expiry cannot race the cancellation.
      :ok = :sys.suspend(pid)
      RunProcess.keep_alive(run_id, :continue)
      RunProcess.keep_alive(run_id, :cancel)
      RunProcess.keep_alive(run_id, :continue)
      :ok = :sys.resume(pid)
      assert_receive {:timeout_started, ^pid, {:state_timeout, 1, :idle, []}, :running}

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{
                         completed: %{
                           error: :user_requested,
                           meta: %{cancelled: true, cancel_reason: :user_requested}
                         }
                       },
                       meta: %{run_id: ^run_id}
                     },
                     1_500

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}
      refute_received {:timeout_started, ^pid, {:state_timeout, _, :idle, _}, _}
      refute_received %LemonCore.Event{type: :run_completed, meta: %{run_id: ^run_id}}
    end

    test "abort leaves confirmation and cancels its timeout" do
      {pid, run_id, session_key} =
        watchdog_run(
          telegram?: true,
          run_watchdog_timeout_ms: 1,
          run_watchdog_confirm_timeout_ms: 60_000,
          hold_cancel?: true
        )

      start_watchdog(pid, run_id, session_key)

      assert_receive {:dispatched_intent,
                      %LemonCore.DeliveryIntent{kind: :watchdog_prompt, run_id: ^run_id}}

      RunProcess.abort(pid, :test_abort)
      assert {:aborting, _} = :sys.get_state(pid)
      refute {:state_timeout, :confirmation} in active_timeouts(pid)
      assert {:state_timeout, :cancel_drain} in active_timeouts(pid)
      TestExecutor.complete(runner_for(run_id))
    end
  end

  defp watchdog_run(opts) do
    run_id = "watchdog-#{System.unique_integer([:positive, :monotonic])}"

    session_key =
      if opts[:telegram?] do
        SessionKey.channel_peer(%{
          agent_id: run_id,
          channel_id: "telegram",
          account_id: "default",
          peer_kind: :group,
          peer_id: "12345"
        })
      else
        SessionKey.main(run_id)
      end

    LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session_key))

    options =
      opts
      |> Map.new()
      |> Map.merge(%{
        run_id: run_id,
        session_key: session_key,
        execution_request:
          make_test_request(run_id, %{test_executor_hold_cancel: opts[:hold_cancel?]})
      })

    :ok = EngineSessionClaim.claim({:session, session_key})
    pid = start_supervised!({RunProcess, options})
    {pid, run_id, session_key}
  end

  defp start_watchdog(_pid, run_id, session_key) do
    :ok = EngineSessionClaim.release({:session, session_key})
    runner_for(run_id)
  end

  defp trace_timeouts(pid) do
    debug = fn owner, event, _extra ->
      case event do
        {:start_timer, action, phase} -> send(owner, {:timeout_started, pid, action, phase})
        _ -> :ok
      end

      owner
    end

    :ok = :sys.install(pid, {debug, self()})
  end

  defp active_timeouts(pid) do
    {:status, ^pid, _, [_, _, _, _, status]} = :sys.get_status(pid)

    [{_count, timeouts}] =
      for {:data, fields} <- status, {~c"Time-outs", value} <- fields, do: value

    timeouts
  end

  describe "zero-answer assistant retries" do
    for explicit <- [false, true, nil], keys <- [:atom, :string] do
      @retry_explicit explicit
      @retry_keys keys
      test "retains #{@retry_keys} model provenance #{@retry_explicit} across retry" do
        run_id = "run_#{System.unique_integer([:positive])}"
        session_key = SessionKey.main("test-agent-#{run_id}")
        model_meta = %{model: "openai:gpt-4o", model_explicit: @retry_explicit}

        model_meta =
          if @retry_keys == :string,
            do: Map.new(model_meta, fn {key, value} -> {Atom.to_string(key), value} end),
            else: model_meta

        job = %{make_test_request(run_id, model_meta) | prompt: "Do work"}
        start_supervised!({__MODULE__.TestRunOrchestrator, [notify_pid: self()]})

        assert {:ok, pid} =
                 RunProcess.start_link(%{
                   run_id: run_id,
                   session_key: session_key,
                   execution_request: job,
                   run_orchestrator: __MODULE__.TestRunOrchestrator
                 })

        event =
          LemonCore.Event.new(
            :run_completed,
            %{completed: %{ok: false, error: {:assistant_error, "HTTP 400: "}, answer: ""}},
            %{run_id: run_id, session_key: session_key}
          )

        :ok = execute_event(run_id, event)
        assert_receive {:test_run_orchestrator_submit, %RunRequest{} = retry, 1}, 1_000
        assert retry.model == "openai:gpt-4o"
        assert retry.model_explicit == @retry_explicit

        assert %{model_explicit: explicit} =
                 LemonRouter.ModelSelection.resolve(%{
                   explicit_model: retry.model,
                   model_explicit: retry.model_explicit
                 })

        assert explicit == (@retry_explicit != false)
        assert eventually(fn -> not Process.alive?(pid) end)
      end
    end

    test "auto-retries once with retry context in prompt" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent-#{run_id}")

      job =
        %{
          make_test_request(run_id, %{origin: :channel})
          | prompt: "Collect the latest status report"
        }

      {:ok, _} =
        start_supervised({__MODULE__.TestRunOrchestrator, [notify_pid: self()]})

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 execution_request: job,
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

      :ok = execute_event(run_id, completed_event)

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
      session_key = SessionKey.main("test-agent-#{run_id}")
      job = %{make_test_request(run_id, %{origin: :channel}) | prompt: "Do work"}

      {:ok, _} =
        start_supervised({__MODULE__.TestRunOrchestrator, [notify_pid: self()]})

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job,
             run_orchestrator: __MODULE__.TestRunOrchestrator
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, completed_event)

      refute_receive {:test_run_orchestrator_submit, %RunRequest{}, _}, 300
      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "does not auto-retry when retry limit is already reached" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent-#{run_id}")

      job =
        %{
          make_test_request(run_id, %{origin: :channel, zero_answer_retry_attempt: 1})
          | prompt: "Do work"
        }

      {:ok, _} =
        start_supervised({__MODULE__.TestRunOrchestrator, [notify_pid: self()]})

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job,
             run_orchestrator: __MODULE__.TestRunOrchestrator
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, completed_event)

      refute_receive {:test_run_orchestrator_submit, %RunRequest{}, _}, 300
      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "does not auto-retry when assistant error is context overflow" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent-#{run_id}")
      job = %{make_test_request(run_id, %{origin: :channel}) | prompt: "Do work"}

      {:ok, _} =
        start_supervised({__MODULE__.TestRunOrchestrator, [notify_pid: self()]})

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job,
             run_orchestrator: __MODULE__.TestRunOrchestrator
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, completed_event)

      refute_receive {:test_run_orchestrator_submit, %RunRequest{}, _}, 300
      assert eventually(fn -> not Process.alive?(pid) end)
    end
  end

  describe "context overflow recovery" do
    test "context_length_exceeded clears generic chat-state resume for non-telegram sessions" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent-#{run_id}")

      _ =
        ChatStateStore.put(session_key, %{
          last_engine: "codex",
          last_resume_token: "thread_old",
          updated_at: System.system_time(:millisecond)
        })

      job = make_test_request(run_id, %{origin: :channel})

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)
      assert eventually(fn -> ChatStateStore.get(session_key) == nil end)
    end
  end

  describe "task tool status routing" do
    test "task child actions stay attached to the parent task surface after later assistant text" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        RateLimiter.start_link([])
      end)

      start_if_needed(Dedupe, fn ->
        Dedupe.start_link([])
      end)

      start_if_needed(LemonChannels.PresentationState, fn ->
        LemonChannels.PresentationState.start_link([])
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

      job =
        make_test_request(run_id, %{
          progress_msg_id: 111,
          user_msg_id: 222
        })

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

      prefix = "Found the key files. Let me read the markdown renderer and the formatter:"
      task_surface = {:status_task, "task_1"}

      delta_event_1 =
        LemonCore.Event.new(
          :delta,
          %{seq: 1, text: prefix},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = execute_event(run_id, delta_event_1)

      flush_answer_delta(pid, session_key, run_id, 1)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: :text,
                        content: ^prefix,
                        meta: %{run_id: ^run_id}
                      }},
                     1_500

      task_start_event =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_1",
              kind: "subagent",
              title: "task(claude): inspect repo",
              detail: %{name: "task"}
            },
            phase: :started
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = execute_event(run_id, task_start_event)

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] -> "task_1" in :sys.get_state(status_pid).order
                 _ -> false
               end
             end)

      LemonRouter.ToolStatusCoalescer.flush(session_key, "telegram", surface: task_surface)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: :edit,
                        content: %{text: task_text},
                        meta: %{run_id: ^run_id}
                      }},
                     1_500

      assert String.contains?(task_text, prefix)
      assert String.contains?(task_text, "task(claude): inspect repo")

      separate = "Separate answer chunk"

      delta_event_2 =
        LemonCore.Event.new(
          :delta,
          %{seq: 2, text: separate},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = execute_event(run_id, delta_event_2)

      flush_answer_delta(pid, session_key, run_id, 2)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: :text,
                        content: ^separate,
                        meta: %{run_id: ^run_id}
                      }},
                     1_500

      task_child_event =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "claude",
            action: %{
              id: "task_child_1",
              kind: "command",
              title: "pwd",
              detail: %{parent_tool_use_id: "task_1"}
            },
            phase: :started
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = execute_event(run_id, task_child_event)

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] -> "task_child_1" in :sys.get_state(status_pid).order
                 _ -> false
               end
             end)

      LemonRouter.ToolStatusCoalescer.flush(session_key, "telegram", surface: task_surface)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: :edit,
                        content: %{text: task_child_text},
                        meta: %{run_id: ^run_id}
                      }},
                     1_500

      assert String.contains?(task_child_text, prefix)
      assert String.contains?(task_child_text, "task(claude): inspect repo")
      assert String.contains?(task_child_text, "pwd")
      refute String.contains?(task_child_text, separate)

      GenServer.stop(pid)
    end

    test "async task poll actions stay attached to the original task surface by task_id" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        RateLimiter.start_link([])
      end)

      start_if_needed(Dedupe, fn ->
        Dedupe.start_link([])
      end)

      start_if_needed(LemonChannels.PresentationState, fn ->
        LemonChannels.PresentationState.start_link([])
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

      # Reproduce a preceding test/run leaving the same sequence number on this
      # session's long-lived coalescer. It must not satisfy this run's barrier.
      previous_run_id = "#{run_id}:previous"
      previous_answer = "Previous run answer"

      :ok =
        LemonRouter.StreamCoalescer.ingest_delta(
          session_key,
          "telegram",
          previous_run_id,
          1,
          previous_answer
        )

      [{coalescer_pid, _}] =
        Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, "telegram"})

      assert %{run_id: ^previous_run_id, last_seq: 1} = :sys.get_state(coalescer_pid)

      :ok =
        LemonRouter.StreamCoalescer.finalize_run(session_key, "telegram", previous_run_id,
          final_text: previous_answer
        )

      job =
        make_test_request(run_id, %{
          progress_msg_id: 111,
          user_msg_id: 222
        })

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

      prefix = "Running external reviews"
      task_surface = {:status_task, "task_root"}

      :ok =
        execute_event(
          run_id,
          LemonCore.Event.new(:delta, %{seq: 1, text: prefix}, %{
            run_id: run_id,
            session_key: session_key
          })
        )

      flush_answer_delta(pid, session_key, run_id, 1)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: :text,
                        content: ^prefix,
                        meta: %{run_id: ^run_id}
                      }},
                     1_500

      task_started =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_root",
              kind: "subagent",
              title: "task(codex): review fix",
              detail: %{name: "task"}
            },
            phase: :started
          },
          %{run_id: run_id, session_key: session_key}
        )

      task_completed =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_root",
              kind: "subagent",
              title: "task(codex): review fix",
              detail: %{
                name: "task",
                result: "Task queued: review fix (task-store-1)",
                result_meta: %{task_id: "task-store-1", status: "queued", run_id: "child_run_1"}
              }
            },
            phase: :completed,
            ok: true
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = execute_event(run_id, task_started)
      :ok = execute_event(run_id, task_completed)

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] -> "task_root" in :sys.get_state(status_pid).order
                 _ -> false
               end
             end)

      followup_text = "Waiting on the review"

      TestExecutor.delta(runner_for(run_id), followup_text)

      flush_answer_delta(pid, session_key, run_id, 2)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: :text,
                        content: ^followup_text,
                        meta: %{run_id: ^run_id}
                      }},
                     1_500

      poll_completed =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_poll_1",
              kind: "subagent",
              title: "task: ",
              detail: %{
                name: "task",
                args: %{"action" => "poll", "task_id" => "task-store-1"},
                result: "Read: AGENTS.md",
                result_meta: %{
                  task_id: "task-store-1",
                  engine: "codex",
                  current_action: %{title: "Read: AGENTS.md", kind: "tool", phase: "completed"}
                }
              }
            },
            phase: :completed,
            ok: true
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = execute_event(run_id, poll_completed)

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] ->
                   state = :sys.get_state(status_pid)

                   Enum.any?(Map.values(state.actions), fn action ->
                     action[:detail][:parent_tool_use_id] == "task_root" and
                       action[:title] == "Read: AGENTS.md"
                   end)

                 _ ->
                   false
               end
             end)

      refute eventually(
               fn ->
                 Registry.lookup(
                   LemonRouter.ToolStatusRegistry,
                   {session_key, "telegram", :status}
                 ) !=
                   []
               end,
               500
             )

      LemonRouter.ToolStatusCoalescer.flush(session_key, "telegram", surface: task_surface)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: :edit,
                        content: %{text: task_text},
                        meta: %{run_id: ^run_id}
                      }},
                     1_500

      assert String.contains?(task_text, prefix)
      assert String.contains?(task_text, "task(codex): review fix")
      assert String.contains?(task_text, "Read: AGENTS.md")
      refute String.contains?(task_text, followup_text)
      refute String.contains?(task_text, "\ntask: ")

      GenServer.stop(pid)
    end
  end

  describe "final answer fanout delivery" do
    test "completion with tool actions but no streamed deltas flushes status before final answer" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        RateLimiter.start_link([])
      end)

      start_if_needed(Dedupe, fn ->
        Dedupe.start_link([])
      end)

      start_if_needed(LemonChannels.PresentationState, fn ->
        LemonChannels.PresentationState.start_link([])
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

      job =
        make_test_request(run_id, %{
          progress_msg_id: 111,
          user_msg_id: 222
        })

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

      :ok =
        execute_event(
          run_id,
          LemonCore.Event.new(
            :engine_action,
            %{
              engine: "lemon",
              action: %{
                id: "tool_1",
                kind: "tool",
                title: "Read: foo.txt",
                detail: %{}
              },
              phase: :started
            },
            %{run_id: run_id, session_key: session_key}
          )
        )

      :ok =
        execute_event(
          run_id,
          LemonCore.Event.new(
            :run_completed,
            %{completed: %{ok: true, answer: "Final answer"}},
            %{run_id: run_id, session_key: session_key}
          )
        )

      payloads = receive_run_payloads_until_idle(run_id, 1_500)
      texts = Enum.map(payloads, &payload_text/1)

      assert Enum.any?(texts, &String.contains?(&1, "Read: foo.txt"))
      assert Enum.any?(texts, &String.contains?(&1, "Final answer"))

      first_status_text =
        Enum.find_value(texts, fn text ->
          if String.contains?(text, "Read: foo.txt"), do: text
        end)

      refute String.contains?(first_status_text, "Final answer")
      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "delivers final answer once per unique fanout route" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        RateLimiter.start_link([])
      end)

      start_if_needed(Dedupe, fn ->
        Dedupe.start_link([])
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
      session_key = SessionKey.main("test-agent-#{run_id}")

      fanout_routes = [
        %{channel_id: "telegram", account_id: "default", peer_kind: :dm, peer_id: "111"},
        %{channel_id: "telegram", account_id: "default", peer_kind: :dm, peer_id: "111"},
        %{channel_id: "telegram", account_id: "default", peer_kind: :dm, peer_id: "222"}
      ]

      job = make_test_request(run_id, %{fanout_routes: fanout_routes})

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        meta: %{run_id: ^run_id, intent_meta: intent_meta_a}
                      } = payload_a},
                     3_000

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        meta: %{run_id: ^run_id, intent_meta: intent_meta_b}
                      } = payload_b},
                     3_000

      refute_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        meta: %{run_id: ^run_id, intent_meta: %{fanout: true}}
                      }},
                     500

      assert intent_meta_a[:fanout] == true
      assert intent_meta_b[:fanout] == true
      assert intent_meta_a[:fanout_index] in [1, 2]
      assert intent_meta_b[:fanout_index] in [1, 2]
      assert intent_meta_a[:fanout_index] != intent_meta_b[:fanout_index]

      assert payload_a.content == "Fanout answer"
      assert payload_b.content == "Fanout answer"

      peer_ids =
        [payload_a.peer.id, payload_b.peer.id]
        |> Enum.sort()

      assert peer_ids == ["111", "222"]
    end
  end

  describe "completion ordering without streamed deltas" do
    test "flushes tool status output before the final answer" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        RateLimiter.start_link([])
      end)

      start_if_needed(Dedupe, fn ->
        Dedupe.start_link([])
      end)

      start_if_needed(LemonChannels.PresentationState, fn ->
        LemonChannels.PresentationState.start_link([])
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

      job =
        make_test_request(
          run_id,
          %{progress_msg_id: 111, user_msg_id: 222},
          %{session_key: session_key, conversation_key: {:session, session_key}}
        )

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

      action_event =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "tool_1",
              kind: "tool",
              title: "Read: AGENTS.md",
              detail: %{}
            },
            phase: :started
          },
          %{run_id: run_id, session_key: session_key}
        )

      completed_event =
        LemonCore.Event.new(
          :run_completed,
          %{completed: %{ok: true, answer: "Final answer without streamed deltas"}},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = execute_event(run_id, action_event)
      :ok = execute_event(run_id, completed_event)

      payloads = receive_run_payloads_until_idle(run_id, 3_000)
      intent_kinds = Enum.map(payloads, & &1.meta[:intent_kind])
      texts = Enum.map(payloads, &payload_text/1)

      assert Enum.any?(intent_kinds, &(&1 in [:tool_status_snapshot, :tool_status_finalize]))
      assert Enum.any?(intent_kinds, &(&1 in [:stream_finalize, :final_text]))
      assert Enum.any?(texts, &String.contains?(&1, "Final answer without streamed deltas"))
      assert eventually(fn -> not Process.alive?(pid) end)
    end
  end

  describe "completion ordering with streamed deltas" do
    test "still finalizes the answer when artifact metadata enrichment raises" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        RateLimiter.start_link([])
      end)

      start_if_needed(Dedupe, fn ->
        Dedupe.start_link([])
      end)

      start_if_needed(LemonChannels.PresentationState, fn ->
        LemonChannels.PresentationState.start_link([])
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

      job =
        make_test_request(
          run_id,
          %{progress_msg_id: 111, user_msg_id: 222},
          %{session_key: session_key, conversation_key: {:session, session_key}}
        )

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job,
             artifact_tracker: RaisingArtifactTracker
           }},
          id: run_id
        )

      delta_event =
        LemonCore.Event.new(
          :delta,
          %{seq: 1, text: "snapshot body"},
          %{run_id: run_id, session_key: session_key}
        )

      completed_event =
        LemonCore.Event.new(
          :run_completed,
          %{completed: %{ok: true, answer: "Final answer after artifact tracker failure"}},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = execute_event(run_id, delta_event)
      :ok = execute_event(run_id, completed_event)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        meta: %{intent_kind: :stream_finalize, run_id: ^run_id},
                        content: final_content
                      }},
                     3_000

      final_text =
        case final_content do
          %{text: text} -> text
          text when is_binary(text) -> text
        end

      assert String.contains?(final_text, "Final answer after artifact tracker failure")
      assert eventually(fn -> not Process.alive?(pid) end)
    end
  end

  describe "telegram final message resume indexing" do
    test "indexes the bot final message id so replies can resume the right engine/session" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        RateLimiter.start_link([])
      end)

      start_if_needed(Dedupe, fn ->
        Dedupe.start_link([])
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

      _ = ResumeIndexStore.delete_thread("botx", 12_345, nil, generation: 0)

      job =
        make_test_request(run_id, %{
          progress_msg_id: 111,
          user_msg_id: 222
        })

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, completed_event)

      # RunProcess stops after completion; give it a moment to tear down.
      assert eventually(fn -> not Process.alive?(pid) end)

      assert eventually(fn ->
               case ResumeIndexStore.get_resume("botx", 12_345, nil, 101, generation: 0) do
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
      stale_resume = %ResumeToken{engine: "codex", value: "thread_old"}

      _ = PendingCompactionStore.delete(session_key)

      _ =
        ChatStateStore.put(session_key, %{
          last_engine: "codex",
          last_resume_token: "thread_old",
          updated_at: System.system_time(:millisecond)
        })

      _ = StateStore.put_selected_resume(selected_key, stale_resume)

      _ =
        ResumeIndexStore.put_session("botx", 12_345, 777, 9_001, session_key <> ":sub:old",
          generation: 0
        )

      _ = ResumeIndexStore.put_resume("botx", 12_345, 777, 9_001, stale_resume, generation: 0)

      job = make_test_request(run_id, %{progress_msg_id: 111, user_msg_id: 222})

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)
      assert eventually(fn -> ChatStateStore.get(session_key) == nil end)
      assert StateStore.get_selected_resume(selected_key) == nil
      assert ResumeIndexStore.get_session("botx", 12_345, 777, 9_001, generation: 0) == nil
      assert ResumeIndexStore.get_resume("botx", 12_345, 777, 9_001, generation: 0) == nil

      assert eventually(fn ->
               case PendingCompactionStore.get(session_key) do
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
      stale_resume = %ResumeToken{engine: "codex", value: "thread_old"}

      _ = PendingCompactionStore.delete(session_key)

      _ =
        ChatStateStore.put(session_key, %{
          last_engine: "codex",
          last_resume_token: "thread_old",
          updated_at: System.system_time(:millisecond)
        })

      _ = StateStore.put_selected_resume(selected_key, stale_resume)

      _ =
        ResumeIndexStore.put_session("botx", 12_345, 777, 9_002, session_key <> ":sub:old",
          generation: 0
        )

      _ = ResumeIndexStore.put_resume("botx", 12_345, 777, 9_002, stale_resume, generation: 0)

      job = make_test_request(run_id, %{progress_msg_id: 111, user_msg_id: 222})

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)
      assert eventually(fn -> ChatStateStore.get(session_key) == nil end)
      assert StateStore.get_selected_resume(selected_key) == nil
      assert ResumeIndexStore.get_session("botx", 12_345, 777, 9_002, generation: 0) == nil
      assert ResumeIndexStore.get_resume("botx", 12_345, 777, 9_002, generation: 0) == nil

      assert eventually(fn ->
               case PendingCompactionStore.get(session_key) do
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

      old_compaction_env = Application.get_env(:lemon_router, :compaction)

      Application.put_env(:lemon_router, :compaction, %{
        enabled: true,
        context_window_tokens: 1_000,
        reserve_tokens: 100,
        trigger_ratio: 0.95
      })

      on_exit(fn ->
        if is_nil(old_compaction_env) do
          Application.delete_env(:lemon_router, :compaction)
        else
          Application.put_env(:lemon_router, :compaction, old_compaction_env)
        end
      end)

      _ = PendingCompactionStore.delete(session_key)

      job = make_test_request(run_id, %{progress_msg_id: 111, user_msg_id: 222})

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)

      assert eventually(fn ->
               case PendingCompactionStore.get(session_key) do
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

      old_compaction_env = Application.get_env(:lemon_router, :compaction)

      Application.put_env(:lemon_router, :compaction, %{
        enabled: true,
        context_window_tokens: 1_000,
        reserve_tokens: 100,
        trigger_ratio: 0.95
      })

      on_exit(fn ->
        if is_nil(old_compaction_env) do
          Application.delete_env(:lemon_router, :compaction)
        else
          Application.put_env(:lemon_router, :compaction, old_compaction_env)
        end
      end)

      _ = PendingCompactionStore.delete(session_key)

      job = make_test_request(run_id, %{progress_msg_id: 111, user_msg_id: 222})

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)

      assert eventually(fn ->
               case PendingCompactionStore.get(session_key) do
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

      old_compaction_env = Application.get_env(:lemon_router, :compaction)

      Application.put_env(:lemon_router, :compaction, %{
        enabled: true,
        context_window_tokens: 1_000,
        reserve_tokens: 100,
        trigger_ratio: 0.95
      })

      on_exit(fn ->
        if is_nil(old_compaction_env) do
          Application.delete_env(:lemon_router, :compaction)
        else
          Application.put_env(:lemon_router, :compaction, old_compaction_env)
        end
      end)

      _ = PendingCompactionStore.delete(session_key)

      job = make_test_request(run_id, %{progress_msg_id: 111, user_msg_id: 222})

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)

      assert eventually(fn ->
               case PendingCompactionStore.get(session_key) do
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

      old_compaction_env = Application.get_env(:lemon_router, :compaction)

      # context_window=100, reserve=10, trigger_ratio=0.9 → threshold=min(90,90)=90
      # A prompt with 400 chars → 400/4 = 100 estimated tokens → 100 >= 90 → should mark
      Application.put_env(:lemon_router, :compaction, %{
        enabled: true,
        context_window_tokens: 100,
        reserve_tokens: 10,
        trigger_ratio: 0.9
      })

      on_exit(fn ->
        if is_nil(old_compaction_env) do
          Application.delete_env(:lemon_router, :compaction)
        else
          Application.put_env(:lemon_router, :compaction, old_compaction_env)
        end
      end)

      _ = PendingCompactionStore.delete(session_key)

      # Create a job with a long prompt (400 chars → ~100 estimated tokens)
      long_prompt = String.duplicate("a", 400)

      job =
        make_test_request(run_id, %{progress_msg_id: 111, user_msg_id: 222}, %{
          prompt: long_prompt
        })

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)

      # Should have set the generic pending_compaction marker via char estimate
      assert eventually(fn ->
               case PendingCompactionStore.get(session_key) do
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
      _ = PendingCompactionStore.delete(session_key)
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

      _ = PendingCompactionStore.delete(session_key)

      job =
        make_test_request(run_id, %{progress_msg_id: 111, user_msg_id: 222}, %{
          prompt: "short prompt"
        })

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)

      # Short prompt → below threshold → no marker
      Process.sleep(100)
      assert PendingCompactionStore.get(session_key) == nil
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

      _ = PendingCompactionStore.delete(session_key)

      job =
        make_test_request(run_id, %{progress_msg_id: 111, user_msg_id: 222}, %{
          prompt: String.duplicate("a", 400)
        })

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)
      Process.sleep(100)
      assert PendingCompactionStore.get(session_key) == nil
    end
  end

  describe "estimate_input_tokens_from_prompt/1" do
    test "returns char-based estimate for valid prompt" do
      state = %{
        execution_request: %LemonCore.ExecutionCommand{
          run_id: "run-estimate",
          session_key: "session-estimate",
          prompt: String.duplicate("a", 400)
        }
      }

      assert RunProcess.estimate_input_tokens_from_prompt(state) == 100
    end

    test "returns nil when prompt is nil" do
      state = %{
        execution_request: %LemonCore.ExecutionCommand{
          run_id: "run-estimate-nil",
          session_key: "session-estimate-nil",
          prompt: nil
        }
      }

      assert RunProcess.estimate_input_tokens_from_prompt(state) == nil
    end

    test "returns nil when execution_request is missing" do
      state = %{execution_request: nil}
      assert RunProcess.estimate_input_tokens_from_prompt(state) == nil
    end
  end

  describe "generated image tracking" do
    test "tracks image file_change paths from completed engine actions" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent-#{run_id}")
      job = make_test_request(run_id)

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, action_event)

      assert eventually(fn ->
               {_phase, state} = :sys.get_state(pid)
               state.generated_image_paths == ["artifacts/chart.png"]
             end)

      GenServer.stop(pid)
    end

    test "tracks explicit auto_send_files from tool result metadata" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent-#{run_id}")
      job = %{make_test_request(run_id) | cwd: "/tmp/project"}

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

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

      :ok = execute_event(run_id, action_event)

      assert eventually(fn ->
               {_phase, state} = :sys.get_state(pid)

               state.requested_send_files == [
                 %{path: "workspace/image.png", filename: "image.png", caption: "Generated"}
               ]
             end)

      GenServer.stop(pid)
    end

    test "delivers auto_send_files on the final answer channel path" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        RateLimiter.start_link([])
      end)

      start_if_needed(Dedupe, fn ->
        Dedupe.start_link([])
      end)

      start_if_needed(LemonChannels.PresentationState, fn ->
        LemonChannels.PresentationState.start_link([])
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

      cwd =
        Path.join(System.tmp_dir!(), "run-process-files-#{System.unique_integer([:positive])}")

      file_path = Path.join(cwd, "workspace/image.png")
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "png-bytes")
      on_exit(fn -> File.rm_rf(cwd) end)

      job =
        make_test_request(
          run_id,
          %{progress_msg_id: 111, user_msg_id: 222},
          %{cwd: cwd, session_key: session_key, conversation_key: {:session, session_key}}
        )

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

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
                    %{path: "workspace/image.png", filename: "renamed.png", caption: "Generated"}
                  ]
                }
              }
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      completed_event =
        LemonCore.Event.new(
          :run_completed,
          %{completed: %{ok: true, answer: "Final answer with file"}},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = execute_event(run_id, action_event)

      assert eventually(fn ->
               {_phase, state} = :sys.get_state(pid)

               state.requested_send_files == [
                 %{path: "workspace/image.png", filename: "renamed.png", caption: "Generated"}
               ]
             end)

      :ok = execute_event(run_id, completed_event)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: text_kind,
                        content: text_content,
                        meta: %{run_id: ^run_id, intent_kind: kind}
                      }}
                     when kind in [:stream_finalize, :final_text],
                     3_000

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: :file,
                        content: %{
                          path: delivered_path,
                          filename: "renamed.png",
                          caption: "Generated"
                        },
                        meta: %{run_id: ^run_id}
                      }},
                     3_000

      assert text_kind in [:text, :edit]

      delivered_text =
        case text_content do
          %{text: text} -> text
          text when is_binary(text) -> text
        end

      assert String.contains?(delivered_text, "Final answer with file")
      assert File.regular?(delivered_path)
      assert String.ends_with?(delivered_path, "/workspace/image.png")
      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "delivers final-answer MEDIA directives through the file channel path" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        RateLimiter.start_link([])
      end)

      start_if_needed(Dedupe, fn ->
        Dedupe.start_link([])
      end)

      start_if_needed(LemonChannels.PresentationState, fn ->
        LemonChannels.PresentationState.start_link([])
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

      cwd =
        Path.join(
          System.tmp_dir!(),
          "run-process-media-directive-#{System.unique_integer([:positive])}"
        )

      file_path = Path.join(cwd, "workspace/image.png")
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "png-bytes")
      on_exit(fn -> File.rm_rf(cwd) end)

      job =
        make_test_request(
          run_id,
          %{progress_msg_id: 111, user_msg_id: 222},
          %{cwd: cwd, session_key: session_key, conversation_key: {:session, session_key}}
        )

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

      completed_event =
        LemonCore.Event.new(
          :run_completed,
          %{completed: %{ok: true, answer: "Final answer\nMEDIA: workspace/image.png"}},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = execute_event(run_id, completed_event)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: text_kind,
                        content: text_content,
                        meta: %{run_id: ^run_id}
                      }},
                     3_000

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: :file,
                        content: %{
                          path: delivered_path,
                          filename: "image.png",
                          caption: nil
                        },
                        meta: %{run_id: ^run_id}
                      }},
                     3_000

      assert text_kind in [:text, :edit]

      delivered_text =
        case text_content do
          %{text: text} -> text
          text when is_binary(text) -> text
        end

      assert String.contains?(delivered_text, "Final answer")
      refute String.contains?(delivered_text, "MEDIA:")
      assert File.regular?(delivered_path)
      assert String.ends_with?(delivered_path, "/workspace/image.png")
      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "records generated auto-send files into media job metadata on finalization" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent-#{run_id}")

      cwd =
        Path.join(
          System.tmp_dir!(),
          "run-process-media-jobs-#{System.unique_integer([:positive])}"
        )

      file_path = Path.join(cwd, "artifacts/chart.png")
      File.mkdir_p!(Path.dirname(file_path))
      File.write!(file_path, "png-bytes")
      on_exit(fn -> File.rm_rf(cwd) end)

      job =
        make_test_request(run_id, %{}, %{
          cwd: cwd,
          session_key: session_key,
          conversation_key: {:session, session_key}
        })

      pid =
        start_supervised!(
          {RunProcess,
           %{
             run_id: run_id,
             session_key: session_key,
             execution_request: job
           }},
          id: run_id
        )

      action_event =
        LemonCore.Event.new(
          :engine_action,
          %{
            phase: :completed,
            ok: true,
            action: %{
              kind: "file_change",
              detail: %{changes: [%{path: "artifacts/chart.png", kind: "added"}]}
            }
          },
          %{run_id: run_id, session_key: session_key}
        )

      completed_event =
        LemonCore.Event.new(
          :run_completed,
          %{completed: %{ok: true, answer: "Final answer with generated file"}},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = execute_event(run_id, action_event)
      :ok = execute_event(run_id, completed_event)

      assert eventually(fn -> length(LemonMedia.MediaJobs.recent(project_dir: cwd)) == 1 end)

      [job] = LemonMedia.MediaJobs.recent(project_dir: cwd)
      assert job.type == :image
      assert job.status == :completed
      assert job.artifact.name == "chart.png"
      assert job.artifact.bytes == 9
      refute inspect(job) =~ file_path
      refute inspect(job) =~ session_key
      assert eventually(fn -> not Process.alive?(pid) end)
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

  defp receive_run_payloads_until_idle(run_id, timeout_ms) do
    receive_run_payloads_until_idle(run_id, timeout_ms, [])
  end

  defp receive_run_payloads_until_idle(run_id, timeout_ms, acc) do
    receive do
      {:delivered, %LemonChannels.OutboundPayload{meta: %{run_id: ^run_id}} = payload} ->
        receive_run_payloads_until_idle(run_id, timeout_ms, [payload | acc])
    after
      timeout_ms ->
        Enum.reverse(acc)
    end
  end

  defp payload_text(%LemonChannels.OutboundPayload{content: %{text: text}}) when is_binary(text),
    do: text

  defp payload_text(%LemonChannels.OutboundPayload{content: text}) when is_binary(text), do: text
end
