defmodule LemonGatewayTest do
  alias Elixir.LemonGateway, as: LemonGateway
  use ExUnit.Case

  alias Elixir.LemonGateway.Event
  alias Elixir.LemonGateway.Types.Job

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

  defmodule LemonGatewayTest.CrashEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias Elixir.LemonGateway.Types.Job
    alias LemonCore.ResumeToken
    alias Elixir.LemonGateway.Event

    @impl true
    def id, do: "crash"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "crash resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: "crash"}

      Task.start(fn ->
        send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})
        Process.exit(sink_pid, :kill)
      end)

      {:ok, run_ref, %{pid: self()}}
    end

    @impl true
    def cancel(_ctx), do: :ok
  end

  defmodule ErrorEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias Elixir.LemonGateway.Types.Job
    alias LemonCore.ResumeToken
    alias Elixir.LemonGateway.Event

    @impl true
    def id, do: "error"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "error resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{}, _opts, _sink_pid) do
      {:error, :boom}
    end

    @impl true
    def cancel(_ctx), do: :ok
  end

  defmodule ActionEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias Elixir.LemonGateway.Types.Job
    alias LemonCore.ResumeToken
    alias Elixir.LemonGateway.Event

    @impl true
    def id, do: "action"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "action resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: "action"}
      action = Event.action(%{id: "step-1", kind: "work", title: "Step 1"})

      Task.start(fn ->
        send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})

        send(
          sink_pid,
          {:engine_event, run_ref,
           Event.action_event(%{engine: id(), action: action, phase: :started})}
        )

        send(
          sink_pid,
          {:engine_event, run_ref, Event.completed(%{engine: id(), ok: true, answer: "result"})}
        )
      end)

      {:ok, run_ref, %{pid: self()}}
    end

    @impl true
    def cancel(_ctx), do: :ok
  end

  defmodule LemonGatewayTest.StreamingEngine do
    @moduledoc "Test engine that emits multiple action events to test streaming edits"
    @behaviour Elixir.LemonGateway.Engine

    alias Elixir.LemonGateway.Types.Job
    alias LemonCore.ResumeToken
    alias Elixir.LemonGateway.Event

    @impl true
    def id, do: "streaming"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "streaming resume #{sid}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: "streaming"}
      action1 = Event.action(%{id: "step-1", kind: "work", title: "Step 1"})
      action2 = Event.action(%{id: "step-2", kind: "work", title: "Step 2"})

      Task.start(fn ->
        send(sink_pid, {:engine_event, run_ref, Event.started(%{engine: id(), resume: resume})})
        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           Event.action_event(%{engine: id(), action: action1, phase: :started})}
        )

        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           Event.action_event(%{engine: id(), action: action1, phase: :completed})}
        )

        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           Event.action_event(%{engine: id(), action: action2, phase: :started})}
        )

        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           Event.action_event(%{engine: id(), action: action2, phase: :completed})}
        )

        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           Event.completed(%{engine: id(), ok: true, answer: "done streaming"})}
        )
      end)

      {:ok, run_ref, %{pid: self()}}
    end

    @impl true
    def cancel(_ctx), do: :ok
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
      default_engine: "echo",
      enable_telegram: false
    })

    Application.put_env(:lemon_gateway, :engines, [
      Elixir.LemonGateway.Engines.Echo,
      LemonGatewayTest.CrashEngine,
      ErrorEngine,
      ActionEngine,
      LemonGatewayTest.StreamingEngine
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    :ok
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    :ok
  end

  test "submits a job and receives completion" do
    session_key = "test:1"

    job = %Job{
      session_key: session_key,
      prompt: "hello",
      resume: nil,
      engine_id: nil,
      meta: %{notify_pid: self(), user_msg_id: 1}
    }

    Elixir.LemonGateway.submit(job)

    assert_receive {:lemon_gateway_run_completed, ^job,
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

  test "thread worker frees slot when run crashes" do
    session_key = "test:2"

    crash_job = %Job{
      session_key: session_key,
      prompt: "boom",
      resume: nil,
      engine_id: "crash",
      meta: %{notify_pid: self(), user_msg_id: 10}
    }

    ok_job = %Job{
      session_key: session_key,
      prompt: "ok",
      resume: nil,
      engine_id: "echo",
      meta: %{notify_pid: self(), user_msg_id: 11}
    }

    Elixir.LemonGateway.submit(crash_job)
    Elixir.LemonGateway.submit(ok_job)

    assert_receive {:lemon_gateway_run_completed, ^ok_job,
                    %{__event__: :completed, ok: true, answer: "Echo: ok"}},
                   2_000
  end

  test "scheduler handles back-to-back submits for same thread" do
    session_key = "test:3"

    job1 = %Job{
      session_key: session_key,
      prompt: "first",
      resume: nil,
      engine_id: "echo",
      meta: %{notify_pid: self(), user_msg_id: 20}
    }

    job2 = %Job{
      session_key: session_key,
      prompt: "second",
      resume: nil,
      engine_id: "echo",
      meta: %{notify_pid: self(), user_msg_id: 21}
    }

    Task.async(fn -> Elixir.LemonGateway.submit(job1) end)
    Task.async(fn -> Elixir.LemonGateway.submit(job2) end)

    assert_receive {:lemon_gateway_run_completed, ^job1,
                    %{__event__: :completed, ok: true, answer: "Echo: first"}},
                   2_000

    assert_receive {:lemon_gateway_run_completed, ^job2,
                    %{__event__: :completed, ok: true, answer: "Echo: second"}},
                   2_000
  end

  test "scheduler re-creates worker after idle stop" do
    session_key = "test:4"

    job1 = %Job{
      session_key: session_key,
      prompt: "one",
      resume: nil,
      engine_id: "echo",
      meta: %{notify_pid: self(), user_msg_id: 30}
    }

    job2 = %Job{
      session_key: session_key,
      prompt: "two",
      resume: nil,
      engine_id: "echo",
      meta: %{notify_pid: self(), user_msg_id: 31}
    }

    Elixir.LemonGateway.submit(job1)

    assert_receive {:lemon_gateway_run_completed, ^job1,
                    %{__event__: :completed, ok: true, answer: "Echo: one"}},
                   2_000

    # Allow worker to stop when idle.
    Process.sleep(50)

    Elixir.LemonGateway.submit(job2)

    assert_receive {:lemon_gateway_run_completed, ^job2,
                    %{__event__: :completed, ok: true, answer: "Echo: two"}},
                   2_000
  end

  test "engine start error still notifies completion" do
    session_key = "test:5"

    job = %Job{
      session_key: session_key,
      prompt: "fail",
      resume: nil,
      engine_id: "error",
      meta: %{notify_pid: self(), user_msg_id: 40}
    }

    Elixir.LemonGateway.submit(job)

    assert_receive {:lemon_gateway_run_completed, ^job, %{__event__: :completed, ok: false}},
                   1_000
  end

  test "telegram dedupe init is idempotent" do
    table = :lemon_gateway_test_dedupe
    assert :ok = LemonCore.Dedupe.Ets.init(table)
    assert :ok = LemonCore.Dedupe.Ets.init(table)
  end
end
