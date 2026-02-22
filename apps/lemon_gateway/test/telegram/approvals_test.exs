defmodule LemonGateway.Telegram.ApprovalsTest do
  alias Elixir.LemonGateway, as: LemonGateway
  use ExUnit.Case, async: false

  alias Elixir.LemonGateway.Config
  alias LemonCore.SessionKey

  defmodule LemonGateway.Telegram.ApprovalsTest.MockTelegramAPI do
    use Agent

    def start_link(opts \\ []) do
      Agent.start_link(
        fn ->
          %{
            calls: [],
            pending_updates: [],
            update_id: 1000,
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

    def enqueue_update(update) when is_map(update) do
      Agent.update(__MODULE__, fn state ->
        id = state.update_id
        update_with_id = Map.put(update, "update_id", id)
        %{state | pending_updates: state.pending_updates ++ [update_with_id], update_id: id + 1}
      end)
    end

    def calls do
      Agent.get(__MODULE__, fn state -> Enum.reverse(state.calls) end)
    end

    def get_updates(_token, _offset, _timeout_ms) do
      Agent.get_and_update(__MODULE__, fn state ->
        updates = state.pending_updates
        {{:ok, %{"ok" => true, "result" => updates}}, %{state | pending_updates: []}}
      end)
    end

    def send_message(_token, chat_id, text, reply_to_or_opts \\ nil, _parse_mode \\ nil) do
      record({:send_message, chat_id, text, reply_to_or_opts})
      msg_id = System.unique_integer([:positive])
      {:ok, %{"ok" => true, "result" => %{"message_id" => msg_id}}}
    end

    def edit_message_text(_token, chat_id, message_id, text, opts_or_parse_mode \\ nil) do
      record({:edit_message_text, chat_id, message_id, text, opts_or_parse_mode})
      {:ok, %{"ok" => true}}
    end

    def answer_callback_query(_token, cb_id, opts \\ %{}) do
      record({:answer_callback_query, cb_id, opts})
      {:ok, %{"ok" => true}}
    end

    defp record(call) do
      Agent.update(__MODULE__, fn state -> %{state | calls: [call | state.calls]} end)

      notify_pid = Agent.get(__MODULE__, & &1.notify_pid)
      if is_pid(notify_pid), do: send(notify_pid, {:telegram_api_call, call})
      :ok
    end
  end

  setup do
    _ = Application.stop(:lemon_gateway)
    _ = Application.stop(:lemon_channels)
    _ = Application.stop(:lemon_control_plane)
    _ = Application.stop(:lemon_automation)
    _ = Application.stop(:lemon_core)

    Elixir.LemonGateway.Telegram.ApprovalsTest.MockTelegramAPI.stop()
    {:ok, _} = start_supervised({Elixir.LemonGateway.Telegram.ApprovalsTest.MockTelegramAPI, notify_pid: self()})

    Application.delete_env(:lemon_gateway, Elixir.LemonGateway.Config)
    Application.delete_env(:lemon_gateway, :config_path)
    Application.delete_env(:lemon_gateway, :telegram)
    Application.delete_env(:lemon_gateway, :transports)
    Application.delete_env(:lemon_gateway, :engines)
    Application.delete_env(:lemon_gateway, :commands)
    Application.delete_env(:lemon_channels, :gateway)
    Application.delete_env(:lemon_channels, :telegram)
    Application.delete_env(:lemon_channels, :engines)

    on_exit(fn ->
      Elixir.LemonGateway.Telegram.ApprovalsTest.MockTelegramAPI.stop()
      _ = Application.stop(:lemon_gateway)
      _ = Application.stop(:lemon_channels)
      _ = Application.stop(:lemon_control_plane)
      _ = Application.stop(:lemon_automation)
      _ = Application.stop(:lemon_core)
      Application.delete_env(:lemon_gateway, Elixir.LemonGateway.Config)
      Application.delete_env(:lemon_gateway, :config_path)
      Application.delete_env(:lemon_gateway, :telegram)
      Application.delete_env(:lemon_gateway, :transports)
      Application.delete_env(:lemon_gateway, :engines)
      Application.delete_env(:lemon_gateway, :commands)
      Application.delete_env(:lemon_channels, :gateway)
      Application.delete_env(:lemon_channels, :telegram)
      Application.delete_env(:lemon_channels, :engines)
    end)

    :ok
  end

  defp start_gateway do
    config = %{
      max_concurrent_runs: 1,
      default_engine: "echo",
      enable_telegram: true,
      bindings: [],
      telegram: %{
        bot_token: "test_token",
        poll_interval_ms: 20,
        allowed_chat_ids: nil,
        deny_unbound_chats: false
      }
    }

    Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")

    Application.put_env(:lemon_gateway, Config, config)

    Application.put_env(:lemon_gateway, :engines, [
      Elixir.LemonGateway.Engines.Echo
    ])

    Application.put_env(:lemon_gateway, :commands, [])

    Application.put_env(:lemon_gateway, :telegram, %{
      api_mod: Elixir.LemonGateway.Telegram.ApprovalsTest.MockTelegramAPI,
      account_id: "default"
    })

    Application.put_env(:lemon_channels, :gateway, config)

    Application.put_env(:lemon_channels, :telegram, %{
      api_mod: Elixir.LemonGateway.Telegram.ApprovalsTest.MockTelegramAPI,
      poll_interval_ms: config.telegram.poll_interval_ms,
      allowed_chat_ids: config.telegram.allowed_chat_ids,
      deny_unbound_chats: config.telegram.deny_unbound_chats
    })

    Application.put_env(:lemon_channels, :engines, [
      Elixir.LemonGateway.Engines.Echo
    ])

    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    {:ok, _} = Application.ensure_all_started(:lemon_channels)

    # Wait for channels-based Telegram poller to come up and pick up the mock API module.
    poller_pid =
      wait_until(fn -> Process.whereis(LemonChannels.Adapters.Telegram.Transport) end, 5_000) ||
        Process.whereis(LemonChannels.Adapters.Telegram.Transport)

    assert is_pid(poller_pid)

    poller_state = :sys.get_state(LemonChannels.Adapters.Telegram.Transport)
    assert poller_state.api_mod == Elixir.LemonGateway.Telegram.ApprovalsTest.MockTelegramAPI
  end

  defp wait_until(fun, timeout_ms) when is_function(fun, 0) and is_integer(timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline_ms) do
    case fun.() do
      nil ->
        if System.monotonic_time(:millisecond) < deadline_ms do
          Process.sleep(10)
          do_wait_until(fun, deadline_ms)
        else
          nil
        end

      val ->
        val
    end
  end

  test "approval request results in Telegram inline keyboard; callback resolves approval" do
    start_gateway()

    chat_id = 12345

    session_key =
      SessionKey.channel_peer(%{
        agent_id: "daily",
        channel_id: "telegram",
        account_id: "default",
        peer_kind: :dm,
        peer_id: Integer.to_string(chat_id)
      })

    task =
      Task.async(fn ->
        LemonCore.ExecApprovals.request(%{
          run_id: "run_test",
          session_key: session_key,
          agent_id: "daily",
          tool: "bash",
          action: %{"cmd" => "ls"},
          rationale: "test",
          expires_in_ms: 5_000
        })
      end)

    approval_id =
      wait_until(
        fn ->
          case LemonCore.Store.list(:exec_approvals_pending) do
            [{id, _pending} | _] when is_binary(id) -> id
            _ -> nil
          end
        end,
        2_000
      )

    assert is_binary(approval_id)

    assert_receive {:telegram_api_call, {:send_message, ^chat_id, text, opts}}, 2_000
    assert is_binary(text)
    assert is_map(opts)
    assert Map.has_key?(opts, "reply_markup")

    # Simulate button click (callback_query)
    Elixir.LemonGateway.Telegram.ApprovalsTest.MockTelegramAPI.enqueue_update(%{
      "callback_query" => %{
        "id" => "cb_1",
        "data" => "#{approval_id}|once",
        "message" => %{
          "message_id" => 999,
          "chat" => %{"id" => chat_id, "type" => "private"}
        }
      }
    })

    assert_receive {:telegram_api_call, {:answer_callback_query, "cb_1", _}}, 2_000
    assert_receive {:telegram_api_call, {:edit_message_text, ^chat_id, 999, _text, _opts}}, 2_000

    assert LemonCore.Store.get(:exec_approvals_pending, approval_id) == nil

    assert {:ok, :approved, :approve_once} = Task.await(task, 5_000)
  end
end
