defmodule LemonGateway.Telegram.QueueModeIntegrationTest do
  alias Elixir.LemonGateway, as: LemonGateway

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

  alias Elixir.LemonGateway.Types.{ChatScope, Job, ResumeToken}
  alias Elixir.LemonGateway.{Config, BindingResolver}
  alias LemonChannels.BindingResolver, as: ChannelsBindingResolver
  alias LemonChannels.Types.ChatScope, as: ChannelsChatScope

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
        notify_pid = state.notify_pid
        if is_pid(notify_pid), do: send(notify_pid, {:telegram_get_updates, updates})
        new_state = %{state | pending_updates: []}
        {{:ok, %{"ok" => true, "result" => updates}}, new_state}
      end)
    end

    def send_message(_token, chat_id, text, reply_to_or_opts \\ nil, parse_mode \\ nil) do
      record({:send_message, chat_id, text, reply_to_or_opts, parse_mode})
      msg_id = System.unique_integer([:positive])
      {:ok, %{"ok" => true, "result" => %{"message_id" => msg_id}}}
    end

    def edit_message_text(_token, chat_id, message_id, text, _parse_mode \\ nil) do
      record({:edit_message, chat_id, message_id, text})
      {:ok, %{"ok" => true}}
    end

    def set_message_reaction(_token, chat_id, message_id, emoji, _opts \\ %{}) do
      record({:set_message_reaction, chat_id, message_id, emoji})
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
    @behaviour Elixir.LemonGateway.Engine

    use Agent

    alias Elixir.LemonGateway.Types.{Job, ResumeToken}
    alias Elixir.LemonGateway.Event

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

    def format_resume(%{value: v}) when is_binary(v), do: "capture resume #{v}"

    @impl true
    def extract_resume(text) when is_binary(text) do
      # Minimal resume support for testing Telegram /resume flows.
      case Regex.run(~r/\bcapture\s+resume\s+([^\s]+)/i, text) do
        [_, token] -> %ResumeToken{engine: id(), value: token}
        _ -> nil
      end
    end

    def extract_resume(_), do: nil

    @impl true
    def is_resume_line(line) when is_binary(line) do
      Regex.match?(~r/^\s*capture\s+resume\s+[^\s]+/i, line)
    end

    def is_resume_line(_), do: false

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

  # Runtime now resolves default Telegram runs through "lemon". Delegate that
  # engine id to the same capture engine so existing queue-mode assertions stay stable.
  defmodule LemonJobCapturingEngine do
    @behaviour Elixir.LemonGateway.Engine

    alias Elixir.LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "lemon"

    @impl true
    def format_resume(%ResumeToken{value: v}), do: "capture resume #{v}"

    def format_resume(%{value: v}) when is_binary(v), do: "capture resume #{v}"

    @impl true
    def extract_resume(text), do: JobCapturingEngine.extract_resume(text)

    @impl true
    def is_resume_line(line), do: JobCapturingEngine.is_resume_line(line)

    @impl true
    def supports_steer?, do: JobCapturingEngine.supports_steer?()

    @impl true
    def start_run(%Job{} = job, opts, sink_pid),
      do: JobCapturingEngine.start_run(job, opts, sink_pid)

    @impl true
    def cancel(state), do: JobCapturingEngine.cancel(state)
  end

  setup do
    # Stop the app to reset state
    _ = Application.stop(:lemon_gateway)
    _ = Application.stop(:lemon_router)
    _ = Application.stop(:lemon_channels)
    _ = Application.stop(:lemon_control_plane)
    _ = Application.stop(:lemon_automation)
    _ = Application.stop(:lemon_core)

    # Clean up any existing agents
    Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.stop()
    JobCapturingEngine.stop()

    # Start our mock agents
    {:ok, _} =
      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.start_link(
        notify_pid: self()
      )

    {:ok, _} = JobCapturingEngine.start_link(notify_pid: self())

    on_exit(fn ->
      _ = Application.stop(:lemon_channels)
      _ = Application.stop(:lemon_router)
      _ = Application.stop(:lemon_gateway)
      _ = Application.stop(:lemon_control_plane)
      _ = Application.stop(:lemon_automation)
      _ = Application.stop(:lemon_core)

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.stop()
      JobCapturingEngine.stop()
      Application.delete_env(:lemon_gateway, Elixir.LemonGateway.Config)
      Application.delete_env(:lemon_core, LemonCore.Store)
      Application.delete_env(:lemon_gateway, :config_path)
      Application.delete_env(:lemon_gateway, :telegram)
      Application.delete_env(:lemon_gateway, :transports)
      Application.delete_env(:lemon_gateway, :engines)
      Application.delete_env(:lemon_channels, :gateway)
      Application.delete_env(:lemon_channels, :telegram)
    end)

    :ok
  end

  defp start_gateway_with_config(config_overrides) do
    # Stop the app first to ensure fresh config is loaded
    _ = Application.stop(:lemon_gateway)
    _ = Application.stop(:lemon_router)
    _ = Application.stop(:lemon_channels)
    _ = Application.stop(:lemon_control_plane)
    _ = Application.stop(:lemon_automation)
    _ = Application.stop(:lemon_core)

    # Isolate Telegram poller file locks from any locally running gateway process (and from other tests).
    lock_dir =
      Path.join(System.tmp_dir!(), "lemon_test_locks_#{System.unique_integer([:positive])}")

    System.put_env("LEMON_LOCK_DIR", lock_dir)

    base_config = %{
      max_concurrent_runs: 10,
      default_engine: "lemon",
      enable_telegram: true,
      bindings: [],
      telegram: %{
        bot_token: "test_token",
        poll_interval_ms: 50,
        dedupe_ttl_ms: 60_000,
        debounce_ms: 10,
        allowed_chat_ids: nil,
        deny_unbound_chats: false,
        allow_queue_override: config_overrides[:allow_queue_override] || false
      }
    }

    config =
      base_config
      |> Map.merge(config_overrides)
      # Keep allow_queue_override under the telegram config, even if callers pass it at top-level.
      |> Map.update(:telegram, %{}, fn tg ->
        base_config.telegram
        |> Map.merge(tg || %{})
        |> Map.put(:allow_queue_override, config_overrides[:allow_queue_override] || false)
      end)

    Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
    Application.put_env(:lemon_gateway, Config, config)
    # Avoid leaking state across tests via the default JsonlBackend (config/config.exs).
    Application.put_env(:lemon_core, LemonCore.Store, backend: LemonCore.Store.EtsBackend)

    Application.put_env(:lemon_gateway, :engines, [
      LemonJobCapturingEngine,
      JobCapturingEngine,
      Elixir.LemonGateway.Engines.Echo
    ])

    Application.put_env(:lemon_gateway, :telegram, %{
      api_mod: Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI,
      # The adapter transport merges these into TOML-backed config (used in tests).
      poll_interval_ms: 50
    })

    Application.put_env(:lemon_channels, :gateway, config)

    Application.put_env(:lemon_channels, :telegram, %{
      api_mod: Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI,
      poll_interval_ms: config.telegram.poll_interval_ms
    })

    Application.put_env(:lemon_channels, :engines, [
      LemonJobCapturingEngine,
      JobCapturingEngine,
      Elixir.LemonGateway.Engines.Echo
    ])

    assert Application.get_env(:lemon_gateway, :telegram)[:api_mod] ==
             Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    {:ok, _} = Application.ensure_all_started(:lemon_router)

    :ok =
      LemonCore.RouterBridge.configure(
        router: LemonRouter.Router,
        run_orchestrator: LemonRouter.RunOrchestrator
      )

    {:ok, _} = Application.ensure_all_started(:lemon_channels)

    # Ensure the channels-based Telegram poller is actually running and using our mock API.
    poller_pid =
      wait_for_pid(LemonChannels.Adapters.Telegram.Transport, 5_000) ||
        Process.whereis(LemonChannels.Adapters.Telegram.Transport)

    assert is_pid(poller_pid)

    poller_state = :sys.get_state(LemonChannels.Adapters.Telegram.Transport)

    assert poller_state.api_mod ==
             Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI

    # Sanity-check engine wiring so `JobCapturingEngine` can actually receive jobs.
    assert Elixir.LemonGateway.EngineRegistry.get_engine("lemon") == LemonJobCapturingEngine
    assert is_pid(Process.whereis(JobCapturingEngine))
    assert Elixir.LemonGateway.EngineRegistry.get_engine("capture") == JobCapturingEngine
  end

  defp wait_for_pid(name, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_pid(name, deadline)
  end

  defp do_wait_for_pid(name, deadline_ms) do
    case Process.whereis(name) do
      pid when is_pid(pid) ->
        pid

      _ ->
        now = System.monotonic_time(:millisecond)

        if now >= deadline_ms do
          nil
        else
          Process.sleep(10)
          do_wait_for_pid(name, deadline_ms)
        end
    end
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
      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        12345,
        "test message"
      )

      # Wait for job to be captured
      assert_receive {:job_captured, %Job{} = job}, 2000

      # Verify queue_mode from binding
      assert job.queue_mode == :followup
      assert job.meta.chat_id == 12345
      assert job.prompt == "test message"
    end

    test "job gets queue_mode: :interrupt from binding" do
      start_gateway_with_config(%{
        bindings: [
          %{transport: :telegram, chat_id: 33333, queue_mode: :interrupt}
        ]
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        33333,
        "interrupt test"
      )

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
      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        44444,
        "topic message",
        topic_id: 100
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :followup
      assert job.meta.topic_id == 100
    end

    test "chat without topic falls back to chat binding queue_mode" do
      start_gateway_with_config(%{
        bindings: [
          %{transport: :telegram, chat_id: 55555, queue_mode: :interrupt},
          %{transport: :telegram, chat_id: 55555, topic_id: 200, queue_mode: :followup}
        ]
      })

      # Message without topic should get chat binding queue_mode
      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        55555,
        "chat message"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :interrupt
      assert job.meta.topic_id == nil
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

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        99999,
        "no binding message"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :collect
    end

    test "job defaults to queue_mode: :collect when binding has no queue_mode" do
      start_gateway_with_config(%{
        bindings: [
          %{transport: :telegram, chat_id: 88888, project: "some_project"}
        ]
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        88888,
        "binding without queue_mode"
      )

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

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        22221,
        "/followup add this to the previous"
      )

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

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        33331,
        "/interrupt stop everything!"
      )

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
      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        44441,
        "/interrupt this should not interrupt"
      )

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
      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        55551,
        "/interrupt urgent!"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :interrupt
    end

    test "queue override with leading whitespace" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        77771,
        "  /followup with spaces"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :followup
    end

    test "queue override requires boundary (no match for /steerable)" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        11110,
        "/steerable should not override"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      # Not treated as a queue override
      assert job.queue_mode == :collect
      assert job.prompt == "/steerable should not override"
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
      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        11111,
        "/steer please do this urgently"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      # After ThreadWorker processing, :steer becomes :followup (no active run)
      assert job.queue_mode == :followup
      # Queue override prefix is stripped from the text
      assert job.prompt == "please do this urgently"
    end

    test "queue override stripping preserves engine routing on subsequent /engine" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        11117,
        "/steer /lemon hello"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      # /steer override applied, and subsequent /lemon routing is preserved.
      assert job.queue_mode == :followup
      assert job.engine_id == "lemon"
      assert job.prompt == "hello"
    end

    test "/followup prefix is stripped from job.prompt" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        11112,
        "/followup add this context"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :followup
      assert job.prompt == "add this context"
    end

    test "/interrupt prefix is stripped from job.prompt" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        11113,
        "/interrupt stop everything now"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :interrupt
      assert job.prompt == "stop everything now"
    end

    test "queue override prefix stripping is case-insensitive" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        11114,
        "/FOLLOWUP UPPERCASE MESSAGE"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :followup
      assert job.prompt == "UPPERCASE MESSAGE"
    end

    test "queue override with only command and no text results in empty text" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        11115,
        "/interrupt"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :interrupt
      assert job.prompt == ""
    end

    test "queue override prefix is NOT stripped when allow_queue_override is false" do
      start_gateway_with_config(%{
        allow_queue_override: false,
        bindings: []
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        11116,
        "/interrupt not actually an override"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      # queue_mode defaults to :collect (override not recognized)
      assert job.queue_mode == :collect
      # Text should remain unchanged since override was not applied
      assert job.prompt == "/interrupt not actually an override"
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
      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        12121,
        "end to end test"
      )

      # Verify job is captured with all expected fields
      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :followup
      assert job.meta.channel_id == "telegram"
      assert job.meta.chat_id == 12121
      assert job.prompt == "end to end test"
    end

    test "messages with different bindings get correct queue_modes" do
      start_gateway_with_config(%{
        bindings: [
          %{transport: :telegram, chat_id: 1001, queue_mode: :collect},
          %{transport: :telegram, chat_id: 1002, queue_mode: :followup},
          %{transport: :telegram, chat_id: 1003, queue_mode: :interrupt}
        ]
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        1001,
        "collect message"
      )

      assert_receive {:job_captured, %Job{} = job1}, 2000
      assert job1.meta.chat_id == 1001
      assert job1.queue_mode == :collect

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        1002,
        "followup message"
      )

      assert_receive {:job_captured, %Job{} = job2}, 2000
      assert job2.meta.chat_id == 1002
      assert job2.queue_mode == :followup

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        1003,
        "interrupt message"
      )

      assert_receive {:job_captured, %Job{} = job3}, 2000
      assert job3.meta.chat_id == 1003
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
      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        66666,
        "/steer urgent"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      # :steer was parsed by transport but converted to :followup by ThreadWorker
      assert job.queue_mode == :followup
    end

    test "/STEER uppercase is also parsed (case insensitive)" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        77777,
        "/STEER uppercase"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      # :steer was parsed and converted to :followup
      assert job.queue_mode == :followup
    end

    test "/INTERRUPT uppercase works" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        88888,
        "/INTERRUPT stop!"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :interrupt
    end

    test "/FOLLOWUP uppercase works" do
      start_gateway_with_config(%{
        allow_queue_override: true,
        bindings: []
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        99991,
        "/FOLLOWUP add more"
      )

      assert_receive {:job_captured, %Job{} = job}, 2000

      assert job.queue_mode == :followup
    end
  end

  describe "telegram transport parity (channels)" do
    test "debounces and joins consecutive non-command messages into one job" do
      chat_id = 52_345

      start_gateway_with_config(%{
        telegram: %{
          bot_token: "test_token",
          poll_interval_ms: 50,
          dedupe_ttl_ms: 60_000,
          debounce_ms: 30
        }
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "part one",
        message_id: 111
      )

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "part two",
        message_id: 112
      )

      assert_receive {:job_captured, %Job{} = job}, 5000
      assert job.prompt == "part one\n\npart two"
      assert job.meta.user_msg_id == 112
      # progress_msg_id is now the user_msg_id (reaction is set on user's message)
      assert job.meta[:progress_msg_id] == 112
    end

    test "allowed_chat_ids drops messages from disallowed chats" do
      start_gateway_with_config(%{
        telegram: %{
          bot_token: "test_token",
          poll_interval_ms: 50,
          dedupe_ttl_ms: 60_000,
          debounce_ms: 10,
          allowed_chat_ids: [12345]
        }
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        99999,
        "should be dropped"
      )

      refute_receive {:job_captured, %Job{}}, 300
      assert Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.calls() == []
    end

    test "deny_unbound_chats drops messages when no binding exists" do
      start_gateway_with_config(%{
        telegram: %{
          bot_token: "test_token",
          poll_interval_ms: 50,
          dedupe_ttl_ms: 60_000,
          debounce_ms: 10,
          deny_unbound_chats: true
        },
        bindings: []
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        12345,
        "should be dropped (unbound)"
      )

      refute_receive {:job_captured, %Job{}}, 300
      assert Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.calls() == []
    end

    test "deny_unbound_chats allows messages when a chat binding exists" do
      chat_id = 52_347

      start_gateway_with_config(%{
        telegram: %{
          bot_token: "test_token",
          poll_interval_ms: 50,
          dedupe_ttl_ms: 60_000,
          debounce_ms: 10,
          deny_unbound_chats: true
        },
        bindings: [
          %{transport: :telegram, chat_id: chat_id, queue_mode: :collect}
        ]
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "allowed (bound)"
      )

      scope = %ChannelsChatScope{transport: :telegram, chat_id: chat_id}
      assert ChannelsBindingResolver.resolve_binding(scope) != nil

      assert_receive {:job_captured, %Job{} = job}, 5000
      assert job.prompt == "allowed (bound)"
    end

    test "/new records memories (when history exists) and then clears auto-resume chat state" do
      chat_id = 52_348

      start_gateway_with_config(%{})

      session_key = telegram_session_key(chat_id)

      Elixir.LemonGateway.Store.put_chat_state(session_key, %{
        last_engine: "capture",
        last_resume_token: "resume_1",
        updated_at: System.system_time(:millisecond)
      })

      assert Elixir.LemonGateway.Store.get_chat_state(session_key) != nil

      # Seed minimal run history so /new has something to reflect on.
      Elixir.LemonGateway.Store.finalize_run("seed_run_1", %{
        run_id: "seed_run_1",
        session_key: session_key,
        prompt: "Earlier prompt",
        completed: %{ok: true, answer: "Earlier answer"},
        meta: %{origin: :telegram}
      })

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "/new",
        message_id: 500
      )

      {new_session_msg, _opts} = assert_receive_new_session_message(chat_id, 500)

      assert String.contains?(new_session_msg, "Model:")
      assert String.contains?(new_session_msg, "Provider:")
      assert String.contains?(new_session_msg, "CWD:")

      assert_receive {:job_captured, %Job{} = job}, 2000
      assert is_binary(job.prompt)
      assert String.contains?(job.prompt, "Transcript")

      assert eventually(fn -> Elixir.LemonGateway.Store.get_chat_state(session_key) == nil end)
    end

    test "/new <path> registers a dynamic project and uses it as cwd for subsequent jobs" do
      chat_id = 52_349

      start_gateway_with_config(%{})

      scope = %ChannelsChatScope{transport: :telegram, chat_id: chat_id, topic_id: nil}

      base =
        Path.join(System.tmp_dir!(), "lemon_new_project_#{System.unique_integer([:positive])}")

      root = Path.join(base, "lemon")
      File.mkdir_p!(root)

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "/new #{root}",
        message_id: 801
      )

      refute_receive {:job_captured, %Job{}}, 300

      assert eventually(fn -> ChannelsBindingResolver.resolve_cwd(scope) == root end)

      assert eventually(fn ->
               dyn = LemonCore.Store.get(:channels_projects_dynamic, "lemon")
               (dyn && (dyn[:root] || dyn["root"])) == root
             end)

      assert eventually(fn ->
               LemonCore.Store.get(:channels_project_overrides, scope) == "lemon"
             end)

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "hi",
        message_id: 802
      )

      assert_receive {:job_captured, %Job{} = job}, 2000
      assert job.cwd == root
    end

    test "/new <relative path> resolves relative to current bound project cwd" do
      chat_id = 52_350

      start_gateway_with_config(%{})

      scope = %ChannelsChatScope{transport: :telegram, chat_id: chat_id, topic_id: nil}

      base =
        Path.join(
          System.tmp_dir!(),
          "lemon_new_project_rel_#{System.unique_integer([:positive])}"
        )

      root1 = Path.join(base, "one")
      root2 = Path.join(base, "two")
      File.mkdir_p!(root1)
      File.mkdir_p!(root2)

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "/new #{root1}",
        message_id: 811
      )

      refute_receive {:job_captured, %Job{}}, 300
      assert eventually(fn -> ChannelsBindingResolver.resolve_cwd(scope) == root1 end)

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "/new ../two",
        message_id: 812
      )

      refute_receive {:job_captured, %Job{}}, 300
      assert eventually(fn -> ChannelsBindingResolver.resolve_cwd(scope) == root2 end)

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "yo",
        message_id: 813
      )

      assert_receive {:job_captured, %Job{} = job}, 2000
      assert job.cwd == root2
    end

    test "/new <project_id> selects a configured gateway project" do
      chat_id = 52_351

      base =
        Path.join(
          System.tmp_dir!(),
          "lemon_new_project_cfg_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(base)

      start_gateway_with_config(%{
        projects: %{
          "myrepo" => %{root: base, default_engine: nil}
        }
      })

      scope = %ChannelsChatScope{transport: :telegram, chat_id: chat_id, topic_id: nil}

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "/new myrepo",
        message_id: 821
      )

      refute_receive {:job_captured, %Job{}}, 300
      assert eventually(fn -> ChannelsBindingResolver.resolve_cwd(scope) == base end)

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "ok",
        message_id: 822
      )

      assert_receive {:job_captured, %Job{} = job}, 2000
      assert job.cwd == base
    end

    test "/resume lists prior sessions and /resume <n> selects one for subsequent messages" do
      chat_id = 52_352

      start_gateway_with_config(%{})

      session_key = telegram_session_key(chat_id)

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "first",
        message_id: 601
      )

      assert_receive {:job_captured, %Job{} = _job1}, 2000

      assert eventually(fn -> Elixir.LemonGateway.Store.get_chat_state(session_key) != nil end)
      state1 = Elixir.LemonGateway.Store.get_chat_state(session_key)

      token1 =
        state1.last_resume_token || state1[:last_resume_token] || state1["last_resume_token"]

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "/new",
        message_id: 602
      )

      refute_receive {:job_captured, %Job{}}, 300

      {new_session_msg, _opts} = assert_receive_new_session_message(chat_id, 602)

      assert String.contains?(new_session_msg, "Model:")
      assert String.contains?(new_session_msg, "Provider:")
      assert String.contains?(new_session_msg, "CWD:")

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "second",
        message_id: 603
      )

      assert_receive {:job_captured, %Job{} = _job2}, 2000

      assert eventually(fn ->
               st = Elixir.LemonGateway.Store.get_chat_state(session_key)

               st != nil and
                 (st.last_resume_token || st[:last_resume_token] || st["last_resume_token"]) !=
                   token1
             end)

      state2 = Elixir.LemonGateway.Store.get_chat_state(session_key)

      token2 =
        state2.last_resume_token || state2[:last_resume_token] || state2["last_resume_token"]

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "/resume",
        message_id: 604
      )

      refute_receive {:job_captured, %Job{}}, 300

      {text, opts} =
        assert_receive_matching_system_message(chat_id, 604, fn text ->
          String.contains?(text, "Available sessions")
        end)

      assert reply_to_from_opts(opts) == 604
      assert String.contains?(text, token2)
      assert String.contains?(text, token1)

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "/resume 2",
        message_id: 605
      )

      refute_receive {:job_captured, %Job{}}, 300

      {text2, opts2} =
        assert_receive_matching_system_message(chat_id, 605, fn text ->
          String.contains?(text, "Resuming session")
        end)

      assert reply_to_from_opts(opts2) == 605
      assert String.contains?(text2, token1)

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "continue",
        message_id: 606
      )

      assert_receive {:job_captured, %Job{} = job3}, 2000

      cond do
        match?(%ResumeToken{}, job3.resume) ->
          assert job3.resume.engine == "capture"

        is_map(job3.resume) ->
          assert (Map.get(job3.resume, :engine) || Map.get(job3.resume, "engine")) == "capture"

        true ->
          assert is_nil(job3.resume)
      end
    end

    test "replying to a message from an older session switches and resumes that session" do
      chat_id = 52_353

      start_gateway_with_config(%{})

      session_key = telegram_session_key(chat_id)

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "first",
        message_id: 701
      )

      assert_receive {:job_captured, %Job{} = _job1}, 2000

      assert eventually(fn -> Elixir.LemonGateway.Store.get_chat_state(session_key) != nil end)
      state1 = Elixir.LemonGateway.Store.get_chat_state(session_key)

      token1 =
        state1.last_resume_token || state1[:last_resume_token] || state1["last_resume_token"]

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "/new",
        message_id: 702
      )

      refute_receive {:job_captured, %Job{}}, 300

      {new_session_msg, _opts} = assert_receive_new_session_message(chat_id, 702)

      assert String.contains?(new_session_msg, "Model:")
      assert String.contains?(new_session_msg, "Provider:")
      assert String.contains?(new_session_msg, "CWD:")

      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "second",
        message_id: 703
      )

      assert_receive {:job_captured, %Job{} = _job2}, 2000

      # Reply to the old user message ID (701); reply text is empty, so the transport must
      # use the persisted message->resume index.
      Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.enqueue_message(
        chat_id,
        "back to first",
        message_id: 704,
        reply_to: 701
      )

      assert_receive {:job_captured, %Job{} = job3}, 2000

      cond do
        match?(%ResumeToken{}, job3.resume) ->
          assert job3.resume.engine == "capture"

        is_map(job3.resume) ->
          assert (Map.get(job3.resume, :engine) || Map.get(job3.resume, "engine")) == "capture"

        true ->
          assert is_nil(job3.resume)
      end

      # Reply-based switching is intentionally silent (no extra "Resuming session" chat noise).
      refute Enum.any?(
               Elixir.LemonGateway.Telegram.QueueModeIntegrationTest.MockTelegramAPI.calls(),
               fn
                 {:send_message, ^chat_id, text, _opts, _parse_mode} ->
                   String.contains?(text, "Resuming session") and String.contains?(text, token1)

                 _ ->
                   false
               end
             )
    end
  end

  defp telegram_session_key(chat_id, topic_id \\ nil) do
    opts = %{
      agent_id: "default",
      channel_id: "telegram",
      account_id: "default",
      peer_kind: "dm",
      peer_id: Integer.to_string(chat_id)
    }

    opts =
      if is_nil(topic_id),
        do: opts,
        else: Map.put(opts, :thread_id, Integer.to_string(topic_id))

    LemonCore.SessionKey.channel_peer(opts)
  end

  defp reply_to_from_opts(opts) when is_map(opts) do
    opts[:reply_to_message_id] || opts["reply_to_message_id"]
  end

  defp reply_to_from_opts(opts) when is_list(opts) do
    Keyword.get(opts, :reply_to_message_id)
  end

  defp reply_to_from_opts(_opts), do: nil

  defp assert_receive_new_session_message(chat_id, reply_to_id, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_receive_new_session_message(chat_id, reply_to_id, deadline)
  end

  defp do_assert_receive_new_session_message(chat_id, reply_to_id, deadline_ms) do
    remaining = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    assert_receive {:telegram_api_call, {:send_message, ^chat_id, text, opts, _parse_mode}},
                   remaining

    if String.starts_with?(text, "Started a new session.") and
         reply_to_from_opts(opts) == reply_to_id do
      {text, opts}
    else
      do_assert_receive_new_session_message(chat_id, reply_to_id, deadline_ms)
    end
  end

  defp assert_receive_matching_system_message(
         chat_id,
         reply_to_id,
         predicate,
         timeout_ms \\ 2_000
       )
       when is_function(predicate, 1) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_assert_receive_matching_system_message(chat_id, reply_to_id, predicate, deadline)
  end

  defp do_assert_receive_matching_system_message(chat_id, reply_to_id, predicate, deadline_ms) do
    remaining = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    assert_receive {:telegram_api_call, {:send_message, ^chat_id, text, opts, _parse_mode}},
                   remaining

    if reply_to_from_opts(opts) == reply_to_id and predicate.(text) do
      {text, opts}
    else
      do_assert_receive_matching_system_message(chat_id, reply_to_id, predicate, deadline_ms)
    end
  end

  defp eventually(fun, attempts_left \\ 500)

  defp eventually(fun, 0) when is_function(fun, 0) do
    fun.()
  end

  defp eventually(fun, attempts_left) when is_function(fun, 0) and attempts_left > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts_left - 1)
    end
  end
end
