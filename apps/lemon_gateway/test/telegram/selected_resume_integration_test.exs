defmodule LemonGateway.Telegram.SelectedResumeIntegrationTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Config
  alias LemonGateway.Event
  alias LemonGateway.TestSupport.MockTelegramAPI
  alias LemonGateway.Types.{Job, ResumeToken}

  defmodule LemonCaptureEngine do
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

    def jobs do
      Agent.get(__MODULE__, &Enum.reverse(&1.jobs))
    end

    @impl true
    def id, do: "lemon"

    @impl true
    def format_resume(%ResumeToken{value: v}), do: "lemon resume #{v}"

    def format_resume(%{value: v}) when is_binary(v), do: "lemon resume #{v}"

    @impl true
    def extract_resume(text) when is_binary(text) do
      case Regex.run(~r/`?lemon\s+resume\s+([a-zA-Z0-9_-]+)`?/i, text) do
        [_, token] -> %ResumeToken{engine: id(), value: token}
        _ -> nil
      end
    end

    def extract_resume(_), do: nil

    @impl true
    def is_resume_line(line) when is_binary(line) do
      Regex.match?(~r/^`?lemon\s+resume\s+[a-zA-Z0-9_-]+`?$/i, String.trim(line))
    end

    def is_resume_line(_), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = job.resume || %ResumeToken{engine: id(), value: unique_id()}

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
             %Event.Completed{engine: id(), resume: resume, ok: true, answer: "ok"}}
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
    LemonCaptureEngine.stop()
    {:ok, _} = LemonCaptureEngine.start_link(notify_pid: self())

    on_exit(fn ->
      _ = Application.stop(:lemon_channels)
      _ = Application.stop(:lemon_router)
      _ = Application.stop(:lemon_gateway)
      _ = Application.stop(:lemon_control_plane)
      _ = Application.stop(:lemon_automation)
      _ = Application.stop(:lemon_core)

      LemonCaptureEngine.stop()
      MockTelegramAPI.stop()
      Application.delete_env(:lemon_gateway, LemonGateway.Config)
      Application.delete_env(:lemon_core, LemonCore.Store)
      Application.delete_env(:lemon_gateway, :config_path)
      Application.delete_env(:lemon_gateway, :telegram)
      Application.delete_env(:lemon_gateway, :transports)
      Application.delete_env(:lemon_gateway, :engines)
      Application.delete_env(:lemon_channels, :gateway)
      Application.delete_env(:lemon_channels, :telegram)
      Application.delete_env(:lemon_channels, :engines)
    end)

    :ok
  end

  defp start_system! do
    lock_dir =
      Path.join(System.tmp_dir!(), "lemon_test_locks_#{System.unique_integer([:positive])}")

    System.put_env("LEMON_LOCK_DIR", lock_dir)

    Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")

    config = %{
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

    Application.put_env(:lemon_gateway, Config, config)

    Application.put_env(:lemon_core, LemonCore.Store, backend: LemonCore.Store.EtsBackend)

    Application.put_env(:lemon_gateway, :engines, [
      LemonCaptureEngine,
      LemonGateway.Engines.Echo
    ])

    Application.put_env(:lemon_gateway, :telegram, %{
      api_mod: MockTelegramAPI,
      poll_interval_ms: 25
    })

    Application.put_env(:lemon_channels, :gateway, config)

    Application.put_env(:lemon_channels, :telegram, %{
      api_mod: MockTelegramAPI,
      poll_interval_ms: config.telegram.poll_interval_ms
    })

    Application.put_env(:lemon_channels, :engines, [
      LemonCaptureEngine,
      LemonGateway.Engines.Echo
    ])

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

  test "selected resume token is applied to subsequent messages (without user typing it)" do
    start_system!()

    chat_id = 41_001
    tok = %LemonChannels.Types.ResumeToken{engine: "lemon", value: "tok123"}

    # Seed explicitly-selected resume session (transport reads this per chat/topic).
    :ok = LemonCore.Store.put(:telegram_selected_resume, {"default", chat_id, nil}, tok)

    MockTelegramAPI.enqueue_message(chat_id, "hi", message_id: 1)

    assert_receive {:job_captured, %Job{} = job}, 2_000

    assert job.resume.engine == "lemon"
    assert job.resume.value == "tok123"
    assert job.prompt == "hi"
  end

  test "explicit resume line in user message wins over selected resume" do
    start_system!()

    chat_id = 41_002
    tok = %LemonChannels.Types.ResumeToken{engine: "lemon", value: "selected"}
    :ok = LemonCore.Store.put(:telegram_selected_resume, {"default", chat_id, nil}, tok)

    MockTelegramAPI.enqueue_message(chat_id, "lemon resume explicit\nhello", message_id: 1)

    assert_receive {:job_captured, %Job{} = job}, 2_000

    assert job.resume.engine == "lemon"
    assert job.resume.value == "explicit"
    assert job.prompt == "hello"
  end
end
