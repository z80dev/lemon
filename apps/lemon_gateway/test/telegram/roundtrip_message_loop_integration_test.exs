defmodule LemonGateway.Telegram.RoundtripMessageLoopIntegrationTest do
  @moduledoc """
  Integration tests for a synthetic Telegram message flowing through:

    Telegram update -> lemon_channels Telegram transport -> lemon_router -> lemon_gateway engine ->
    lemon_router coalescing -> lemon_channels outbox -> Telegram outbound API calls

  These tests do not talk to real Telegram. A mock API module captures calls.
  """

  use ExUnit.Case, async: false

  alias LemonGateway.Config
  alias LemonGateway.Types.{Job, ResumeToken}
  alias LemonGateway.Event

  # Mock Telegram API that records calls and can inject updates.
  defmodule MockTelegramAPI do
    use Agent

    def start_link(opts \\ []) do
      Agent.start_link(
        fn ->
          %{
            calls: [],
            pending_updates: opts[:updates] || [],
            update_id: opts[:start_update_id] || 1000,
            notify_pid: opts[:notify_pid],
            # Deterministic "Running…" message id so tests can reply-to it.
            running_message_id: opts[:running_message_id] || 90_001,
            # Controls whether the Running… send_message response includes a message_id.
            # Values: :ok_with_id | :ok_missing_id
            running_send_mode: opts[:running_send_mode] || :ok_with_id
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

    def set_running_message_id(message_id) when is_integer(message_id) do
      Agent.update(__MODULE__, &%{&1 | running_message_id: message_id})
    end

    def set_running_send_mode(mode) when mode in [:ok_with_id, :ok_missing_id] do
      Agent.update(__MODULE__, &%{&1 | running_send_mode: mode})
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
      reply_to_message_id = Keyword.get(opts, :reply_to_message_id)

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
        if is_integer(reply_to_message_id) do
          Map.put(message, "reply_to_message", %{"message_id" => reply_to_message_id})
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

      if text == "Running…" do
        state = Agent.get(__MODULE__, & &1)

        case state.running_send_mode do
          :ok_with_id ->
            {:ok, %{"ok" => true, "result" => %{"message_id" => state.running_message_id}}}

          :ok_missing_id ->
            {:ok, %{"ok" => true, "result" => %{}}}
        end
      else
        msg_id = System.unique_integer([:positive])
        {:ok, %{"ok" => true, "result" => %{"message_id" => msg_id}}}
      end
    end

    def edit_message_text(_token, chat_id, message_id, text, _parse_mode \\ nil) do
      record({:edit_message, chat_id, message_id, text})
      {:ok, %{"ok" => true}}
    end

    def delete_message(_token, chat_id, message_id) do
      record({:delete_message, chat_id, message_id})
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

  # Deterministic test engine: completes quickly with a fixed answer.
  defmodule ReplyEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

    @impl true
    def id, do: "lemon"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "reply resume #{sid}"

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
          Process.sleep(10)

          send(
            sink_pid,
            {:engine_event, run_ref,
             %Event.Completed{engine: id(), resume: resume, ok: true, answer: "pong"}}
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

  # Deterministic test engine: completes with ok: false and no answer.
  defmodule FailEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

    @impl true
    def id, do: "lemon"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "fail resume #{sid}"

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
          Process.sleep(10)

          send(
            sink_pid,
            {:engine_event, run_ref,
             %Event.Completed{engine: id(), resume: resume, ok: false, error: :boom, answer: ""}}
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

  # Deterministic test engine: slow completion so cancel timing is stable.
  defmodule SlowReplyEngine do
    @behaviour LemonGateway.Engine

    alias LemonGateway.Types.{Job, ResumeToken}
    alias LemonGateway.Event

    @impl true
    def id, do: "lemon"

    @impl true
    def format_resume(%ResumeToken{value: sid}), do: "slow reply resume #{sid}"

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
          Process.sleep(500)

          send(
            sink_pid,
            {:engine_event, run_ref,
             %Event.Completed{engine: id(), resume: resume, ok: true, answer: "pong"}}
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

    MockTelegramAPI.stop()
    {:ok, _} = MockTelegramAPI.start_link(notify_pid: self())

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

  defp start_system!(overrides \\ %{}) do
    # Isolate poller locks for each test run.
    lock_dir =
      Path.join(System.tmp_dir!(), "lemon_test_locks_#{System.unique_integer([:positive])}")

    System.put_env("LEMON_LOCK_DIR", lock_dir)

    engine_selector = Map.get(overrides, :default_engine, "reply")

    engine_mod =
      case engine_selector do
        "fail" -> FailEngine
        "slow_reply" -> SlowReplyEngine
        _ -> ReplyEngine
      end

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

    config_overrides = Map.delete(overrides, :default_engine)

    config =
      base_config
      |> Map.merge(config_overrides)
      |> Map.update(:telegram, %{}, fn tg -> Map.merge(base_config.telegram, tg || %{}) end)

    Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")
    Application.put_env(:lemon_gateway, Config, config)

    # Avoid leaking state across tests via the default JsonlBackend (config/config.exs).
    Application.put_env(:lemon_core, LemonCore.Store, backend: LemonCore.Store.EtsBackend)

    Application.put_env(:lemon_gateway, :engines, [
      engine_mod,
      LemonGateway.Engines.Echo
    ])

    # Used by the inbound poller and (via lemon_channels Outbound) outbound delivery.
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
      engine_mod,
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

  defp reply_to_from_opts(opts) when is_list(opts) do
    Keyword.get(opts, :reply_to_message_id)
  end

  defp reply_to_from_opts(opts) when is_map(opts) do
    opts[:reply_to_message_id] || opts["reply_to_message_id"]
  end

  defp thread_id_from_opts(opts) when is_list(opts) do
    Keyword.get(opts, :message_thread_id)
  end

  defp thread_id_from_opts(opts) when is_map(opts) do
    opts[:message_thread_id] || opts["message_thread_id"]
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

  test "incoming message produces final reply" do
    start_system!()

    chat_id = 12_345
    user_msg_id = 111
    MockTelegramAPI.enqueue_message(chat_id, "/hello", message_id: user_msg_id)

    # Transport progress: send "Running…" (and store its msg id into run meta)
    assert_receive {:telegram_api_call, {:send_message, ^chat_id, "Running…", _opts, _pm}}, 2_000

    # Wait for the outbox to deliver the finalize payload.
    assert :ok ==
             wait_until(
               fn ->
                 calls = MockTelegramAPI.calls()

                 Enum.any?(calls, fn
                   {:send_message, ^chat_id, "pong", _opts, _pm} -> true
                   _ -> false
                 end)
               end,
               5_000
             )

    calls = MockTelegramAPI.calls()

    {:send_message, ^chat_id, "Running…", _progress_opts, _} =
      Enum.find(calls, fn
        {:send_message, ^chat_id, "Running…", _, _} -> true
        _ -> false
      end)

    {:send_message, ^chat_id, "pong", final_opts, _} =
      Enum.find(calls, fn
        {:send_message, ^chat_id, "pong", _, _} -> true
        _ -> false
      end)

    assert reply_to_from_opts(final_opts) == user_msg_id
  end

  test "topic messages propagate message_thread_id to final reply" do
    start_system!()

    chat_id = 22_222
    topic_id = 333
    user_msg_id = 444

    MockTelegramAPI.enqueue_message(chat_id, "/hello",
      message_id: user_msg_id,
      topic_id: topic_id
    )

    assert_receive {:telegram_api_call, {:send_message, ^chat_id, "Running…", _opts, _pm}}, 2_000

    assert :ok ==
             wait_until(
               fn ->
                 calls = MockTelegramAPI.calls()

                 Enum.any?(calls, fn
                   {:send_message, ^chat_id, "pong", opts, _pm} ->
                     thread_id_from_opts(opts) == topic_id

                   _ ->
                     false
                 end)
               end,
               5_000
             )
  end

  test "engine failure produces run failed message (keep progress message; clear cancel UI)" do
    start_system!(%{default_engine: "fail"})

    chat_id = 55_555
    user_msg_id = 12
    MockTelegramAPI.enqueue_message(chat_id, "please fail", message_id: user_msg_id)

    assert_receive {:telegram_api_call, {:send_message, ^chat_id, "Running…", _opts, _pm}}, 2_000

    assert :ok ==
             wait_until(
               fn ->
                 calls = MockTelegramAPI.calls()

                 Enum.any?(calls, fn
                   {:edit_message, ^chat_id, _msg_id, "Done"} -> true
                   _ -> false
                 end) and
                   Enum.any?(calls, fn
                     {:send_message, ^chat_id, text, _opts, _pm} when is_binary(text) ->
                       String.starts_with?(text, "Run failed:")

                     _ ->
                       false
                   end)
               end,
               5_000
             )
  end

  test "reply /cancel cancels the run and clears the Running… message UI (no delete)" do
    start_system!(%{default_engine: "slow_reply"})

    chat_id = 66_666
    user_msg_id = 13
    running_msg_id = 90_001
    MockTelegramAPI.set_running_message_id(running_msg_id)

    MockTelegramAPI.enqueue_message(chat_id, "slow please", message_id: user_msg_id)

    assert_receive {:telegram_api_call, {:send_message, ^chat_id, "Running…", _opts, _pm}}, 2_000

    # Wait until the gateway indexes the progress message id so cancel-by-reply can resolve it.
    session_key = telegram_session_key(chat_id)

    assert :ok ==
             wait_until(
               fn ->
                 is_pid(LemonGateway.Store.get_run_by_progress(session_key, running_msg_id))
               end,
               5_000
             )

    MockTelegramAPI.enqueue_message(chat_id, "/cancel", reply_to_message_id: running_msg_id)

    assert :ok ==
             wait_until(
               fn ->
                 calls = MockTelegramAPI.calls()

                 Enum.any?(calls, fn
                   {:edit_message, ^chat_id, ^running_msg_id, "Done"} -> true
                   _ -> false
                 end) and
                   Enum.any?(calls, fn
                     {:send_message, ^chat_id, text, _opts, _pm} when is_binary(text) ->
                       String.starts_with?(text, "Run failed:")

                     _ ->
                       false
                   end)
               end,
               5_000
             )
  end

  test "/cancel without reply does not cancel an in-flight run" do
    start_system!(%{default_engine: "slow_reply"})

    chat_id = 77_777
    user_msg_id = 14
    MockTelegramAPI.enqueue_message(chat_id, "slow please", message_id: user_msg_id)

    assert_receive {:telegram_api_call, {:send_message, ^chat_id, "Running…", _opts, _pm}}, 2_000

    # This /cancel is ignored because it is not a reply to the progress message.
    MockTelegramAPI.enqueue_message(chat_id, "/cancel")

    assert :ok ==
             wait_until(
               fn ->
                 calls = MockTelegramAPI.calls()

                 Enum.any?(calls, fn
                   {:send_message, ^chat_id, "pong", _opts, _pm} -> true
                   _ -> false
                 end)
               end,
               5_000
             )
  end

  test "if the Running… send response has no message_id, finalize does not attempt delete" do
    start_system!()
    MockTelegramAPI.set_running_send_mode(:ok_missing_id)

    chat_id = 88_888
    user_msg_id = 15
    MockTelegramAPI.enqueue_message(chat_id, "hello", message_id: user_msg_id)

    assert_receive {:telegram_api_call, {:send_message, ^chat_id, "Running…", _opts, _pm}}, 2_000

    assert :ok ==
             wait_until(
               fn ->
                 calls = MockTelegramAPI.calls()

                 Enum.any?(calls, fn
                   {:send_message, ^chat_id, "pong", _, _} -> true
                   _ -> false
                 end)
               end,
               5_000
             )

    # Running… was sent, but without a message_id in the response; progress_msg_id stays nil
    # and the router cannot delete the progress message.
    refute Enum.any?(MockTelegramAPI.calls(), fn
             {:delete_message, ^chat_id, _} -> true
             _ -> false
           end)
  end
end
