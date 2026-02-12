defmodule LemonGateway.Telegram.ResumeByReplyMsgIndexIntegrationTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Config
  alias LemonGateway.Event
  alias LemonGateway.TestSupport.MockTelegramAPI
  alias LemonGateway.Types.{Job, ResumeToken}

  defmodule CaptureEngine do
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
    def id, do: "cap"

    @impl true
    def format_resume(%ResumeToken{value: v}), do: "cap resume #{v}"

    @impl true
    def extract_resume(text) when is_binary(text) do
      case Regex.run(~r/`?cap\s+resume\s+([a-zA-Z0-9_-]+)`?/i, text) do
        [_, token] -> %ResumeToken{engine: id(), value: token}
        _ -> nil
      end
    end

    def extract_resume(_), do: nil

    @impl true
    def is_resume_line(line) when is_binary(line) do
      Regex.match?(~r/^`?cap\s+resume\s+[a-zA-Z0-9_-]+`?$/i, String.trim(line))
    end

    def is_resume_line(_), do: false

    @impl true
    def supports_steer?, do: false

    @impl true
    def start_run(%Job{} = job, _opts, sink_pid) do
      run_ref = make_ref()

      resume =
        job.resume ||
          %ResumeToken{engine: id(), value: Integer.to_string(System.unique_integer([:positive]))}

      Agent.update(__MODULE__, fn state ->
        if is_pid(state.notify_pid), do: send(state.notify_pid, {:job_captured, job})
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
  end

  setup do
    _ = Application.stop(:lemon_gateway)
    _ = Application.stop(:lemon_router)
    _ = Application.stop(:lemon_channels)
    _ = Application.stop(:lemon_core)

    MockTelegramAPI.reset!(notify_pid: self())
    CaptureEngine.stop()
    {:ok, _} = CaptureEngine.start_link(notify_pid: self())

    on_exit(fn ->
      _ = Application.stop(:lemon_channels)
      _ = Application.stop(:lemon_router)
      _ = Application.stop(:lemon_gateway)
      _ = Application.stop(:lemon_control_plane)
      _ = Application.stop(:lemon_automation)
      _ = Application.stop(:lemon_core)

      CaptureEngine.stop()
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

  defp start_system! do
    lock_dir =
      Path.join(System.tmp_dir!(), "lemon_test_locks_#{System.unique_integer([:positive])}")

    System.put_env("LEMON_LOCK_DIR", lock_dir)

    Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")

    Application.put_env(:lemon_gateway, Config, %{
      max_concurrent_runs: 10,
      default_engine: CaptureEngine.id(),
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
    })

    Application.put_env(:lemon_core, LemonCore.Store, backend: LemonCore.Store.EtsBackend)

    Application.put_env(:lemon_gateway, :engines, [
      CaptureEngine,
      LemonGateway.Engines.Echo
    ])

    Application.put_env(:lemon_gateway, :telegram, %{
      api_mod: MockTelegramAPI,
      poll_interval_ms: 25
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

  test "replying to the bot's last message resumes via the message_id index (no resume line in reply text)" do
    start_system!()

    chat_id = 81_001

    # First message starts a run (engine will emit a resume token).
    MockTelegramAPI.enqueue_message(chat_id, "hi", message_id: 1)
    assert_receive {:job_captured, %Job{} = _job1}, 2_000

    # Wait for StreamCoalescer to index the final bot message_id -> resume token mapping.
    assert :ok ==
             wait_until(
               fn ->
                 LemonCore.Store.list(:telegram_msg_resume)
                 |> Enum.any?(fn
                   {{_acc, ^chat_id, _thread_id, _bot_msg_id}, %ResumeToken{engine: "cap"}} ->
                     true

                   _ ->
                     false
                 end)
               end,
               2_000
             )

    {{_acc, ^chat_id, thread_id, bot_msg_id}, %ResumeToken{} = indexed_tok} =
      LemonCore.Store.list(:telegram_msg_resume)
      |> Enum.find(fn
        {{_acc, ^chat_id, _thread_id, _bot_msg_id}, %ResumeToken{engine: "cap"}} -> true
        _ -> false
      end)

    assert is_integer(bot_msg_id)

    # Second message replies to bot message; reply_to text is empty in the test double,
    # so the transport must fall back to :telegram_msg_resume lookup.
    MockTelegramAPI.enqueue_message(chat_id, "follow up", message_id: 2, reply_to: bot_msg_id)

    assert_receive {:job_captured, %Job{} = job2}, 2_000

    assert %ResumeToken{} = job2.resume
    assert job2.resume.engine == indexed_tok.engine
    assert job2.resume.value == indexed_tok.value
    assert job2.engine_id in [nil, "cap"]
    assert job2.session_key != nil
    assert String.contains?(job2.prompt || "", "follow up")

    # Sanity: index entry uses same chat/thread we replied in.
    assert {job2.meta[:chat_id], job2.meta[:topic_id] || job2.meta[:thread_id]} ==
             {chat_id, thread_id}
  end
end
