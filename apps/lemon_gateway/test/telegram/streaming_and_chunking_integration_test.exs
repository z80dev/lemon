defmodule LemonGateway.Telegram.StreamingAndChunkingIntegrationTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Config
  alias LemonGateway.Event
  alias LemonGateway.TestSupport.MockTelegramAPI
  alias LemonGateway.Types.{Job, ResumeToken}

  defmodule StreamingEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Event
    alias LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "streaming"

    @impl true
    def format_resume(%ResumeToken{value: v}), do: "streaming resume #{v}"

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

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})

          # >= 48 chars triggers immediate flush; then idle flush safety covers if needed.
          send(sink_pid, {:engine_delta, run_ref, String.duplicate("a", 60)})
          Process.sleep(100)

          # Second delta exercises the "edit answer message" path.
          send(sink_pid, {:engine_delta, run_ref, String.duplicate("b", 60)})
          Process.sleep(500)

          send(
            sink_pid,
            {:engine_event, run_ref,
             %Event.Completed{engine: id(), resume: resume, ok: true, answer: ""}}
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

  defmodule LargeAnswerEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Event
    alias LemonGateway.Types.{Job, ResumeToken}

    @impl true
    def id, do: "large"

    @impl true
    def format_resume(%ResumeToken{value: v}), do: "large resume #{v}"

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
      answer = String.duplicate("x", 5_000)

      {:ok, task_pid} =
        Task.start(fn ->
          send(sink_pid, {:engine_event, run_ref, %Event.Started{engine: id(), resume: resume}})
          Process.sleep(10)

          send(
            sink_pid,
            {:engine_event, run_ref,
             %Event.Completed{engine: id(), resume: resume, ok: true, answer: answer}}
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
    end)

    :ok
  end

  defp start_system!(engine_mod) when is_atom(engine_mod) do
    lock_dir =
      Path.join(System.tmp_dir!(), "lemon_test_locks_#{System.unique_integer([:positive])}")

    System.put_env("LEMON_LOCK_DIR", lock_dir)

    Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")

    Application.put_env(:lemon_gateway, Config, %{
      max_concurrent_runs: 10,
      default_engine: engine_mod.id(),
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
      engine_mod,
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

  defp reply_to_from_opts(opts) when is_list(opts), do: Keyword.get(opts, :reply_to_message_id)

  defp reply_to_from_opts(opts) when is_map(opts),
    do: opts[:reply_to_message_id] || opts["reply_to_message_id"]

  defp reply_to_from_opts(_), do: nil

  test "streaming deltas update the answer message (progress message is reserved for tool status)" do
    start_system!(StreamingEngine)

    chat_id = 31_001
    user_msg_id = 11
    MockTelegramAPI.enqueue_message(chat_id, "go", message_id: user_msg_id)

    assert_receive {:telegram_api_call, {:send_message, ^chat_id, "Running…", _opts, _pm}}, 2_000

    assert :ok ==
             wait_until(
               fn ->
                 calls = MockTelegramAPI.calls()

                 Enum.any?(calls, fn
                   {:send_message, ^chat_id, text, _opts, _pm} ->
                     is_binary(text) and String.starts_with?(text, "a")

                   _ ->
                     false
                 end) and
                   Enum.any?(calls, fn
                     {:edit_message, ^chat_id, _msg_id, text, _opts} ->
                       is_binary(text) and String.contains?(text, "b")

                     _ ->
                       false
                   end)
               end,
               5_000
             )
  end

  test "final answers exceeding Telegram chunk limit are split into multiple sendMessage calls" do
    start_system!(LargeAnswerEngine)

    chat_id = 31_002
    user_msg_id = 12
    MockTelegramAPI.enqueue_message(chat_id, "go", message_id: user_msg_id)

    assert_receive {:telegram_api_call, {:send_message, ^chat_id, "Running…", _opts, _pm}}, 2_000

    assert :ok ==
             wait_until(
               fn ->
                 calls = MockTelegramAPI.calls()

                 Enum.count(calls, fn
                   {:send_message, ^chat_id, text, _opts, _pm} ->
                     is_binary(text) and String.starts_with?(text, "x")

                   _ ->
                     false
                 end) >= 2
               end,
               5_000
             )

    chunks =
      MockTelegramAPI.calls()
      |> Enum.filter(fn
        {:send_message, ^chat_id, text, _opts, _pm} when is_binary(text) ->
          String.starts_with?(text, "x")

        _ ->
          false
      end)

    assert length(chunks) == 2

    [{:send_message, ^chat_id, chunk1, opts1, _}, {:send_message, ^chat_id, chunk2, opts2, _}] =
      chunks

    assert String.length(chunk1) == 4096
    assert String.length(chunk2) == 904

    assert reply_to_from_opts(opts1) == user_msg_id
    assert reply_to_from_opts(opts2) == nil
  end
end
