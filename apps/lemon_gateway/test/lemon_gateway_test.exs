defmodule LemonGatewayTest do
  use ExUnit.Case

  alias LemonGateway.Event.Completed
  alias LemonGateway.Types.{ChatScope, Job}

  defmodule CrashEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

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
        send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
        Process.exit(sink_pid, :kill)
      end)

      {:ok, run_ref, %{pid: self()}}
    end

    @impl true
    def cancel(_ctx), do: :ok
  end

  defmodule ErrorEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

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
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

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
      action = %Event.Action{id: "step-1", kind: "work", title: "Step 1"}

      Task.start(fn ->
        send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})

        send(
          sink_pid,
          {:engine_event, run_ref,
           %Event.ActionEvent{engine: id(), action: action, phase: :started}}
        )

        send(
          sink_pid,
          {:engine_event, run_ref, %Event.Completed{engine: id(), ok: true, answer: "result"}}
        )
      end)

      {:ok, run_ref, %{pid: self()}}
    end

    @impl true
    def cancel(_ctx), do: :ok
  end

  defmodule StreamingEngine do
    @moduledoc "Test engine that emits multiple action events to test streaming edits"
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

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
      action1 = %Event.Action{id: "step-1", kind: "work", title: "Step 1"}
      action2 = %Event.Action{id: "step-2", kind: "work", title: "Step 2"}

      Task.start(fn ->
        send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           %Event.ActionEvent{engine: id(), action: action1, phase: :started}}
        )

        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           %Event.ActionEvent{engine: id(), action: action1, phase: :completed}}
        )

        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           %Event.ActionEvent{engine: id(), action: action2, phase: :started}}
        )

        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           %Event.ActionEvent{engine: id(), action: action2, phase: :completed}}
        )

        Process.sleep(10)

        send(
          sink_pid,
          {:engine_event, run_ref,
           %Event.Completed{engine: id(), ok: true, answer: "done streaming"}}
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

  setup do
    _ = Application.stop(:lemon_gateway)

    Application.put_env(:lemon_gateway, LemonGateway.Config, %{
      max_concurrent_runs: 1,
      default_engine: "echo",
      enable_telegram: false
    })

    Application.put_env(:lemon_gateway, :engines, [
      LemonGateway.Engines.Echo,
      CrashEngine,
      ErrorEngine,
      ActionEngine,
      StreamingEngine
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    :ok
  end

  setup do
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    :ok
  end

  test "submits a job and receives completion" do
    scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

    job = %Job{
      scope: scope,
      user_msg_id: 1,
      text: "hello",
      resume: nil,
      engine_hint: nil,
      meta: %{notify_pid: self()}
    }

    LemonGateway.submit(job)

    assert_receive {:lemon_gateway_run_completed, ^job,
                    %Completed{ok: true, answer: "Echo: hello"}},
                   1_000
  end

  test "scheduler releases slot after worker death" do
    parent = self()

    _worker_a =
      spawn(fn ->
        LemonGateway.Scheduler.request_slot(self(), :thread_a)

        receive do
          {:slot_granted, _slot_ref} ->
            send(parent, :worker_a_granted)
            Process.exit(self(), :kill)
        end
      end)

    worker_b =
      spawn(fn ->
        LemonGateway.Scheduler.request_slot(self(), :thread_b)

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
    scope = %ChatScope{transport: :test, chat_id: 2, topic_id: nil}

    crash_job = %Job{
      scope: scope,
      user_msg_id: 10,
      text: "boom",
      resume: nil,
      engine_hint: "crash",
      meta: %{notify_pid: self()}
    }

    ok_job = %Job{
      scope: scope,
      user_msg_id: 11,
      text: "ok",
      resume: nil,
      engine_hint: "echo",
      meta: %{notify_pid: self()}
    }

    LemonGateway.submit(crash_job)
    LemonGateway.submit(ok_job)

    assert_receive {:lemon_gateway_run_completed, ^ok_job,
                    %Completed{ok: true, answer: "Echo: ok"}},
                   2_000
  end

  test "scheduler handles back-to-back submits for same thread" do
    scope = %ChatScope{transport: :test, chat_id: 3, topic_id: nil}

    job1 = %Job{
      scope: scope,
      user_msg_id: 20,
      text: "first",
      resume: nil,
      engine_hint: "echo",
      meta: %{notify_pid: self()}
    }

    job2 = %Job{
      scope: scope,
      user_msg_id: 21,
      text: "second",
      resume: nil,
      engine_hint: "echo",
      meta: %{notify_pid: self()}
    }

    Task.async(fn -> LemonGateway.submit(job1) end)
    Task.async(fn -> LemonGateway.submit(job2) end)

    assert_receive {:lemon_gateway_run_completed, ^job1,
                    %Completed{ok: true, answer: "Echo: first"}},
                   2_000

    assert_receive {:lemon_gateway_run_completed, ^job2,
                    %Completed{ok: true, answer: "Echo: second"}},
                   2_000
  end

  test "scheduler re-creates worker after idle stop" do
    scope = %ChatScope{transport: :test, chat_id: 4, topic_id: nil}

    job1 = %Job{
      scope: scope,
      user_msg_id: 30,
      text: "one",
      resume: nil,
      engine_hint: "echo",
      meta: %{notify_pid: self()}
    }

    job2 = %Job{
      scope: scope,
      user_msg_id: 31,
      text: "two",
      resume: nil,
      engine_hint: "echo",
      meta: %{notify_pid: self()}
    }

    LemonGateway.submit(job1)

    assert_receive {:lemon_gateway_run_completed, ^job1,
                    %Completed{ok: true, answer: "Echo: one"}},
                   2_000

    # Allow worker to stop when idle.
    Process.sleep(50)

    LemonGateway.submit(job2)

    assert_receive {:lemon_gateway_run_completed, ^job2,
                    %Completed{ok: true, answer: "Echo: two"}},
                   2_000
  end

  test "engine start error still notifies completion" do
    scope = %ChatScope{transport: :test, chat_id: 5, topic_id: nil}

    job = %Job{
      scope: scope,
      user_msg_id: 40,
      text: "fail",
      resume: nil,
      engine_hint: "error",
      meta: %{notify_pid: self()}
    }

    LemonGateway.submit(job)

    assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: false}}, 1_000
  end

  test "telegram dedupe init is idempotent" do
    assert :ok = LemonGateway.Telegram.Dedupe.init()
    assert :ok = LemonGateway.Telegram.Dedupe.init()
  end

  test "telegram debounce waits for quiet period" do
    updates_a = [
      %{
        "update_id" => 1,
        "message" => %{
          "text" => "hello",
          "chat" => %{"id" => 1},
          "message_id" => 1
        }
      }
    ]

    updates_b = [
      %{
        "update_id" => 2,
        "message" => %{
          "text" => "world",
          "chat" => %{"id" => 1},
          "message_id" => 2
        }
      }
    ]

    {:ok, _} =
      start_supervised({TestTelegramAPI, [updates_queue: [updates_a], notify_pid: self()]})

    Application.put_env(:lemon_gateway, :telegram, %{
      bot_token: "token",
      api_mod: TestTelegramAPI,
      poll_interval_ms: 20,
      debounce_ms: 80,
      allowed_chat_ids: [1]
    })

    {:ok, _} = start_supervised(LemonGateway.Telegram.Transport)

    assert_receive {:api_get_updates, ^updates_a, _t1}, 500
    Process.sleep(60)
    TestTelegramAPI.set_updates_queue([updates_b])
    assert_receive {:api_get_updates, ^updates_b, t2}, 500
    assert_receive {:api_send_message, 1, "Running…", 2, t_send}, 1_000

    assert t_send - t2 >= 50
  end

  test "telegram outbox edits progress message for final result" do
    {:ok, _} = start_supervised({TestTelegramAPI, [notify_pid: self()]})
    TestTelegramAPI.set_notify_pid(self())
    assert is_pid(Process.whereis(TestTelegramAPI))

    if pid = Process.whereis(LemonGateway.Telegram.Outbox) do
      GenServer.stop(pid)
    end

    {:ok, _} =
      start_supervised(
        {LemonGateway.Telegram.Outbox,
         [bot_token: "token", api_mod: TestTelegramAPI, edit_throttle_ms: 0]}
      )

    assert is_pid(Process.whereis(LemonGateway.Telegram.Outbox))
    assert :sys.get_state(LemonGateway.Telegram.Outbox).api_mod == TestTelegramAPI

    scope = %ChatScope{transport: :telegram, chat_id: 1, topic_id: nil}

    job = %Job{
      scope: scope,
      user_msg_id: 10,
      text: "run",
      resume: nil,
      engine_hint: "action",
      meta: %{
        notify_pid: self(),
        chat_id: 1,
        progress_msg_id: 99,
        user_msg_id: 10
      }
    }

    LemonGateway.submit(job)

    assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: true}}, 1_000

    wait_for(
      fn ->
        Enum.any?(TestTelegramAPI.calls(), fn
          {:edit, 1, 99, text, _t} -> String.contains?(text, "Done.")
          _ -> false
        end)
      end,
      "expected final edit for progress_msg_id 99"
    )

    # Verify streaming edits occurred for the progress message during the run
    wait_for(
      fn ->
        Enum.any?(TestTelegramAPI.calls(), fn
          {:edit, 1, 99, text, _t} -> String.contains?(text, "Running")
          _ -> false
        end)
      end,
      "expected running edit for progress_msg_id 99"
    )
  end

  test "telegram streaming edits progress message during run" do
    {:ok, _} = start_supervised({TestTelegramAPI, [notify_pid: self()]})
    TestTelegramAPI.set_notify_pid(self())

    if pid = Process.whereis(LemonGateway.Telegram.Outbox) do
      GenServer.stop(pid)
    end

    {:ok, _} =
      start_supervised(
        {LemonGateway.Telegram.Outbox,
         [bot_token: "token", api_mod: TestTelegramAPI, edit_throttle_ms: 0]}
      )

    scope = %ChatScope{transport: :telegram, chat_id: 10, topic_id: nil}

    job = %Job{
      scope: scope,
      user_msg_id: 100,
      text: "stream",
      resume: nil,
      engine_hint: "streaming",
      meta: %{
        notify_pid: self(),
        chat_id: 10,
        progress_msg_id: 200,
        user_msg_id: 100
      }
    }

    LemonGateway.submit(job)

    assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: true}}, 2_000

    # Wait for final edit
    wait_for(
      fn ->
        Enum.any?(TestTelegramAPI.calls(), fn
          {:edit, 10, 200, text, _t_send} -> String.contains?(text, "Done.")
          _ -> false
        end)
      end,
      "expected final edit for chat 10 progress_msg_id 200"
    )

    # Verify edit operations were enqueued for the progress message
    edit_calls =
      TestTelegramAPI.calls()
      |> Enum.filter(fn
        {:edit, 10, 200, _text, _t} -> true
        _ -> false
      end)

    # Should have at least one edit for running updates
    assert length(edit_calls) >= 1, "Expected at least one edit call, got #{inspect(edit_calls)}"

    running_edits =
      Enum.filter(edit_calls, fn {:edit, _chat, _msg_id, text, _t} ->
        String.contains?(text, "Running")
      end)

    assert length(running_edits) >= 1,
           "Expected at least one running edit, got #{inspect(edit_calls)}"
  end

  test "telegram streaming edits use stable key for coalescing" do
    {:ok, _} = start_supervised({TestTelegramAPI, [notify_pid: self()]})
    TestTelegramAPI.set_notify_pid(self())

    if pid = Process.whereis(LemonGateway.Telegram.Outbox) do
      GenServer.stop(pid)
    end

    # Use a longer throttle so rapid updates get coalesced
    {:ok, _} =
      start_supervised(
        {LemonGateway.Telegram.Outbox,
         [bot_token: "token", api_mod: TestTelegramAPI, edit_throttle_ms: 100]}
      )

    scope = %ChatScope{transport: :telegram, chat_id: 20, topic_id: nil}

    job = %Job{
      scope: scope,
      user_msg_id: 200,
      text: "coalesce",
      resume: nil,
      engine_hint: "streaming",
      meta: %{
        notify_pid: self(),
        chat_id: 20,
        progress_msg_id: 300,
        user_msg_id: 200
      }
    }

    LemonGateway.submit(job)

    assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: true}}, 2_000

    # Wait a bit for throttled edits to complete
    Process.sleep(200)

    # With throttling, rapid updates should be coalesced, so we should have fewer
    # edits than there were events (started + 4 action events = 5 running renders)
    edit_calls =
      TestTelegramAPI.calls()
      |> Enum.filter(fn
        {:edit, 20, 300, _text, _t} -> true
        _ -> false
      end)

    # The key {chat_id, progress_msg_id, :edit} should coalesce rapid updates
    # We expect fewer actual API calls than the 5 render events
    assert length(edit_calls) <= 5,
           "Edits should be coalesced, got #{length(edit_calls)} calls"
  end

  test "telegram edits progress message when engine start fails" do
    {:ok, _} = start_supervised({TestTelegramAPI, [notify_pid: self()]})
    TestTelegramAPI.set_notify_pid(self())
    assert is_pid(Process.whereis(TestTelegramAPI))

    if pid = Process.whereis(LemonGateway.Telegram.Outbox) do
      GenServer.stop(pid)
    end

    {:ok, _} =
      start_supervised(
        {LemonGateway.Telegram.Outbox,
         [bot_token: "token", api_mod: TestTelegramAPI, edit_throttle_ms: 0]}
      )

    assert is_pid(Process.whereis(LemonGateway.Telegram.Outbox))
    assert :sys.get_state(LemonGateway.Telegram.Outbox).api_mod == TestTelegramAPI

    scope = %ChatScope{transport: :telegram, chat_id: 3, topic_id: nil}

    job = %Job{
      scope: scope,
      user_msg_id: 70,
      text: "fail",
      resume: nil,
      engine_hint: "error",
      meta: %{
        notify_pid: self(),
        chat_id: 3,
        progress_msg_id: 100,
        user_msg_id: 70
      }
    }

    LemonGateway.submit(job)

    assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: false}}, 1_000

    wait_for(
      fn ->
        Enum.any?(TestTelegramAPI.calls(), fn
          {:edit, 3, 100, _text, _t_send} -> true
          _ -> false
        end)
      end,
      "expected error edit for chat 3 message 100"
    )

    refute_receive {:api_send_message, _, _, _, _}, 200
  end

  defp wait_for(predicate, message), do: wait_for(predicate, message, 2_000)

  defp wait_for(predicate, message, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for(predicate, deadline, message)
  end

  defp do_wait_for(predicate, deadline, message) do
    if predicate.() do
      :ok
    else
      if System.monotonic_time(:millisecond) > deadline do
        flunk("#{message}. calls=#{inspect(TestTelegramAPI.calls())}")
      else
        Process.sleep(10)
        do_wait_for(predicate, deadline, message)
      end
    end
  end

  test "telegram dedupe skips duplicate update" do
    updates = [
      %{
        "update_id" => 5,
        "message" => %{
          "text" => "hello",
          "chat" => %{"id" => 1},
          "message_id" => 50
        }
      }
    ]

    {:ok, _} =
      start_supervised({TestTelegramAPI, [updates_queue: [updates, updates], notify_pid: self()]})

    Application.put_env(:lemon_gateway, :telegram, %{
      bot_token: "token",
      api_mod: TestTelegramAPI,
      poll_interval_ms: 20,
      debounce_ms: 10,
      allowed_chat_ids: [1]
    })

    {:ok, _} = start_supervised(LemonGateway.Telegram.Transport)

    assert_receive {:api_get_updates, ^updates, _t1}, 500
    assert_receive {:api_get_updates, ^updates, _t2}, 500
    assert_receive {:api_send_message, 1, "Running…", 50, _t_send}, 1_000
    refute_receive {:api_send_message, 1, "Running…", 50, _t_send2}, 200
  end

  test "telegram command bypasses debounce" do
    updates = [
      %{
        "update_id" => 6,
        "message" => %{
          "text" => "/status",
          "chat" => %{"id" => 2},
          "message_id" => 60
        }
      }
    ]

    {:ok, _} = start_supervised({TestTelegramAPI, [updates_queue: [updates], notify_pid: self()]})

    Application.put_env(:lemon_gateway, :telegram, %{
      bot_token: "token",
      api_mod: TestTelegramAPI,
      poll_interval_ms: 20,
      debounce_ms: 200,
      allowed_chat_ids: [2]
    })

    {:ok, _} = start_supervised(LemonGateway.Telegram.Transport)

    assert_receive {:api_get_updates, ^updates, t_poll}, 500
    assert_receive {:api_send_message, 2, "Running…", 60, t_send}, 500

    assert t_send - t_poll < 150
  end
end
