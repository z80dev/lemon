defmodule LemonGateway.Telegram.QueueModeIntegrationTest do
  @moduledoc """
  Integration tests for queue_mode application through Telegram transport.

  Verifies that:
  1. Binding queue_mode is correctly applied to jobs created from messages
  2. Default queue_mode is :collect when no binding queue_mode is set
  3. Queue override commands (/steer, /followup, /interrupt) work when allowed

  Note: These tests verify the transport layer's job creation. Some queue modes
  (like :steer) may be converted to other modes by ThreadWorker based on system
  state (e.g., no active run converts :steer to :followup). This is expected behavior.
  """
  use ExUnit.Case, async: false

  alias LemonGateway.Types.{ChatScope, Job}
  alias LemonGateway.{Config, BindingResolver}

  # Mock Telegram API that records calls and can inject updates
  defmodule MockTelegramAPI do
    use Agent

    def start_link(opts \\ []) do
      Agent.start_link(
        fn ->
          %{
            calls: [],
            pending_updates: opts[:updates] || [],
            update_id: opts[:start_update_id] || 1000,
            notify_pid: opts[:notify_pid]
          }
        end,
        name: __MODULE__
      )
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> Agent.stop(pid, :normal, 100)
      end
    catch
      :exit, _ -> :ok
    end

    def set_notify_pid(pid) do
      Agent.update(__MODULE__, &%{&1 | notify_pid: pid})
    end

    def enqueue_update(update) do
      Agent.update(__MODULE__, fn state ->
        id = state.update_id
        update_with_id = Map.put(update, "update_id", id)
        %{state | pending_updates: state.pending_updates ++ [update_with_id], update_id: id + 1}
      end)
    end

    def enqueue_message(chat_id, text, opts \\ []) do
      message_id = Keyword.get(opts, :message_id, System.unique_integer([:positive]))
      topic_id = Keyword.get(opts, :topic_id)
      reply_to = Keyword.get(opts, :reply_to)

      message = %{
        "message_id" => message_id,
        "chat" => %{"id" => chat_id, "type" => "private"},
        "text" => text,
        "date" => System.system_time(:second)
      }

      message =
        if topic_id do
          Map.put(message, "message_thread_id", topic_id)
        else
          message
        end

      message =
        if reply_to do
          Map.put(message, "reply_to_message", %{"message_id" => reply_to, "text" => ""})
        else
          message
        end

      enqueue_update(%{"message" => message})
    end

    def calls do
      Agent.get(__MODULE__, fn state -> Enum.reverse(state.calls) end)
    end

    def get_updates(_token, _offset, _timeout_ms) do
      Agent.get_and_update(__MODULE__, fn state ->
        updates = state.pending_updates
        new_state = %{state | pending_updates: []}
        {{:ok, %{"ok" => true, "result" => updates}}, new_state}
      end)
    end

    def send_message(_token, chat_id, text, reply_to_message_id \\ nil) do
      record({:send_message, chat_id, text, reply_to_message_id})
      msg_id = System.unique_integer([:positive])
      {:ok, %{"ok" => true, "result" => %{"message_id" => msg_id}}}
    end

    def edit_message_text(_token, chat_id, message_id, text) do
      record({:edit_message, chat_id, message_id, text})
      {:ok, %{"ok" => true}}
    end

    defp record(call) do
      Agent.update(__MODULE__, fn state ->
        %{state | calls: [call | state.calls]}
      end)

      notify_pid = Agent.get(__MODULE__, & &1.notify_pid)
      if is_pid(notify_pid), do: send(notify_pid, {:telegram_api_call, call})
      :ok
    end
  end

  # Test engine that captures submitted jobs for inspection
  # This captures jobs as they arrive at the engine (after ThreadWorker processing)
  defmodule JobCapturingEngine do
    @behaviour LemonGateway.Engine

    use Agent

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

    def start_link(opts \\ []) do
      Agent.start_link(fn -> %{jobs: [], notify_pid: opts[:notify_pid]} end, name: __MODULE__)
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> Agent.stop(pid, :normal, 100)
      end
    catch
      :exit, _ -> :ok
    end

    def set_notify_pid(pid) do
      Agent.update(__MODULE__, &%{&1 | notify_pid: pid})
    end

    def get_jobs do
      Agent.get(__MODULE__, & &1.jobs)
    end

    def clear_jobs do
      Agent.update(__MODULE__, &%{&1 | jobs: []})
    end

    @impl true
    def id, do: "capture"

    @impl true
    def format_resume(%ResumeToken{value: v}), do: "capture resume #{v}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = %ResumeToken{engine: id(), value: unique_id()}

      # Record the job
      Agent.update(__MODULE__, fn state ->
        notify_pid = state.notify_pid
        if is_pid(notify_pid), do: send(notify_pid, {:job_captured, job})
        %{state | jobs: [job | state.jobs]}
      end)

      # Complete immediately
      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
          Process.sleep(10)

          send(
            sink_pid,
            {:engine_event, run_ref,
             %Event.Completed{engine: id(), resume: resume, ok: true, answer: "captured"}}
          )
        end)

      {:ok, run_ref, %{task_pid: task_pid}}
    end

    @impl true
    def cancel(%{task_pid: pid}) when is_pid(pid) do
      Process.exit(pid, :kill)
      :ok
    end

    defp unique_id, do: Integer.to_string(System.unique_integer([:positive]))
  end

  setup do
    # Stop the app to reset state
    _ = Application.stop(:lemon_gateway)

    # Clean up any existing agents
    MockTelegramAPI.stop()
    JobCapturingEngine.stop()

    # Start our mock agents
    {:ok, _} = MockTelegramAPI.start_link(notify_pid: self())
    {:ok, _} = JobCapturingEngine.start_link(notify_pid: self())

    on_exit(fn ->
      MockTelegramAPI.stop()
      JobCapturingEngine.stop()
      Application.delete_env(:lemon_gateway, LemonGateway.Config)
      Application.delete_env(:lemon_gateway, :config_path)
      Application.delete_env(:lemon_gateway, :telegram)
    end)

    :ok
  end

  defp start_gateway_with_config(config_overrides) do
    # Stop the app first to ensure fresh config is loaded
    _ = Application.stop(:lemon_gateway)

    base_config = %{
      max_concurrent_runs: 10,
      default_engine: "capture",
      enable_telegram: true,
      bindings: []
    }

    config = Map.merge(base_config, config_overrides)

    Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
    Application.put_env(:lemon_gateway, Config, config)

    Application.put_env(:lemon_gateway, :engines, [
      JobCapturingEngine,
      LemonGateway.Engines.Echo
    ])

    Application.put_env(:lemon_gateway, :telegram, %{
      bot_token: "test_token",
      api_mod: MockTelegramAPI,
      poll_interval_ms: 50,
      dedupe_ttl_ms: 60_000,
      debounce_ms: 10,
      allowed_chat_ids: nil,
      allow_queue_override: config_overrides[:allow_queue_override] || false
    })

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
  end

  # ============================================================================
  # 1. Binding queue_mode is applied to jobs
  # ============================================================================

  describe "binding queue_mode application" do
    test "job gets queue_mode: :followup from binding" do
      start_gateway_with_config(%{
        bindings: [
          %{transport: :telegram, chat_id: 12345, queue_mode: :followup}
        ]
      })

      # Inject a message
      MockTelegramAPI.enqueue_message(12345, "test message")

      # Wait for job to be captured
      assert_receive {:job_captured, %Job{} = job}, 2000

      # Verify queue_mode from binding
      assert job.queue_mode == :followup
      assert job.scope.chat_id == 12345
      assert job.text == "test message"
    end

    test "job gets queue_mode: :interrupt from binding" do
      start_gateway_with_config(%{
        bindings: [
          %{transport: :telegram, chat_id: 33333, queue_mode: :interrupt}
        ]
      })

      MockTelegramAPI.enqueue_message(33333, "interrupt test")

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :interrupt
    end

    test "topic binding queue_mode takes precedence over chat binding" do
      start_gateway_with_config(%{
        bindings: [
          %{transport: :telegram, chat_id: 44444, queue_mode: :collect},
          %{transport: :telegram, chat_id: 44444, topic_id: 100, queue_mode: :followup}
        ]
      })

      # Message in topic should get topic binding queue_mode
      MockTelegramAPI.enqueue_message(44444, "topic message", topic_id: 100)

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :followup
      assert job.scope.topic_id == 100
    end

    test "chat without topic falls back to chat binding queue_mode" do
      start_gateway_with_config(%{
        bindings: [
          %{transport: :telegram, chat_id: 55555, queue_mode: :interrupt},
          %{transport: :telegram, chat_id: 55555, topic_id: 200, queue_mode: :followup}
        ]
      })

      # Message without topic should get chat binding queue_mode
      MockTelegramAPI.enqueue_message(55555, "chat message")

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :interrupt
      assert job.scope.topic_id == nil
    end
  end

  # ============================================================================
  # 2. Default queue_mode when no binding queue_mode is set
  # ============================================================================

  describe "default queue_mode behavior" do
    test "job defaults to queue_mode: :collect when no binding exists" do
      start_gateway_with_config(%{
        bindings: []
      })

      MockTelegramAPI.enqueue_message(99999, "no binding message")

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :collect
    end

    test "job defaults to queue_mode: :collect when binding has no queue_mode" do
      start_gateway_with_config(%{
        bindings: [
          %{transport: :telegram, chat_id: 88888, project: "some_project"}
        ]
      })

      MockTelegramAPI.enqueue_message(88888, "binding without queue_mode")

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :collect
    end
  end

  # ============================================================================
  # 3. Queue override commands when allow_queue_override is true
  # ============================================================================

  describe "queue override commands" do
    test "/followup command sets queue_mode: :followup when allowed" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: [
          %{transport: :telegram, chat_id: 22221, queue_mode: :collect}
        ]
      })

      MockTelegramAPI.enqueue_message(22221, "/followup add this to the previous")

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :followup
    end

    test "/interrupt command sets queue_mode: :interrupt when allowed" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: [
          %{transport: :telegram, chat_id: 33331, queue_mode: :collect}
        ]
      })

      MockTelegramAPI.enqueue_message(33331, "/interrupt stop everything!")

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :interrupt
    end

    test "queue override commands are ignored when allow_queue_override is false" do
      start_gateway_with_config(%{
        allow_queue_override: false,
        bindings: [
          %{transport: :telegram, chat_id: 44441, queue_mode: :collect}
        ]
      })

      # /interrupt should be ignored when not allowed
      MockTelegramAPI.enqueue_message(44441, "/interrupt this should not interrupt")

      assert_receive {:job_captured, %Job{} = job}, 2000

      # queue_mode should remain :collect from binding (override not applied)
      assert job.queue_mode == :collect
    end

    test "queue override takes precedence over binding queue_mode when allowed" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: [
          %{transport: :telegram, chat_id: 55551, queue_mode: :followup}
        ]
      })

      # Binding says :followup, but /interrupt should override
      MockTelegramAPI.enqueue_message(55551, "/interrupt urgent!")

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :interrupt
    end

    test "queue override with leading whitespace" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      MockTelegramAPI.enqueue_message(77771, "  /followup with spaces")

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :followup
    end

    test "queue override requires boundary (no match for /steerable)" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      MockTelegramAPI.enqueue_message(11110, "/steerable should not override")

      assert_receive {:job_captured, %Job{} = job}, 2000

      # Not treated as a queue override
      assert job.queue_mode == :collect
      assert job.text == "/steerable should not override"
    end

    @doc """
    Note: /steer command is converted to :followup by ThreadWorker when there's
    no active run. This test verifies the conversion behavior is working.
    """
    test "/steer command is converted to followup when no active run" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: [
          %{transport: :telegram, chat_id: 11111, queue_mode: :collect}
        ]
      })

      # /steer should be parsed by transport as :steer, then converted to :followup
      # by ThreadWorker since there's no active run
      MockTelegramAPI.enqueue_message(11111, "/steer please do this urgently")

      assert_receive {:job_captured, %Job{} = job}, 2000

      # After ThreadWorker processing, :steer becomes :followup (no active run)
      assert job.queue_mode == :followup
      # Queue override prefix is stripped from the text
      assert job.text == "please do this urgently"
    end

    test "queue override stripping preserves engine routing on subsequent /engine" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      MockTelegramAPI.enqueue_message(11117, "/steer /capture hello")

      assert_receive {:job_captured, %Job{} = job}, 2000

      # /steer override applied, then /capture is still visible to routing
      assert job.queue_mode == :followup
      assert job.engine_hint == "capture"
      assert job.text == "/capture hello"
    end

    test "/followup prefix is stripped from job.text" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      MockTelegramAPI.enqueue_message(11112, "/followup add this context")

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :followup
      assert job.text == "add this context"
    end

    test "/interrupt prefix is stripped from job.text" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      MockTelegramAPI.enqueue_message(11113, "/interrupt stop everything now")

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :interrupt
      assert job.text == "stop everything now"
    end

    test "queue override prefix stripping is case-insensitive" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      MockTelegramAPI.enqueue_message(11114, "/FOLLOWUP UPPERCASE MESSAGE")

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :followup
      assert job.text == "UPPERCASE MESSAGE"
    end

    test "queue override with only command and no text results in empty text" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      MockTelegramAPI.enqueue_message(11115, "/interrupt")

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :interrupt
      assert job.text == ""
    end

    test "queue override prefix is NOT stripped when allow_queue_override is false" do
      start_gateway_with_config(%{
        allow_queue_override: false,
        bindings: []
      })

      MockTelegramAPI.enqueue_message(11116, "/interrupt not actually an override")

      assert_receive {:job_captured, %Job{} = job}, 2000

      # queue_mode defaults to :collect (override not recognized)
      assert job.queue_mode == :collect
      # Text should remain unchanged since override was not applied
      assert job.text == "/interrupt not actually an override"
    end
  end

  # ============================================================================
  # 4. BindingResolver.resolve_queue_mode/1 unit tests
  # ============================================================================

  describe "BindingResolver.resolve_queue_mode/1" do
    test "returns nil when no binding exists" do
      start_gateway_with_config(%{bindings: []})

      scope = %ChatScope{transport: :telegram, chat_id: 99998}

      assert BindingResolver.resolve_queue_mode(scope) == nil
    end

    test "returns queue_mode from matching binding" do
      start_gateway_with_config(%{
        bindings: [
          %{transport: :telegram, chat_id: 88881, queue_mode: :interrupt}
        ]
      })

      scope = %ChatScope{transport: :telegram, chat_id: 88881}

      assert BindingResolver.resolve_queue_mode(scope) == :interrupt
    end

    test "returns nil when binding has no queue_mode set" do
      start_gateway_with_config(%{
        bindings: [
          %{transport: :telegram, chat_id: 77781, project: "test"}
        ]
      })

      scope = %ChatScope{transport: :telegram, chat_id: 77781}

      assert BindingResolver.resolve_queue_mode(scope) == nil
    end

    test "topic binding queue_mode takes precedence" do
      start_gateway_with_config(%{
        bindings: [
          %{transport: :telegram, chat_id: 66681, queue_mode: :collect},
          %{transport: :telegram, chat_id: 66681, topic_id: 500, queue_mode: :interrupt}
        ]
      })

      chat_scope = %ChatScope{transport: :telegram, chat_id: 66681}
      topic_scope = %ChatScope{transport: :telegram, chat_id: 66681, topic_id: 500}

      assert BindingResolver.resolve_queue_mode(chat_scope) == :collect
      assert BindingResolver.resolve_queue_mode(topic_scope) == :interrupt
    end
  end

  # ============================================================================
  # 5. End-to-end flow verification
  # ============================================================================

  describe "end-to-end flow" do
    test "message flows through transport -> job with correct queue_mode" do
      start_gateway_with_config(%{
        bindings: [
          %{transport: :telegram, chat_id: 12121, queue_mode: :followup, project: "test_proj"}
        ]
      })

      # Simulate a real Telegram update flow
      MockTelegramAPI.enqueue_message(12121, "end to end test")

      # Verify job is captured with all expected fields
      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :followup
      assert job.scope.transport == :telegram
      assert job.scope.chat_id == 12121
      assert job.text == "end to end test"
    end

    test "messages with different bindings get correct queue_modes" do
      start_gateway_with_config(%{
        bindings: [
          %{transport: :telegram, chat_id: 1001, queue_mode: :collect},
          %{transport: :telegram, chat_id: 1002, queue_mode: :followup},
          %{transport: :telegram, chat_id: 1003, queue_mode: :interrupt}
        ]
      })

      MockTelegramAPI.enqueue_message(1001, "collect message")

      assert_receive {:job_captured, %Job{} = job1}, 2000
      assert job1.scope.chat_id == 1001
      assert job1.queue_mode == :collect

      MockTelegramAPI.enqueue_message(1002, "followup message")

      assert_receive {:job_captured, %Job{} = job2}, 2000
      assert job2.scope.chat_id == 1002
      assert job2.queue_mode == :followup

      MockTelegramAPI.enqueue_message(1003, "interrupt message")

      assert_receive {:job_captured, %Job{} = job3}, 2000
      assert job3.scope.chat_id == 1003
      assert job3.queue_mode == :interrupt
    end
  end

  # ============================================================================
  # 6. Transport-level queue_mode parsing (direct unit tests)
  # ============================================================================

  describe "Transport.parse_queue_override (via transport)" do
    @doc """
    These tests verify the transport correctly parses queue override commands
    by checking jobs created with different commands.
    """

    test "/steer is parsed when allow_queue_override is true (converted to followup by ThreadWorker)" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      # The job arrives with :followup because ThreadWorker converts :steer
      # when there's no active run
      MockTelegramAPI.enqueue_message(66666, "/steer urgent")

      assert_receive {:job_captured, %Job{} = job}, 2000

      # :steer was parsed by transport but converted to :followup by ThreadWorker
      assert job.queue_mode == :followup
    end

    test "/STEER uppercase is also parsed (case insensitive)" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      MockTelegramAPI.enqueue_message(77777, "/STEER uppercase")

      assert_receive {:job_captured, %Job{} = job}, 2000

      # :steer was parsed and converted to :followup
      assert job.queue_mode == :followup
    end

    test "/INTERRUPT uppercase works" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      MockTelegramAPI.enqueue_message(88888, "/INTERRUPT stop!")

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :interrupt
    end

    test "/FOLLOWUP uppercase works" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      MockTelegramAPI.enqueue_message(99991, "/FOLLOWUP add more")

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :followup
    end
  end
end
