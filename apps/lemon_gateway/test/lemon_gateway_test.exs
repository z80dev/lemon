defmodule LemonGatewayTest do
  alias Elixir.LemonGateway, as: LemonGateway
  use ExUnit.Case

  alias Elixir.LemonGateway.ExecutionRequest
  alias Elixir.LemonGateway.Event

  setup do
    # Isolate Telegram poller file locks from any locally running gateway process (and from other tests).
    lock_dir =
      Path.join(System.tmp_dir!(), "lemon_test_locks_#{System.unique_integer([:positive])}")

    System.put_env("LEMON_LOCK_DIR", lock_dir)

    on_exit(fn ->
      System.delete_env("LEMON_LOCK_DIR")
      _ = File.rm_rf(lock_dir)
    end)

    :ok
  end

  defp submit_request(%ExecutionRequest{} = request) do
    Elixir.LemonGateway.Scheduler.submit_execution(request)
  end

  defp request(session_key, prompt, scenario, meta \\ %{}) do
    %ExecutionRequest{
      run_id: nil,
      session_key: session_key,
      prompt: prompt,
      resume: nil,
      conversation_key: {:session, session_key},
      meta: Map.put(meta, :scenario, scenario)
    }
  end

  describe "ExecutionRequest adapter" do
    test "to_command/1 preserves execution fields without queue semantics" do
      request = %ExecutionRequest{
        run_id: "run-1",
        session_key: "agent:default:main",
        prompt: "hello",
        cwd: "/tmp",
        resume: %LemonCore.ResumeToken{engine: "lemon", value: "resume-1"},
        lane: :main,
        tool_policy: %{approvals: %{"bash" => "always"}},
        conversation_key: {:session, "agent:default:main"},
        meta: %{origin: :test}
      }

      command = ExecutionRequest.to_command(request)
      request_map = Map.from_struct(request)

      assert command.run_id == request.run_id
      assert command.session_key == request.session_key
      assert command.prompt == request.prompt
      assert command.cwd == request.cwd
      assert command.resume == request.resume
      assert command.lane == request.lane
      assert command.tool_policy == request.tool_policy
      assert command.conversation_key == request.conversation_key
      assert command.meta.origin == :test
      refute Map.has_key?(request_map, :queue_mode)
    end

    test "LemonGateway.submit/1 accepts only core execution commands" do
      request = %ExecutionRequest{
        run_id: "run-1",
        session_key: "agent:default:main",
        prompt: "hello",
        conversation_key: {:session, "agent:default:main"}
      }

      assert_raise FunctionClauseError, fn -> apply(LemonGateway, :submit, [request]) end
    end
  end

  defmodule GatewayFixtureExecutor do
    @behaviour LemonGateway.Executor

    alias LemonCore.ResumeToken
    alias LemonGateway.Event
    alias LemonGateway.ExecutionRequest

    @impl true
    def start_run(%ExecutionRequest{meta: %{scenario: "error"}}, _opts, _sink_pid),
      do: {:error, :boom}

    def start_run(%ExecutionRequest{meta: %{scenario: "crash"}} = request, _opts, sink_pid) do
      run_ref = make_ref()
      resume = request.resume || %ResumeToken{engine: "lemon", value: "crash"}

      {:ok, task_pid} =
        Task.start(fn ->
          send(
            sink_pid,
            {:engine_event, run_ref, Event.started(%{engine: "lemon", resume: resume})}
          )

          Process.exit(sink_pid, :kill)
        end)

      {:ok, run_ref, %{task_pid: task_pid}}
    end

    def start_run(%ExecutionRequest{} = request, _opts, sink_pid) do
      run_ref = make_ref()
      resume = request.resume || %ResumeToken{engine: "lemon", value: "fixture"}

      {:ok, task_pid} =
        Task.start(fn ->
          send(
            sink_pid,
            {:engine_event, run_ref, Event.started(%{engine: "lemon", resume: resume})}
          )

          send(
            sink_pid,
            {:engine_event, run_ref,
             Event.completed(%{
               engine: "lemon",
               resume: resume,
               ok: true,
               answer: "Echo: #{request.prompt}"
             })}
          )
        end)

      {:ok, run_ref, %{task_pid: task_pid}}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    def cancel(_ctx), do: :ok

    @impl true
    def steer(_ctx, _text), do: {:error, :unsupported}

    @impl true
    def redirect(_ctx, _text), do: {:error, :unsupported}
  end

  defmodule TestTelegramAPI do
    @moduledoc false

    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]},
        type: :worker,
        restart: :temporary,
        shutdown: 500
      }
    end

    def start_link(opts \\ []) do
      Agent.start_link(
        fn ->
          %{
            updates_queue: Keyword.get(opts, :updates_queue, []),
            notify_pid: Keyword.get(opts, :notify_pid),
            calls: []
          }
        end,
        name: __MODULE__
      )
    end

    def set_updates_queue(queue) do
      Agent.update(__MODULE__, &%{&1 | updates_queue: queue})
    end

    def set_notify_pid(pid) do
      Agent.update(__MODULE__, &%{&1 | notify_pid: pid})
    end

    def calls do
      Agent.get(__MODULE__, &Enum.reverse(&1.calls))
    end

    def get_updates(_token, _offset, _timeout_ms) do
      {updates, notify_pid} =
        Agent.get_and_update(__MODULE__, fn state ->
          case state.updates_queue do
            [head | rest] ->
              {head, %{state | updates_queue: rest}}

            [] ->
              {[], state}
          end
          |> then(fn {batch, new_state} -> {{batch, new_state.notify_pid}, new_state} end)
        end)

      if is_pid(notify_pid) do
        send(notify_pid, {:api_get_updates, updates, System.monotonic_time(:millisecond)})
      end

      {:ok, %{"ok" => true, "result" => updates}}
    end

    def send_message(_token, chat_id, text, reply_to_message_id \\ nil) do
      now = System.monotonic_time(:millisecond)

      Agent.update(__MODULE__, fn state ->
        %{state | calls: [{:send, chat_id, text, reply_to_message_id, now} | state.calls]}
      end)

      notify_pid = Agent.get(__MODULE__, & &1.notify_pid)

      if is_pid(notify_pid) do
        send(notify_pid, {:api_send_message, chat_id, text, reply_to_message_id, now})
      end

      {:ok, %{"ok" => true, "result" => %{"message_id" => 123}}}
    end

    def edit_message_text(_token, chat_id, message_id, text, _parse_mode \\ nil) do
      now = System.monotonic_time(:millisecond)

      Agent.update(__MODULE__, fn state ->
        %{state | calls: [{:edit, chat_id, message_id, text, now} | state.calls]}
      end)

      notify_pid = Agent.get(__MODULE__, & &1.notify_pid)

      if is_pid(notify_pid) do
        send(notify_pid, {:api_edit_message_text, chat_id, message_id, text, now})
      end

      {:ok, %{"ok" => true, "result" => %{"message_id" => message_id}}}
    end
  end

  defmodule PollingFailureTelegramAPI do
    @moduledoc false

    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]},
        type: :worker,
        restart: :temporary,
        shutdown: 500
      }
    end

    def start_link(opts \\ []) do
      Agent.start_link(
        fn ->
          %{
            responses: Keyword.get(opts, :responses, []),
            notify_pid: Keyword.get(opts, :notify_pid)
          }
        end,
        name: __MODULE__
      )
    end

    def get_updates(_token, _offset, _timeout_ms) do
      {response, notify_pid} =
        Agent.get_and_update(__MODULE__, fn state ->
          case state.responses do
            [head | rest] ->
              {head, %{state | responses: rest}}

            [] ->
              {{:ok, %{"ok" => true, "result" => []}}, state}
          end
          |> then(fn {resp, new_state} -> {{resp, new_state.notify_pid}, new_state} end)
        end)

      if is_pid(notify_pid) do
        send(notify_pid, {:poll_response, response})
      end

      response
    end

    def send_message(_token, _chat_id, _text, _reply_to_or_opts \\ nil, _parse_mode \\ nil) do
      {:ok, %{"ok" => true, "result" => %{"message_id" => 123}}}
    end
  end

  setup do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, Elixir.LemonGateway.Config, %{
      max_concurrent_runs: 1,
      enable_telegram: false
    })

    Application.put_env(:lemon_gateway, :executor, GatewayFixtureExecutor)

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    :ok
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    :ok
  end

  test "submits an execution request and receives completion" do
    session_key = "test:1"
    request = request(session_key, "hello", "echo", %{notify_pid: self(), user_msg_id: 1})

    submit_request(request)

    assert_receive {:lemon_gateway_run_completed, ^request,
                    %{__event__: :completed, ok: true, answer: "Echo: hello"}},
                   1_000
  end

  test "scheduler releases slot after worker death" do
    parent = self()

    _worker_a =
      spawn(fn ->
        Elixir.LemonGateway.Scheduler.request_slot(self(), :thread_a)

        receive do
          {:slot_granted, _slot_ref} ->
            send(parent, :worker_a_granted)
            Process.exit(self(), :kill)
        end
      end)

    worker_b =
      spawn(fn ->
        Elixir.LemonGateway.Scheduler.request_slot(self(), :thread_b)

        receive do
          {:slot_granted, _slot_ref} ->
            send(parent, :worker_b_granted)
        end
      end)

    assert_receive :worker_a_granted, 1_000
    assert_receive :worker_b_granted, 1_000

    Process.exit(worker_b, :kill)
  end

  test "thread worker frees slot when a run crashes" do
    session_key = "test:2"

    crash_request =
      request(session_key, "boom", "crash", %{notify_pid: self(), user_msg_id: 10})

    ok_request = request(session_key, "ok", "echo", %{notify_pid: self(), user_msg_id: 11})

    submit_request(crash_request)
    submit_request(ok_request)

    assert_receive {:lemon_gateway_run_completed, ^ok_request,
                    %{__event__: :completed, ok: true, answer: "Echo: ok"}},
                   2_000
  end

  test "scheduler handles back-to-back submissions for the same thread" do
    session_key = "test:3"
    request1 = request(session_key, "first", "echo", %{notify_pid: self(), user_msg_id: 20})
    request2 = request(session_key, "second", "echo", %{notify_pid: self(), user_msg_id: 21})

    Task.async(fn -> submit_request(request1) end)
    Task.async(fn -> submit_request(request2) end)

    assert_receive {:lemon_gateway_run_completed, ^request1,
                    %{__event__: :completed, ok: true, answer: "Echo: first"}},
                   2_000

    assert_receive {:lemon_gateway_run_completed, ^request2,
                    %{__event__: :completed, ok: true, answer: "Echo: second"}},
                   2_000
  end

  test "scheduler re-creates worker after idle stop" do
    session_key = "test:4"
    request1 = request(session_key, "one", "echo", %{notify_pid: self(), user_msg_id: 30})
    request2 = request(session_key, "two", "echo", %{notify_pid: self(), user_msg_id: 31})

    submit_request(request1)

    assert_receive {:lemon_gateway_run_completed, ^request1,
                    %{__event__: :completed, ok: true, answer: "Echo: one"}},
                   2_000

    # Allow worker to stop when idle.
    Process.sleep(50)

    submit_request(request2)

    assert_receive {:lemon_gateway_run_completed, ^request2,
                    %{__event__: :completed, ok: true, answer: "Echo: two"}},
                   2_000
  end

  test "executor start error still notifies completion" do
    session_key = "test:5"
    request = request(session_key, "fail", "error", %{notify_pid: self(), user_msg_id: 40})

    submit_request(request)

    assert_receive {:lemon_gateway_run_completed, ^request, %{__event__: :completed, ok: false}},
                   1_000
  end

  test "telegram dedupe init is idempotent" do
    table = :lemon_gateway_test_dedupe
    assert :ok = LemonCore.Dedupe.Ets.init(table)
    assert :ok = LemonCore.Dedupe.Ets.init(table)
  end
end
