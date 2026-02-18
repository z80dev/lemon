defmodule LemonGateway.Telegram.ResumeFooterIntegrationTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Config
  alias LemonGateway.Event
  alias LemonGateway.TestSupport.MockTelegramAPI
  alias LemonGateway.Types.{Job, ResumeToken}

  defmodule SimpleEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Event
    alias LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "lemon"

    @impl true
    def format_resume(%ResumeToken{value: v}), do: "lemon resume #{v}"

    @impl true
    def extract_resume(_text), do: nil

    @impl true
    def is_resume_line(_line), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = _job, _opts, sink_pid) do
      run_ref = make_ref()
      resume = %ResumeToken{engine: id(), value: "tok_footer"}

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
  end

  setup do
    _ = Application.stop(:lemon_gateway)
    _ = Application.stop(:lemon_router)
    _ = Application.stop(:lemon_channels)
    _ = Application.stop(:lemon_control_plane)
    _ = Application.stop(:lemon_automation)
    _ = Application.stop(:lemon_core)

    MockTelegramAPI.reset!(notify_pid: self())

    on_exit(fn ->
      _ = Application.stop(:lemon_channels)
      _ = Application.stop(:lemon_router)
      _ = Application.stop(:lemon_gateway)
      _ = Application.stop(:lemon_control_plane)
      _ = Application.stop(:lemon_automation)
      _ = Application.stop(:lemon_core)

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

  defp start_system!(show_resume_line?) do
    lock_dir =
      Path.join(System.tmp_dir!(), "lemon_test_locks_#{System.unique_integer([:positive])}")

    System.put_env("LEMON_LOCK_DIR", lock_dir)

    Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")

    config = %{
      max_concurrent_runs: 10,
      default_engine: SimpleEngine.id(),
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
        allow_queue_override: false,
        show_resume_line: show_resume_line?
      }
    }

    Application.put_env(:lemon_gateway, Config, config)

    Application.put_env(:lemon_core, LemonCore.Store, backend: LemonCore.Store.EtsBackend)

    Application.put_env(:lemon_gateway, :engines, [
      SimpleEngine,
      LemonGateway.Engines.Echo
    ])

    Application.put_env(:lemon_gateway, :telegram, %{
      api_mod: MockTelegramAPI,
      poll_interval_ms: 25
    })

    Application.put_env(:lemon_channels, :gateway, config)

    Application.put_env(:lemon_channels, :telegram, %{
      api_mod: MockTelegramAPI,
      poll_interval_ms: 25
    })

    Application.put_env(:lemon_channels, :engines, [
      SimpleEngine,
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

  defp final_ok_message_text(chat_id) do
    MockTelegramAPI.calls()
    |> Enum.filter(fn
      {:send_message, ^chat_id, text, _opts, _pm} when is_binary(text) ->
        String.contains?(text, "ok")

      {:edit_message, ^chat_id, _message_id, text, _opts} when is_binary(text) ->
        String.contains?(text, "ok")

      _ ->
        false
    end)
    |> List.last()
    |> case do
      {:send_message, ^chat_id, text, _opts, _pm} -> text
      {:edit_message, ^chat_id, _message_id, text, _opts} -> text
      _ -> nil
    end
  end

  test "Telegram resume footer is omitted by default (show_resume_line: false)" do
    start_system!(false)
    chat_id = 82_001

    MockTelegramAPI.enqueue_message(chat_id, "hi", message_id: 1)

    assert :ok ==
             wait_until(
               fn -> is_binary(final_ok_message_text(chat_id)) end,
               5_000
             )

    text = final_ok_message_text(chat_id)
    assert String.trim(text) == "ok"
    refute String.contains?(text, "resume")
  end

  test "Telegram resume footer is appended when enabled (show_resume_line: true)" do
    start_system!(true)
    chat_id = 82_002

    MockTelegramAPI.enqueue_message(chat_id, "hi", message_id: 1)

    assert :ok ==
             wait_until(
               fn ->
                 case final_ok_message_text(chat_id) do
                   nil -> false
                   text -> String.contains?(text, "resume")
                 end
               end,
               5_000
             )

    text = final_ok_message_text(chat_id)
    assert String.contains?(text, "ok")
    assert String.contains?(text, "lemon")
    assert String.contains?(text, "resume")
    assert String.contains?(text, "tok_footer")
  end
end
