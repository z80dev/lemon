defmodule LemonRouter.RunProcessTest do
  alias Elixir.LemonRouter, as: LemonRouter

  @moduledoc """
  Tests for Elixir.LemonRouter.RunProcess.

  Note: These are lightweight tests for the public API.
  Full integration testing with gateway should be done separately.
  """
  use ExUnit.Case, async: false

  alias LemonChannels.Telegram.{ResumeIndexStore, StateStore}
  alias LemonCore.{ChatStateStore, RunRequest, SessionKey}
  alias LemonCore.ResumeToken
  alias Elixir.LemonRouter.RunProcess
  alias LemonRouter.AsyncTaskSurface
  alias LemonRouter.PendingCompactionStore

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

    def submit_execution(%LemonGateway.ExecutionRequest{} = request) do
      GenServer.cast(__MODULE__, {:submit, request})
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_cast({:submit, request}, state) do
      if is_pid(state.notify_pid), do: send(state.notify_pid, {:test_scheduler_submit, request})
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

  defmodule WatchdogRuntimeStub do
    @moduledoc false

    def cancel_by_run_id(run_id, reason) do
      case :persistent_term.get({__MODULE__, :notify_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:watchdog_runtime_cancel, run_id, reason})
        _ -> :ok
      end

      :ok
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

    start_if_needed(LemonRouter.AsyncTaskSurfaceRegistry, fn ->
      Registry.start_link(keys: :unique, name: LemonRouter.AsyncTaskSurfaceRegistry)
    end)

    start_if_needed(LemonRouter.AsyncTaskSurfaceSupervisor, fn ->
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        name: LemonRouter.AsyncTaskSurfaceSupervisor
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

    test "does not own SessionRegistry entries directly" do
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

      refute eventually(fn ->
               Registry.lookup(Elixir.LemonRouter.SessionRegistry, session_key) != []
             end)

      GenServer.stop(pid)
    end

    test "single-flight registration is no longer retried in RunProcess" do
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

      assert [] == Registry.lookup(Elixir.LemonRouter.SessionRegistry, session_key)

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
      assert [] == Registry.lookup(Elixir.LemonRouter.SessionRegistry, session_key)

      GenServer.stop(pid1)
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

  defp payload_text(%{text: text}) when is_binary(text), do: text
  defp payload_text(text) when is_binary(text), do: text

  describe "abort/2" do
    test "abort by non-existent run_id returns :ok" do
      # Abort on non-existent run should be safe
      assert :ok = RunProcess.abort("non-existent-run", :test_abort)
    end

    test "aborted run without a gateway pid synthesizes completion and exits" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")
      job = make_test_job(run_id)

      LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session_key))

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false
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

    test "abort fallback stays single-shot when other completion fallbacks are also queued" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")
      job = make_test_job(run_id)

      LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session_key))

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false
               })

      :ok =
        LemonCore.Bus.broadcast(
          LemonCore.Bus.run_topic(run_id),
          LemonCore.Event.new(
            :run_started,
            %{run_id: run_id},
            %{run_id: run_id, session_key: session_key}
          )
        )

      assert :ok = RunProcess.abort(pid, :test_abort)

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{completed: %{ok: false, error: :test_abort}},
                       meta: %{run_id: ^run_id, session_key: ^session_key, synthetic: true}
                     },
                     1_500

      refute_receive %LemonCore.Event{type: :run_completed}, 2_000
      assert eventually(fn -> not Process.alive?(pid) end)
    end
  end

  describe "run_started without gateway binding" do
    test "late run_completed beats synthetic missing-gateway failure" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")
      job = make_test_job(run_id)

      LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session_key))

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false
               })

      :ok =
        LemonCore.Bus.broadcast(
          LemonCore.Bus.run_topic(run_id),
          LemonCore.Event.new(
            :run_started,
            %{run_id: run_id},
            %{run_id: run_id, session_key: session_key}
          )
        )

      Process.sleep(300)

      :ok =
        LemonCore.Bus.broadcast(
          LemonCore.Bus.run_topic(run_id),
          LemonCore.Event.new(
            :run_completed,
            %{
              completed: %{ok: true, answer: "done"},
              duration_ms: 123
            },
            %{run_id: run_id, session_key: session_key}
          )
        )

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{completed: %{ok: true, answer: "done"}},
                       meta: %{run_id: ^run_id, session_key: ^session_key}
                     },
                     1_500

      refute_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{completed: %{error: :gateway_run_missing_after_start}}
                     },
                     1_700

      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "started run without a gateway pid synthesizes completion and exits" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")
      job = make_test_job(run_id)

      LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session_key))

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false
               })

      :ok =
        LemonCore.Bus.broadcast(
          LemonCore.Bus.run_topic(run_id),
          LemonCore.Event.new(
            :run_started,
            %{run_id: run_id},
            %{run_id: run_id, session_key: session_key}
          )
        )

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{
                         completed: %{ok: false, error: :gateway_run_missing_after_start}
                       },
                       meta: %{run_id: ^run_id, session_key: ^session_key, synthetic: true}
                     },
                     2_500

      assert eventually(fn -> not Process.alive?(pid) end)
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

      assert_receive {:test_scheduler_submit, %LemonGateway.ExecutionRequest{run_id: ^run_id}},
                     1_500

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
               if Process.alive?(pid) do
                 state = :sys.get_state(pid)
                 state.aborted == true
               else
                 true
               end
             end)

      {:ok, _scheduler_pid} = start_supervised({TestScheduler, [notify_pid: self()]})

      refute_receive {:test_scheduler_submit, %LemonGateway.ExecutionRequest{run_id: ^run_id}},
                     400

      if Process.alive?(pid), do: GenServer.stop(pid)
    end

    test "projected child task actions attach to the existing task surface" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
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

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), task_started)

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

      refute eventually(fn ->
               Registry.lookup(LemonRouter.ToolStatusRegistry, {session_key, "telegram", :status}) !=
                 []
             end)

      GenServer.stop(pid)
    end

    test "projected child actions honor explicit surface metadata without prior parent reconstruction" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
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

      task_surface = {:status_task, "task_root_meta"}

      projected_child =
        LemonCore.Event.new(
          :task_projected_child_action,
          %{
            engine: "codex",
            action: %{
              id: "taskproj:child_run_meta:read_1",
              kind: "tool",
              title: "Read: AGENTS.md",
              detail: %{
                child_run_id: "child_run_meta",
                task_id: "task-store-meta"
              }
            },
            phase: :completed,
            ok: true,
            message: nil,
            level: nil
          },
          %{
            run_id: run_id,
            session_key: session_key,
            surface: task_surface,
            root_action_id: "task_root_meta"
          }
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), projected_child)

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] ->
                   state = :sys.get_state(status_pid)

                   case Map.get(state.actions, "taskproj:child_run_meta:read_1") do
                     %{detail: %{parent_tool_use_id: "task_root_meta", surface: ^task_surface}} ->
                       true

                     _ ->
                       false
                   end

                 _ ->
                   false
               end
             end)

      refute eventually(fn ->
               Registry.lookup(LemonRouter.ToolStatusRegistry, {session_key, "telegram", :status}) !=
                 []
             end)

      GenServer.stop(pid)
    end

    test "explicit projected-child metadata seeds reusable bindings for later poll follow-up events" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
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

      task_surface = {:status_task, "task_root_meta_followup"}

      projected_child =
        LemonCore.Event.new(
          :task_projected_child_action,
          %{
            engine: "codex",
            action: %{
              id: "taskproj:child_run_meta_followup:read_1",
              kind: "tool",
              title: "Read: AGENTS.md",
              detail: %{
                child_run_id: "child_run_meta_followup",
                task_id: "task-store-meta-followup"
              }
            },
            phase: :completed,
            ok: true,
            message: nil,
            level: nil
          },
          %{
            run_id: run_id,
            session_key: session_key,
            surface: task_surface,
            root_action_id: "task_root_meta_followup"
          }
        )

      poll_completed =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_poll_meta_followup_1",
              kind: "subagent",
              title: "task: poll review",
              detail: %{
                name: "task",
                args: %{"action" => "poll", "task_id" => "task-store-meta-followup"},
                result_meta: %{
                  task_id: "task-store-meta-followup",
                  status: "running",
                  engine: "codex",
                  current_action: %{title: "Write: report.md", kind: "tool", phase: "completed"}
                }
              }
            },
            phase: :completed,
            ok: true
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), projected_child)
      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), poll_completed)

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] ->
                   state = :sys.get_state(status_pid)

                   Enum.any?(Map.values(state.actions), fn action ->
                     action[:detail][:parent_tool_use_id] == "task_root_meta_followup" and
                       action[:title] == "Write: report.md"
                   end)

                 _ ->
                   false
               end
             end)

      assert eventually(fn ->
               state = :sys.get_state(pid)

               state.task_status_surfaces["task_root_meta_followup"] == %{
                 surface_id: "task_root_meta_followup",
                 surface: task_surface,
                 root_action_id: "task_root_meta_followup"
               } and
                 state.task_status_refs["task-store-meta-followup"] == %{
                   surface_id: "task_root_meta_followup",
                   surface: task_surface,
                   root_action_id: "task_root_meta_followup"
                 }
             end)

      refute eventually(fn ->
               Registry.lookup(LemonRouter.ToolStatusRegistry, {session_key, "telegram", :status}) !=
                 []
             end)

      GenServer.stop(pid)
    end

    test "persisted projected-child rebinding honors explicit surface metadata when surface_id differs from root_action_id" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
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

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "botx",
          peer_kind: :dm,
          peer_id: "12345"
        })

      root_run_id = "run_#{System.unique_integer([:positive])}"
      root_job = make_test_job(root_run_id, %{progress_msg_id: 111, user_msg_id: 222})

      assert {:ok, root_pid} =
               RunProcess.start_link(%{
                 run_id: root_run_id,
                 session_key: session_key,
                 job: root_job,
                 submit_to_gateway?: false
               })

      surface_id = "task_surface_meta_cross_run"
      task_surface = {:status_task, surface_id}
      root_action_id = "task_root_meta_cross_run"

      projected_child =
        LemonCore.Event.new(
          :task_projected_child_action,
          %{
            engine: "codex",
            action: %{
              id: "taskproj:child_run_meta_cross_run:read_1",
              kind: "tool",
              title: "Read: AGENTS.md",
              detail: %{child_run_id: "child_run_meta_cross_run"}
            },
            phase: :completed,
            ok: true,
            message: nil,
            level: nil
          },
          %{
            run_id: root_run_id,
            session_key: session_key,
            surface: task_surface,
            root_action_id: root_action_id
          }
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(root_run_id), projected_child)

      assert eventually(fn ->
               case AsyncTaskSurface.get(surface_id) do
                 {:ok, snapshot} ->
                   snapshot.status == :live and
                     snapshot.metadata.surface == task_surface and
                     snapshot.metadata.root_action_id == root_action_id

                 _ ->
                   false
               end
             end)

      assert root_surface_pid = AsyncTaskSurface.whereis(surface_id)
      GenServer.stop(root_pid)

      followup_run_id = "run_#{System.unique_integer([:positive])}"
      followup_job = make_test_job(followup_run_id, %{progress_msg_id: 333, user_msg_id: 444})

      assert {:ok, followup_pid} =
               RunProcess.start_link(%{
                 run_id: followup_run_id,
                 session_key: session_key,
                 job: followup_job,
                 submit_to_gateway?: false
               })

      persisted_followup =
        LemonCore.Event.new(
          :task_projected_child_action,
          %{
            engine: "codex",
            action: %{
              id: "taskproj:child_run_meta_cross_run:write_1",
              kind: "tool",
              title: "Write: report.md",
              detail: %{child_run_id: "child_run_meta_cross_run"}
            },
            phase: :completed,
            ok: true,
            message: nil,
            level: nil
          },
          %{
            run_id: followup_run_id,
            session_key: session_key,
            root_action_id: root_action_id
          }
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(followup_run_id), persisted_followup)

      assert AsyncTaskSurface.whereis(surface_id) == root_surface_pid

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] ->
                   Enum.any?(Map.values(:sys.get_state(status_pid).actions), fn action ->
                     action[:detail][:parent_tool_use_id] == root_action_id and
                       action[:title] == "Write: report.md"
                   end)

                 _ ->
                   false
               end
             end)

      refute eventually(fn ->
               Registry.lookup(
                 LemonRouter.ToolStatusRegistry,
                 {session_key, "telegram", {:status_task, root_action_id}}
               ) != []
             end)

      assert eventually(fn ->
               state = :sys.get_state(followup_pid)

               state.task_status_surfaces[root_action_id] == %{
                 surface_id: surface_id,
                 surface: task_surface,
                 root_action_id: root_action_id
               }
             end)

      GenServer.stop(followup_pid)
    end

    test "root-action-first projected child metadata overrides the default task surface across runs" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
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

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "botx",
          peer_kind: :dm,
          peer_id: "12345"
        })

      root_run_id = "run_#{System.unique_integer([:positive])}"
      root_job = make_test_job(root_run_id, %{progress_msg_id: 111, user_msg_id: 222})

      assert {:ok, root_pid} =
               RunProcess.start_link(%{
                 run_id: root_run_id,
                 session_key: session_key,
                 job: root_job,
                 submit_to_gateway?: false
               })

      root_action_id = "task_root_override_late"
      surface_id = "task_surface_override_late"
      task_surface = {:status_task, surface_id}

      task_started =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: root_action_id,
              kind: "subagent",
              title: "task(codex): inspect repo",
              detail: %{name: "task"}
            },
            phase: :started
          },
          %{run_id: root_run_id, session_key: session_key}
        )

      projected_child =
        LemonCore.Event.new(
          :task_projected_child_action,
          %{
            engine: "codex",
            action: %{
              id: "taskproj:child_run_override_late:read_1",
              kind: "tool",
              title: "Read: AGENTS.md",
              detail: %{
                child_run_id: "child_run_override_late",
                task_id: "task-store-override-late"
              }
            },
            phase: :completed,
            ok: true,
            message: nil,
            level: nil
          },
          %{
            run_id: root_run_id,
            session_key: session_key,
            surface: task_surface,
            root_action_id: root_action_id
          }
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(root_run_id), task_started)
      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(root_run_id), projected_child)

      assert eventually(fn ->
               state = :sys.get_state(root_pid)
               identity = state.task_status_surfaces[root_action_id]

               is_map(identity) and identity.surface_id == surface_id and
                 identity.surface == task_surface and identity.root_action_id == root_action_id
             end)

      assert eventually(fn ->
               AsyncTaskSurface.lookup_identity_by_root_action_id(root_action_id) ==
                 {:ok,
                  %{
                    surface_id: surface_id,
                    surface: task_surface,
                    root_action_id: root_action_id
                  }}
             end)

      GenServer.stop(root_pid)

      followup_run_id = "run_#{System.unique_integer([:positive])}"
      followup_job = make_test_job(followup_run_id, %{progress_msg_id: 333, user_msg_id: 444})

      assert {:ok, followup_pid} =
               RunProcess.start_link(%{
                 run_id: followup_run_id,
                 session_key: session_key,
                 job: followup_job,
                 submit_to_gateway?: false
               })

      persisted_followup =
        LemonCore.Event.new(
          :task_projected_child_action,
          %{
            engine: "codex",
            action: %{
              id: "taskproj:child_run_override_late:write_1",
              kind: "tool",
              title: "Write: summary.md",
              detail: %{child_run_id: "child_run_override_late"}
            },
            phase: :completed,
            ok: true,
            message: nil,
            level: nil
          },
          %{
            run_id: followup_run_id,
            session_key: session_key,
            root_action_id: root_action_id
          }
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(followup_run_id), persisted_followup)

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] ->
                   Enum.any?(Map.values(:sys.get_state(status_pid).actions), fn action ->
                     action[:detail][:parent_tool_use_id] == root_action_id and
                       action[:title] == "Write: summary.md"
                   end)

                 _ ->
                   false
               end
             end)

      assert eventually(fn ->
               state = :sys.get_state(followup_pid)

               state.task_status_surfaces[root_action_id] == %{
                 surface_id: surface_id,
                 surface: task_surface,
                 root_action_id: root_action_id
               }
             end)

      GenServer.stop(followup_pid)
    end

    test "projected child actions bind to their task surface out of order, broadcast to the session, and track files" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
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

      prefix = "Inspecting the projected task"
      task_surface = {:status_task, "task_root_out_of_order"}

      :ok =
        LemonCore.Bus.broadcast(
          LemonCore.Bus.run_topic(run_id),
          LemonCore.Event.new(:delta, %{seq: 1, text: prefix}, %{
            run_id: run_id,
            session_key: session_key
          })
        )

      assert eventually(fn ->
               case Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, "telegram"}) do
                 [{coalescer_pid, _}] -> :sys.get_state(coalescer_pid).last_seq == 1
                 _ -> false
               end
             end)

      LemonRouter.StreamCoalescer.flush(session_key, "telegram")

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: :text,
                        content: ^prefix,
                        meta: %{run_id: ^run_id}
                      }},
                     1_500

      LemonCore.Bus.subscribe(LemonCore.Bus.session_topic(session_key))

      projected_started =
        LemonCore.Event.new(
          :task_projected_child_action,
          %{
            engine: "codex",
            action: %{
              id: "taskproj:child_run_1:read_1",
              kind: "tool",
              title: "Read: AGENTS.md",
              detail: %{
                parent_tool_use_id: "task_root_out_of_order",
                child_run_id: "child_run_1",
                task_id: "task-store-1"
              }
            },
            phase: :started,
            ok: nil,
            message: nil,
            level: nil
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), projected_started)

      assert_receive %LemonCore.Event{
                       type: :task_projected_child_action,
                       payload: %{
                         action: %{detail: %{parent_tool_use_id: "task_root_out_of_order"}}
                       },
                       meta: %{run_id: ^run_id, session_key: ^session_key}
                     },
                     1_500

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] ->
                   "taskproj:child_run_1:read_1" in :sys.get_state(status_pid).order

                 _ ->
                   false
               end
             end)

      LemonRouter.ToolStatusCoalescer.flush(session_key, "telegram", surface: task_surface)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: task_kind,
                        content: task_content,
                        meta: %{run_id: ^run_id}
                      }},
                     1_500

      assert task_kind in [:text, :edit]
      task_text = payload_text(task_content)

      assert String.contains?(task_text, prefix)
      assert String.contains?(task_text, "Read: AGENTS.md")

      projected_file_change =
        LemonCore.Event.new(
          :task_projected_child_action,
          %{
            engine: "codex",
            action: %{
              id: "taskproj:child_run_1:file_1",
              kind: "file_change",
              title: "Write review summary",
              detail: %{
                parent_tool_use_id: "task_root_out_of_order",
                child_run_id: "child_run_1",
                task_id: "task-store-1",
                changes: [
                  %{path: "artifacts/chart.png", kind: "added"},
                  %{path: "notes.txt", kind: "added"}
                ],
                result_meta: %{
                  auto_send_files: [
                    %{path: "workspace/report.txt", filename: "report.txt", caption: "Review"}
                  ]
                }
              }
            },
            phase: :completed,
            ok: true,
            message: nil,
            level: nil
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), projected_file_change)

      assert eventually(fn ->
               state = :sys.get_state(pid)

               state.generated_image_paths == ["artifacts/chart.png"] and
                 state.requested_send_files == [
                   %{path: "workspace/report.txt", filename: "report.txt", caption: "Review"}
                 ]
             end)

      refute eventually(fn ->
               Registry.lookup(LemonRouter.ToolStatusRegistry, {session_key, "telegram", :status}) !=
                 []
             end)

      GenServer.stop(pid)
    end

    test "stream handoff preserves the task surface binding on the task-scoped coalescer" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
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

      prefix = "Inspecting the task handoff"
      task_surface = {:status_task, "task_root_handoff_binding"}

      :ok =
        LemonCore.Bus.broadcast(
          LemonCore.Bus.run_topic(run_id),
          LemonCore.Event.new(:delta, %{seq: 1, text: prefix}, %{
            run_id: run_id,
            session_key: session_key
          })
        )

      assert eventually(fn ->
               case Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, "telegram"}) do
                 [{coalescer_pid, _}] -> :sys.get_state(coalescer_pid).last_seq == 1
                 _ -> false
               end
             end)

      task_started =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_root_handoff_binding",
              kind: "subagent",
              title: "task(codex): inspect repo",
              detail: %{name: "task"}
            },
            phase: :started
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), task_started)

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] ->
                   :sys.get_state(status_pid).surface_binding == %{
                     surface_id: "task_root_handoff_binding",
                     surface: task_surface,
                     root_action_id: "task_root_handoff_binding"
                   }

                 _ ->
                   false
               end
             end)

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

    test "two idle watchdog cycles on the same telegram run produce two visible prompts" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
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
          account_id: "default",
          peer_kind: :group,
          peer_id: "12345",
          thread_id: "778"
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
                 run_watchdog_confirm_timeout_ms: 250
               })

      started_event =
        LemonCore.Event.new(
          :run_started,
          %{run_id: run_id, session_key: session_key, engine: "echo"},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), started_event)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: first_kind,
                        content: first_content,
                        meta: %{run_id: ^run_id}
                      }},
                     1_500

      assert first_kind in [:text, :edit]
      assert payload_text(first_content) =~ "Keep waiting?"

      RunProcess.keep_alive(run_id, :continue)

      assert eventually(
               fn ->
                 st = :sys.get_state(pid)
                 st.run_watchdog_awaiting_confirmation? == false
               end,
               1_000
             )

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: second_kind,
                        content: second_content,
                        meta: %{run_id: ^run_id}
                      }},
                     1_500

      assert second_kind in [:text, :edit]
      assert payload_text(second_content) =~ "Keep waiting?"

      st = :sys.get_state(pid)
      assert st.run_watchdog_prompt_seq == 2

      RunProcess.keep_alive(run_id, :cancel)

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{completed: %{ok: false, error: :user_requested}},
                       meta: %{run_id: ^run_id, session_key: ^session_key, synthetic: true}
                     },
                     1_500

      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "watchdog user cancel preserves :user_requested runtime cancel reason" do
      previous_runtime = Application.get_env(:lemon_router, :watchdog_runtime)
      Application.put_env(:lemon_router, :watchdog_runtime, __MODULE__.WatchdogRuntimeStub)
      :persistent_term.put({__MODULE__.WatchdogRuntimeStub, :notify_pid}, self())

      on_exit(fn ->
        :persistent_term.erase({__MODULE__.WatchdogRuntimeStub, :notify_pid})

        if is_nil(previous_runtime) do
          Application.delete_env(:lemon_router, :watchdog_runtime)
        else
          Application.put_env(:lemon_router, :watchdog_runtime, previous_runtime)
        end
      end)

      run_id = "run_#{System.unique_integer([:positive])}"

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "default",
          peer_kind: :group,
          peer_id: "12345",
          thread_id: "779"
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

      RunProcess.keep_alive(run_id, :cancel)

      assert_receive {:watchdog_runtime_cancel, ^run_id, :user_requested}, 1_500

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{completed: %{ok: false, error: :user_requested}},
                       meta: %{run_id: ^run_id, session_key: ^session_key, synthetic: true}
                     },
                     1_500

      assert eventually(fn -> not Process.alive?(pid) end)
    end

    test "watchdog cancel path keeps synthetic completion state across a later timeout signal" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")

      LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(run_id))

      state = %{
        run_id: run_id,
        session_key: session_key,
        completed: false,
        aborted: false,
        run_watchdog_timeout_ms: 40,
        run_watchdog_confirmation_ref: nil,
        run_watchdog_awaiting_confirmation?: true,
        synthetic_completion_sent?: false
      }

      assert {:noreply, next_state} =
               RunProcess.handle_cast({:watchdog_keep_alive, :cancel}, state)

      assert next_state.synthetic_completion_sent?
      refute next_state.run_watchdog_awaiting_confirmation?

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{completed: %{ok: false, error: :user_requested}},
                       meta: %{run_id: ^run_id, session_key: ^session_key, synthetic: true}
                     },
                     1_500

      assert {:noreply, final_state} =
               RunProcess.handle_info(:run_watchdog_confirmation_timeout, next_state)

      assert final_state.synthetic_completion_sent?
      refute_receive %LemonCore.Event{type: :run_completed}, 100
    end

    test "watchdog timeout path keeps synthetic completion state across a later fallback" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")

      LemonCore.Bus.subscribe(LemonCore.Bus.run_topic(run_id))

      state = %{
        run_id: run_id,
        session_key: session_key,
        completed: false,
        aborted: false,
        run_watchdog_timeout_ms: 40,
        run_watchdog_confirmation_ref: nil,
        run_watchdog_awaiting_confirmation?: false,
        synthetic_completion_sent?: false
      }

      assert {:noreply, next_state} =
               RunProcess.handle_info(:run_watchdog_confirmation_timeout, state)

      assert next_state.synthetic_completion_sent?

      assert_receive %LemonCore.Event{
                       type: :run_completed,
                       payload: %{
                         completed: %{ok: false, error: {:run_idle_watchdog_timeout, 40}}
                       },
                       meta: %{run_id: ^run_id, session_key: ^session_key, synthetic: true}
                     },
                     1_500

      assert {:noreply, final_state} =
               RunProcess.handle_info({:gateway_run_down, :watchdog_followup}, next_state)

      assert final_state.synthetic_completion_sent?
      refute_receive %LemonCore.Event{type: :run_completed}, 100
    end
  end

  describe "zero-answer assistant retries" do
    test "auto-retries once with retry context in prompt" do
      run_id = "run_#{System.unique_integer([:positive])}"
      session_key = SessionKey.main("test-agent")

      job =
        %{make_test_job(run_id, %{origin: :channel}) | prompt: "Collect the latest status report"}

      {:ok, _} =
        start_supervised({__MODULE__.TestRunOrchestrator, [notify_pid: self()]})

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
        start_supervised({__MODULE__.TestRunOrchestrator, [notify_pid: self()]})

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
        start_supervised({__MODULE__.TestRunOrchestrator, [notify_pid: self()]})

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
        start_supervised({__MODULE__.TestRunOrchestrator, [notify_pid: self()]})

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
        ChatStateStore.put(session_key, %{
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
      assert eventually(fn -> ChatStateStore.get(session_key) == nil end)
    end
  end

  describe "task tool status routing" do
    test "task child actions stay attached to the parent task surface after later assistant text" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
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

      prefix = "Found the key files. Let me read the markdown renderer and the formatter:"
      task_surface = {:status_task, "task_1"}

      delta_event_1 =
        LemonCore.Event.new(
          :delta,
          %{seq: 1, text: prefix},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), delta_event_1)

      assert eventually(fn ->
               case Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, "telegram"}) do
                 [{coalescer_pid, _}] -> :sys.get_state(coalescer_pid).last_seq == 1
                 _ -> false
               end
             end)

      LemonRouter.StreamCoalescer.flush(session_key, "telegram")

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

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), task_start_event)

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
                        kind: task_kind,
                        content: task_content,
                        meta: %{run_id: ^run_id}
                      }},
                     1_500

      assert task_kind in [:text, :edit]
      task_text = payload_text(task_content)

      assert String.contains?(task_text, prefix)
      assert String.contains?(task_text, "task(claude): inspect repo")

      separate = "Separate answer chunk"

      delta_event_2 =
        LemonCore.Event.new(
          :delta,
          %{seq: 2, text: separate},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), delta_event_2)

      assert eventually(fn ->
               case Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, "telegram"}) do
                 [{coalescer_pid, _}] -> :sys.get_state(coalescer_pid).last_seq == 2
                 _ -> false
               end
             end)

      LemonRouter.StreamCoalescer.flush(session_key, "telegram")

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

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), task_child_event)

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

    test "parent completion does not recreate a reaped task surface" do
      run_id = "run_#{System.unique_integer([:positive])}"

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "botx",
          peer_kind: :dm,
          peer_id: "12345"
        })

      job = make_test_job(run_id, %{progress_msg_id: 111, user_msg_id: 222})

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false
               })

      task_surface = {:status_task, "task_reaped_before_parent_done"}

      task_started =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_reaped_before_parent_done",
              kind: "subagent",
              title: "task(codex): inspect repo",
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
              id: "task_reaped_before_parent_done",
              kind: "subagent",
              title: "task(codex): inspect repo",
              detail: %{name: "task"}
            },
            phase: :completed,
            ok: true
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), task_started)
      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), task_completed)

      assert eventually(fn ->
               Registry.lookup(
                 LemonRouter.ToolStatusRegistry,
                 {session_key, "telegram", task_surface}
               ) != []
             end)

      LemonRouter.ToolStatusCoalescer.flush(session_key, "telegram", surface: task_surface)

      [{task_pid, _}] =
        Registry.lookup(LemonRouter.ToolStatusRegistry, {session_key, "telegram", task_surface})

      task_state = :sys.get_state(task_pid)
      assert is_reference(task_state.reap_token)

      task_ref = Process.monitor(task_pid)
      send(task_pid, {:reap_if_idle, task_state.reap_token})
      assert_receive {:DOWN, ^task_ref, :process, ^task_pid, :normal}, 500

      assert eventually(fn ->
               state = :sys.get_state(pid)
               state.task_status_surfaces == %{}
             end)

      completed_event =
        LemonCore.Event.new(
          :run_completed,
          %{completed: %{ok: true, answer: "done"}},
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), completed_event)

      assert eventually(fn -> not Process.alive?(pid) end)

      assert [] ==
               Registry.lookup(
                 LemonRouter.ToolStatusRegistry,
                 {session_key, "telegram", task_surface}
               )
    end

    test "async task poll actions bind by detail.task_id" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
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

      task_surface = {:status_task, "task_root_detail"}

      task_started =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_root_detail",
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
              id: "task_root_detail",
              kind: "subagent",
              title: "task(codex): review fix",
              detail: %{
                name: "task",
                result: "Task queued: review fix (task-store-detail-1)",
                result_meta: %{status: "queued", run_id: "child_run_detail_1"},
                task_id: "task-store-detail-1"
              }
            },
            phase: :completed,
            ok: true
          },
          %{run_id: run_id, session_key: session_key}
        )

      poll_completed =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_poll_detail_1",
              kind: "subagent",
              title: "task: poll review",
              detail: %{
                name: "task",
                args: %{"action" => "poll"},
                task_id: "task-store-detail-1",
                result_meta: %{
                  status: "running",
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

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), task_started)

      assert eventually(fn ->
               case AsyncTaskSurface.get("task_root_detail") do
                 {:ok, snapshot} ->
                   snapshot.status == :bound and
                     snapshot.metadata.surface_id == "task_root_detail" and
                     snapshot.metadata.root_action_id == "task_root_detail" and
                     snapshot.metadata.surface == task_surface and
                     snapshot.metadata.parent_run_id == run_id

                 _ ->
                   false
               end
             end)

      assert root_surface_pid = AsyncTaskSurface.whereis("task_root_detail")

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), task_completed)

      assert eventually(fn ->
               case AsyncTaskSurface.get("task_root_detail") do
                 {:ok, snapshot} -> snapshot.status == :live
                 _ -> false
               end
             end)

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), poll_completed)

      assert AsyncTaskSurface.whereis("task_root_detail") == root_surface_pid

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] ->
                   Enum.any?(Map.values(:sys.get_state(status_pid).actions), fn action ->
                     action[:detail][:parent_tool_use_id] == "task_root_detail" and
                       action[:title] == "Read: AGENTS.md"
                   end)

                 _ ->
                   false
               end
             end)

      assert eventually(fn ->
               state = :sys.get_state(pid)

               state.task_status_surfaces["task_root_detail"] == %{
                 surface_id: "task_root_detail",
                 surface: task_surface,
                 root_action_id: "task_root_detail"
               } and
                 state.task_status_refs["task-store-detail-1"] == %{
                   surface_id: "task_root_detail",
                   surface: task_surface,
                   root_action_id: "task_root_detail"
                 }
             end)

      GenServer.stop(pid)
    end

    test "async task poll actions reuse router-owned task-root identity across runs" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
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

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "botx",
          peer_kind: :dm,
          peer_id: "12345"
        })

      root_run_id = "run_#{System.unique_integer([:positive])}"
      root_job = make_test_job(root_run_id, %{progress_msg_id: 111, user_msg_id: 222})

      assert {:ok, root_pid} =
               RunProcess.start_link(%{
                 run_id: root_run_id,
                 session_key: session_key,
                 job: root_job,
                 submit_to_gateway?: false
               })

      task_surface = {:status_task, "task_root_cross_run"}

      task_started =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_root_cross_run",
              kind: "subagent",
              title: "task(codex): cross run review",
              detail: %{name: "task"}
            },
            phase: :started
          },
          %{run_id: root_run_id, session_key: session_key}
        )

      task_completed =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_root_cross_run",
              kind: "subagent",
              title: "task(codex): cross run review",
              detail: %{
                name: "task",
                result: "Task queued: cross run review (task-store-cross-run-1)",
                result_meta: %{task_id: "task-store-cross-run-1", status: "queued"},
                task_id: "task-store-cross-run-1"
              }
            },
            phase: :completed,
            ok: true
          },
          %{run_id: root_run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(root_run_id), task_started)
      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(root_run_id), task_completed)

      assert eventually(fn ->
               case AsyncTaskSurface.get("task_root_cross_run") do
                 {:ok, snapshot} ->
                   snapshot.status == :live and
                     snapshot.metadata.task_ids == ["task-store-cross-run-1"]

                 _ ->
                   false
               end
             end)

      assert root_surface_pid = AsyncTaskSurface.whereis("task_root_cross_run")
      GenServer.stop(root_pid)

      poll_run_id = "run_#{System.unique_integer([:positive])}"
      poll_job = make_test_job(poll_run_id, %{progress_msg_id: 333, user_msg_id: 444})

      assert {:ok, poll_pid} =
               RunProcess.start_link(%{
                 run_id: poll_run_id,
                 session_key: session_key,
                 job: poll_job,
                 submit_to_gateway?: false
               })

      poll_completed =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_poll_cross_run_1",
              kind: "subagent",
              title: "task: poll cross run review",
              detail: %{
                name: "task",
                args: %{"action" => "poll", "task_id" => "task-store-cross-run-1"},
                result_meta: %{
                  task_id: "task-store-cross-run-1",
                  engine: "codex",
                  current_action: %{title: "Read: AGENTS.md", kind: "tool", phase: "completed"}
                }
              }
            },
            phase: :completed,
            ok: true
          },
          %{run_id: poll_run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(poll_run_id), poll_completed)

      assert AsyncTaskSurface.whereis("task_root_cross_run") == root_surface_pid

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] ->
                   Enum.any?(Map.values(:sys.get_state(status_pid).actions), fn action ->
                     action[:detail][:parent_tool_use_id] == "task_root_cross_run" and
                       action[:title] == "Read: AGENTS.md"
                   end)

                 _ ->
                   false
               end
             end)

      assert eventually(fn ->
               state = :sys.get_state(poll_pid)

               state.task_status_refs["task-store-cross-run-1"] == %{
                 surface_id: "task_root_cross_run",
                 surface: task_surface,
                 root_action_id: "task_root_cross_run"
               }
             end)

      GenServer.stop(poll_pid)
    end

    test "late parent-linked task_id enrichment persists across run exit and follow-up polls" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
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

      session_key =
        SessionKey.channel_peer(%{
          agent_id: "test-agent",
          channel_id: "telegram",
          account_id: "botx",
          peer_kind: :dm,
          peer_id: "12345"
        })

      root_run_id = "run_#{System.unique_integer([:positive])}"
      root_job = make_test_job(root_run_id, %{progress_msg_id: 111, user_msg_id: 222})

      assert {:ok, root_pid} =
               RunProcess.start_link(%{
                 run_id: root_run_id,
                 session_key: session_key,
                 job: root_job,
                 submit_to_gateway?: false
               })

      root_action_id = "task_root_parent_task_id"
      task_id = "task-store-parent-task-id"
      task_surface = {:status_task, root_action_id}

      task_started =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: root_action_id,
              kind: "subagent",
              title: "task(codex): inspect repo",
              detail: %{name: "task"}
            },
            phase: :started
          },
          %{run_id: root_run_id, session_key: session_key}
        )

      child_action =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "codex",
            action: %{
              id: "task_child_parent_task_id_1",
              kind: "tool",
              title: "Read: AGENTS.md",
              detail: %{
                parent_tool_use_id: root_action_id,
                task_id: task_id
              }
            },
            phase: :completed,
            ok: true
          },
          %{run_id: root_run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(root_run_id), task_started)
      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(root_run_id), child_action)

      assert eventually(fn ->
               case AsyncTaskSurface.get(root_action_id) do
                 {:ok, snapshot} ->
                   snapshot.metadata.task_id == task_id and
                     snapshot.metadata.task_ids == [task_id]

                 _ ->
                   false
               end
             end)

      GenServer.stop(root_pid)

      assert AsyncTaskSurface.lookup_identity_by_task_id(task_id) ==
               {:ok,
                %{
                  surface_id: root_action_id,
                  surface: task_surface,
                  root_action_id: root_action_id
                }}

      poll_run_id = "run_#{System.unique_integer([:positive])}"
      poll_job = make_test_job(poll_run_id, %{progress_msg_id: 333, user_msg_id: 444})

      assert {:ok, poll_pid} =
               RunProcess.start_link(%{
                 run_id: poll_run_id,
                 session_key: session_key,
                 job: poll_job,
                 submit_to_gateway?: false
               })

      poll_completed =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_poll_parent_task_id_1",
              kind: "subagent",
              title: "task: poll inspect repo",
              detail: %{
                name: "task",
                args: %{"action" => "poll", "task_id" => task_id},
                result_meta: %{
                  task_id: task_id,
                  engine: "codex",
                  current_action: %{title: "Write: summary.md", kind: "tool", phase: "completed"}
                }
              }
            },
            phase: :completed,
            ok: true
          },
          %{run_id: poll_run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(poll_run_id), poll_completed)

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] ->
                   Enum.any?(Map.values(:sys.get_state(status_pid).actions), fn action ->
                     action[:detail][:parent_tool_use_id] == root_action_id and
                       action[:title] == "Write: summary.md"
                   end)

                 _ ->
                   false
               end
             end)

      GenServer.stop(poll_pid)
    end

    test "terminal task poll events drive router-owned async task surfaces to terminal and reap" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
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

      job = make_test_job(run_id, %{progress_msg_id: 111, user_msg_id: 222})

      assert {:ok, pid} =
               RunProcess.start_link(%{
                 run_id: run_id,
                 session_key: session_key,
                 job: job,
                 submit_to_gateway?: false
               })

      task_surface = {:status_task, "task_root_terminal"}

      task_started =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_root_terminal",
              kind: "subagent",
              title: "task(codex): terminal review",
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
              id: "task_root_terminal",
              kind: "subagent",
              title: "task(codex): terminal review",
              detail: %{
                name: "task",
                result_meta: %{task_id: "task-store-terminal", status: "queued"},
                task_id: "task-store-terminal"
              }
            },
            phase: :completed,
            ok: true
          },
          %{run_id: run_id, session_key: session_key}
        )

      poll_completed =
        LemonCore.Event.new(
          :engine_action,
          %{
            engine: "lemon",
            action: %{
              id: "task_poll_terminal_1",
              kind: "subagent",
              title: "task: poll terminal review",
              detail: %{
                name: "task",
                args: %{"action" => "poll", "task_id" => "task-store-terminal"},
                result_meta: %{
                  task_id: "task-store-terminal",
                  status: "completed",
                  engine: "codex",
                  current_action: %{title: "Write: summary.md", kind: "tool", phase: "completed"}
                }
              }
            },
            phase: :completed,
            ok: true
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), task_started)
      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), task_completed)
      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), poll_completed)

      assert eventually(fn ->
               case AsyncTaskSurface.get("task_root_terminal") do
                 {:ok, snapshot} -> snapshot.status == :terminal_grace
                 _ -> false
               end
             end)

      assert eventually(fn ->
               Registry.lookup(
                 LemonRouter.ToolStatusRegistry,
                 {session_key, "telegram", task_surface}
               ) != []
             end)

      LemonRouter.ToolStatusCoalescer.flush(session_key, "telegram", surface: task_surface)

      [{status_pid, _}] =
        Registry.lookup(LemonRouter.ToolStatusRegistry, {session_key, "telegram", task_surface})

      status_state = :sys.get_state(status_pid)

      assert status_state.surface_binding == %{
               surface_id: "task_root_terminal",
               surface: task_surface,
               root_action_id: "task_root_terminal"
             }

      assert is_reference(status_state.reap_token)

      status_ref = Process.monitor(status_pid)
      send(status_pid, {:reap_if_idle, status_state.reap_token})

      assert_receive {:DOWN, ^status_ref, :process, ^status_pid, :normal}, 500
      assert AsyncTaskSurface.whereis("task_root_terminal") == nil
      assert {:error, :not_found} = AsyncTaskSurface.get("task_root_terminal")

      GenServer.stop(pid)
    end

    test "async task poll actions stay attached to the original task surface by task_id" do
      start_if_needed(LemonChannels.Registry, fn -> LemonChannels.Registry.start_link([]) end)
      start_if_needed(LemonChannels.Outbox, fn -> LemonChannels.Outbox.start_link([]) end)

      start_if_needed(LemonChannels.Outbox.RateLimiter, fn ->
        LemonChannels.Outbox.RateLimiter.start_link([])
      end)

      start_if_needed(LemonChannels.Outbox.Dedupe, fn ->
        LemonChannels.Outbox.Dedupe.start_link([])
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

      prefix = "Running external reviews"
      root_action_id = "task_root_followup_task_id"
      task_id = "task-store-followup-task-id-1"
      task_surface = {:status_task, root_action_id}

      :ok =
        LemonCore.Bus.broadcast(
          LemonCore.Bus.run_topic(run_id),
          LemonCore.Event.new(:delta, %{seq: 1, text: prefix}, %{
            run_id: run_id,
            session_key: session_key
          })
        )

      assert eventually(fn ->
               case Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, "telegram"}) do
                 [{coalescer_pid, _}] -> :sys.get_state(coalescer_pid).last_seq == 1
                 _ -> false
               end
             end)

      LemonRouter.StreamCoalescer.flush(session_key, "telegram")

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
              id: root_action_id,
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
              id: root_action_id,
              kind: "subagent",
              title: "task(codex): review fix",
              detail: %{
                name: "task",
                result: "Task queued: review fix (#{task_id})",
                result_meta: %{task_id: task_id, status: "queued", run_id: "child_run_1"}
              }
            },
            phase: :completed,
            ok: true
          },
          %{run_id: run_id, session_key: session_key}
        )

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), task_started)
      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), task_completed)

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] -> root_action_id in :sys.get_state(status_pid).order
                 _ -> false
               end
             end)

      followup_text = "Waiting on the review"

      :ok =
        LemonCore.Bus.broadcast(
          LemonCore.Bus.run_topic(run_id),
          LemonCore.Event.new(:delta, %{seq: 2, text: followup_text}, %{
            run_id: run_id,
            session_key: session_key
          })
        )

      assert eventually(fn ->
               case Registry.lookup(LemonRouter.CoalescerRegistry, {session_key, "telegram"}) do
                 [{coalescer_pid, _}] -> :sys.get_state(coalescer_pid).last_seq == 2
                 _ -> false
               end
             end)

      LemonRouter.StreamCoalescer.flush(session_key, "telegram")

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
                args: %{"action" => "poll", "task_id" => task_id},
                result: "Read: AGENTS.md",
                result_meta: %{
                  task_id: task_id,
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

      :ok = LemonCore.Bus.broadcast(LemonCore.Bus.run_topic(run_id), poll_completed)

      assert eventually(fn ->
               case Registry.lookup(
                      LemonRouter.ToolStatusRegistry,
                      {session_key, "telegram", task_surface}
                    ) do
                 [{status_pid, _}] ->
                   state = :sys.get_state(status_pid)

                   Enum.any?(Map.values(state.actions), fn action ->
                     action[:detail][:parent_tool_use_id] == root_action_id and
                       action[:title] == "Read: AGENTS.md"
                   end)

                 _ ->
                   false
               end
             end)

      refute eventually(fn ->
               Registry.lookup(LemonRouter.ToolStatusRegistry, {session_key, "telegram", :status}) !=
                 []
             end)

      LemonRouter.ToolStatusCoalescer.flush(session_key, "telegram", surface: task_surface)

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        kind: task_kind,
                        content: task_content,
                        meta: %{run_id: ^run_id}
                      }},
                     1_500

      assert task_kind in [:text, :edit]
      task_text = payload_text(task_content)

      assert String.contains?(task_text, prefix)
      assert String.contains?(task_text, "task(codex): review fix")
      assert String.contains?(task_text, "Read: AGENTS.md")
      refute String.contains?(task_text, followup_text)
      refute String.contains?(task_text, "\ntask: ")

      GenServer.stop(pid)
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
                        meta: %{run_id: ^run_id, intent_meta: intent_meta_a} = meta_a
                      } = payload_a},
                     3_000

      assert_receive {:delivered,
                      %LemonChannels.OutboundPayload{
                        meta: %{run_id: ^run_id, intent_meta: intent_meta_b} = meta_b
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

      _ = ResumeIndexStore.delete_thread("botx", 12_345, nil, generation: 0)

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

      job = %LemonGateway.Types.Job{
        run_id: run_id,
        session_key: session_key,
        prompt: long_prompt,
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

      job = %LemonGateway.Types.Job{
        run_id: run_id,
        session_key: session_key,
        prompt: "short prompt",
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

      job = %LemonGateway.Types.Job{
        run_id: run_id,
        session_key: session_key,
        prompt: String.duplicate("a", 400),
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
      assert PendingCompactionStore.get(session_key) == nil
    end
  end

  describe "estimate_input_tokens_from_prompt/1" do
    test "returns char-based estimate for valid prompt" do
      state = %{
        execution_request: %LemonGateway.ExecutionRequest{
          run_id: "run-estimate",
          session_key: "session-estimate",
          prompt: String.duplicate("a", 400),
          engine_id: "codex"
        }
      }

      assert RunProcess.estimate_input_tokens_from_prompt(state) == 100
    end

    test "returns nil when prompt is nil" do
      state = %{
        execution_request: %LemonGateway.ExecutionRequest{
          run_id: "run-estimate-nil",
          session_key: "session-estimate-nil",
          prompt: nil,
          engine_id: "codex"
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
