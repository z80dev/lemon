defmodule LemonGateway.Telegram.ExecApprovalsIntegrationTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Config
  alias LemonGateway.TestSupport.MockTelegramAPI

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

  defp start_system! do
    lock_dir =
      Path.join(System.tmp_dir!(), "lemon_test_locks_#{System.unique_integer([:positive])}")

    System.put_env("LEMON_LOCK_DIR", lock_dir)

    Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")

    config = %{
      max_concurrent_runs: 10,
      default_engine: "echo",
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

  test "approval_requested on exec_approvals bus sends an inline keyboard to the correct chat" do
    start_system!()

    chat_id = 12_345
    session_key = "agent:default:telegram:default:dm:#{chat_id}"

    event =
      LemonCore.Event.new(
        :approval_requested,
        %{
          approval_id: "ap1",
          pending: %{
            session_key: session_key,
            tool: "shell",
            action: %{"cmd" => "ls -la"}
          }
        }
      )

    :ok = LemonCore.Bus.broadcast("exec_approvals", event)

    assert_receive {:telegram_api_call, {:send_message, ^chat_id, text, opts, _pm}}, 2_000

    assert is_binary(text)
    assert String.contains?(text, "Approval requested")
    assert String.contains?(text, "shell")

    reply_markup = opts["reply_markup"] || opts[:reply_markup]
    assert is_map(reply_markup)
    assert is_list(reply_markup["inline_keyboard"])

    # Basic shape check for callback_data (approval_id|decision).
    flat =
      reply_markup["inline_keyboard"]
      |> List.flatten()
      |> Enum.map(& &1["callback_data"])
      |> Enum.filter(&is_binary/1)

    assert Enum.any?(flat, &(&1 == "ap1|once"))
    assert Enum.any?(flat, &(&1 == "ap1|deny"))
  end
end
