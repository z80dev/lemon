defmodule LemonGateway.Telegram.MessageBufferingAndDedupeIntegrationTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Config
  alias LemonGateway.Event
  alias LemonGateway.TestSupport.MockTelegramAPI
  alias LemonGateway.Types.{Job, ResumeToken}

  defmodule CapturingEngine do
    @behaviour LemonGateway.Engine

    use Agent

    alias LemonGateway.Event
    alias LemonGateway.Types.{Job, ResumeToken}

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

    def set_notify_pid(pid) when is_pid(pid) do
      Agent.update(__MODULE__, &%{&1 | notify_pid: pid})
    end

    def jobs do
      Agent.get(__MODULE__, &Enum.reverse(&1.jobs))
    end

    @impl true
    def id, do: "lemon"

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

      Agent.update(__MODULE__, fn state ->
        notify_pid = state.notify_pid
        if is_pid(notify_pid), do: send(notify_pid, {:job_captured, job})
        %{state | jobs: [job | state.jobs]}
      end)

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
    _ = Application.stop(:lemon_gateway)
    _ = Application.stop(:lemon_router)
    _ = Application.stop(:lemon_channels)
    _ = Application.stop(:lemon_control_plane)
    _ = Application.stop(:lemon_automation)
    _ = Application.stop(:lemon_core)

    MockTelegramAPI.reset!(notify_pid: self())
    CapturingEngine.stop()
    {:ok, _} = CapturingEngine.start_link(notify_pid: self())

    on_exit(fn ->
      _ = Application.stop(:lemon_channels)
      _ = Application.stop(:lemon_router)
      _ = Application.stop(:lemon_gateway)
      _ = Application.stop(:lemon_control_plane)
      _ = Application.stop(:lemon_automation)
      _ = Application.stop(:lemon_core)

      CapturingEngine.stop()
      MockTelegramAPI.stop()
      Application.delete_env(:lemon_gateway, LemonGateway.Config)
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

  defp start_system!(overrides) do
    lock_dir =
      Path.join(System.tmp_dir!(), "lemon_test_locks_#{System.unique_integer([:positive])}")

    System.put_env("LEMON_LOCK_DIR", lock_dir)

    base_config = %{
      max_concurrent_runs: 10,
      default_engine: "lemon",
      enable_telegram: true,
      require_engine_lock: false,
      bindings: [],
      telegram: %{
        bot_token: "test_token",
        poll_interval_ms: 25,
        dedupe_ttl_ms: 60_000,
        debounce_ms: 0,
        allowed_chat_ids: nil,
        deny_unbound_chats: false,
        allow_queue_override: false
      }
    }

    config =
      base_config
      |> Map.merge(overrides)
      |> Map.update(:telegram, %{}, fn tg -> Map.merge(base_config.telegram, tg || %{}) end)

    Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
    Application.put_env(:lemon_gateway, Config, config)

    Application.put_env(:lemon_core, LemonCore.Store, backend: LemonCore.Store.EtsBackend)

    Application.put_env(:lemon_gateway, :engines, [
      CapturingEngine,
      LemonGateway.Engines.Echo
    ])

    Application.put_env(:lemon_gateway, :telegram, %{
      api_mod: MockTelegramAPI,
      poll_interval_ms: config.telegram.poll_interval_ms
    })

    Application.put_env(:lemon_channels, :gateway, config)

    Application.put_env(:lemon_channels, :telegram, %{
      api_mod: MockTelegramAPI,
      poll_interval_ms: config.telegram.poll_interval_ms
    })

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    {:ok, _} = Application.ensure_all_started(:lemon_router)
    :ok =
      LemonCore.RouterBridge.configure(
        router: LemonRouter.Router,
        run_orchestrator: LemonRouter.RunOrchestrator
      )

    {:ok, _} = Application.ensure_all_started(:lemon_channels)

    poller_pid =
      wait_for_pid(LemonChannels.Adapters.Telegram.Transport, 5_000) ||
        Process.whereis(LemonChannels.Adapters.Telegram.Transport)

    assert is_pid(poller_pid)

    poller_state = :sys.get_state(LemonChannels.Adapters.Telegram.Transport)
    assert poller_state.api_mod == MockTelegramAPI
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
        if System.monotonic_time(:millisecond) >= deadline_ms do
          nil
        else
          Process.sleep(10)
          do_wait_for_pid(name, deadline_ms)
        end
    end
  end

  defp wait_until(fun, timeout_ms) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline_ms) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline_ms do
        {:error, :timeout}
      else
        Process.sleep(10)
        do_wait_until(fun, deadline_ms)
      end
    end
  end

  test "debounces and joins consecutive non-command messages into a single run" do
    start_system!(%{telegram: %{debounce_ms: 50}})

    chat_id = 10_001

    MockTelegramAPI.enqueue_message(chat_id, "hello", message_id: 1)
    MockTelegramAPI.enqueue_message(chat_id, "world", message_id: 2)

    assert_receive {:job_captured, %Job{} = job}, 2_000

    assert job.prompt == "hello\n\nworld"
    assert job.prompt == "hello\n\nworld"
    assert job.meta.user_msg_id == 2

    # Ensure we didn't accidentally submit a second run for the first message.
    refute_receive {:job_captured, %Job{}}, 200
  end

  test "dedupes repeated messages by (peer_id, message_id)" do
    start_system!(%{telegram: %{debounce_ms: 0}})

    chat_id = 10_002
    MockTelegramAPI.enqueue_message(chat_id, "ping", message_id: 42)
    MockTelegramAPI.enqueue_message(chat_id, "ping", message_id: 42)

    assert_receive {:job_captured, %Job{}}, 2_000
    refute_receive {:job_captured, %Job{}}, 300

    assert :ok ==
             wait_until(
               fn ->
                 calls = MockTelegramAPI.calls()

                 Enum.any?(calls, fn
                   {:send_message, ^chat_id, "captured", _opts, _pm} -> true
                   _ -> false
                 end)
               end,
               3_000
             )

    running_count =
      MockTelegramAPI.calls()
      |> Enum.count(fn
        {:send_message, ^chat_id, "Running…", _opts, _pm} -> true
        _ -> false
      end)

    assert running_count == 1
  end
end
