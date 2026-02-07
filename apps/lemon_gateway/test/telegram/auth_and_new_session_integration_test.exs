defmodule LemonGateway.Telegram.AuthAndNewSessionIntegrationTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Config
  alias LemonGateway.Event
  alias LemonGateway.TestSupport.MockTelegramAPI
  alias LemonGateway.Types.{Job, ResumeToken}

  defmodule CountingEngine do
    @behaviour LemonGateway.Engine

    use Agent

    alias LemonGateway.Event
    alias LemonGateway.Types.{Job, ResumeToken}

    def start_link(opts \\ []) do
      Agent.start_link(fn -> %{count: 0, notify_pid: opts[:notify_pid]} end, name: __MODULE__)
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> Agent.stop(pid, :normal, 100)
      end
    catch
      :exit, _ -> :ok
    end

    def count do
      Agent.get(__MODULE__, & &1.count)
    end

    @impl true
    def id, do: "count"

    @impl true
    def format_resume(%ResumeToken{value: v}), do: "count resume #{v}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = _job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = %ResumeToken{engine: id(), value: unique_id()}

      Agent.update(__MODULE__, fn state ->
        notify_pid = state.notify_pid
        if is_pid(notify_pid), do: send(notify_pid, {:engine_started, run_ref})
        %{state | count: state.count + 1}
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
    _ = Application.stop(:lemon_core)

    MockTelegramAPI.reset!(notify_pid: self())
    CountingEngine.stop()
    {:ok, _} = CountingEngine.start_link(notify_pid: self())

    on_exit(fn ->
      _ = Application.stop(:lemon_channels)
      _ = Application.stop(:lemon_router)
      _ = Application.stop(:lemon_gateway)
      _ = Application.stop(:lemon_control_plane)
      _ = Application.stop(:lemon_automation)
      _ = Application.stop(:lemon_core)

      CountingEngine.stop()
      MockTelegramAPI.stop()
      Application.delete_env(:lemon_gateway, LemonGateway.Config)
      Application.delete_env(:lemon_core, LemonCore.Store)
      Application.delete_env(:lemon_gateway, :config_path)
      Application.delete_env(:lemon_gateway, :telegram)
      Application.delete_env(:lemon_gateway, :transports)
      Application.delete_env(:lemon_gateway, :engines)
    end)

    :ok
  end

  defp start_system!(overrides \\ %{}) do
    lock_dir =
      Path.join(System.tmp_dir!(), "lemon_test_locks_#{System.unique_integer([:positive])}")

    System.put_env("LEMON_LOCK_DIR", lock_dir)

    base_config = %{
      max_concurrent_runs: 10,
      default_engine: "count",
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
      CountingEngine,
      LemonGateway.Engines.Echo
    ])

    Application.put_env(:lemon_gateway, :telegram, %{
      api_mod: MockTelegramAPI,
      poll_interval_ms: config.telegram.poll_interval_ms
    })

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    {:ok, _} = Application.ensure_all_started(:lemon_router)
    {:ok, _} = Application.ensure_all_started(:lemon_channels)

    assert is_pid(wait_for_pid(LemonChannels.Adapters.Telegram.Transport, 2_000))
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

  test "allowed_chat_ids blocks unauthorized chats (no progress, no run)" do
    start_system!(%{telegram: %{allowed_chat_ids: [123]}})

    MockTelegramAPI.enqueue_message(999, "hi", message_id: 1)

    # Poller should ignore the update: no outbound calls, no engine runs.
    Process.sleep(200)

    assert MockTelegramAPI.calls() == []
    assert CountingEngine.count() == 0
  end

  test "deny_unbound_chats blocks chats without bindings" do
    start_system!(%{telegram: %{deny_unbound_chats: true}, bindings: []})

    MockTelegramAPI.enqueue_message(555, "hi", message_id: 1)

    Process.sleep(250)

    assert MockTelegramAPI.calls() == []
    assert CountingEngine.count() == 0
  end

  test "deny_unbound_chats allows chats with a binding" do
    start_system!(%{
      telegram: %{deny_unbound_chats: true},
      bindings: [%{transport: :telegram, chat_id: 777}]
    })

    MockTelegramAPI.enqueue_message(777, "hi", message_id: 1)

    assert_receive {:engine_started, _run_ref}, 2_000

    # At least progress + final should be delivered.
    assert Enum.any?(MockTelegramAPI.calls(), fn
             {:send_message, 777, "Running…", _opts, _pm} -> true
             _ -> false
           end)

    assert CountingEngine.count() == 1
  end

  test "/new produces a system reply but does not start a run" do
    start_system!()

    chat_id = 888
    MockTelegramAPI.enqueue_message(chat_id, "/new", message_id: 10)

    Process.sleep(250)

    # No progress message for /new.
    refute Enum.any?(MockTelegramAPI.calls(), fn
             {:send_message, ^chat_id, "Running…", _opts, _pm} -> true
             _ -> false
           end)

    assert Enum.any?(MockTelegramAPI.calls(), fn
             {:send_message, ^chat_id, text, _opts, _pm} when is_binary(text) ->
               String.contains?(text, "Started a new session")

             _ ->
               false
           end)
  end
end
