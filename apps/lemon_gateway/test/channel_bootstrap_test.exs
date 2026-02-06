defmodule LemonGateway.ChannelBootstrapTest do
  use ExUnit.Case, async: false

  alias LemonGateway.Config

  # Minimal mock Telegram API for boot validation.
  defmodule MockTelegramAPI do
    use Agent

    def start_link(opts \\ []) do
      Agent.start_link(fn -> %{updates: opts[:updates] || []} end, name: __MODULE__)
    end

    def stop do
      case Process.whereis(__MODULE__) do
        nil -> :ok
        pid -> Agent.stop(pid, :normal, 100)
      end
    catch
      :exit, _ -> :ok
    end

    def get_updates(_token, _offset, _timeout_ms) do
      {:ok, %{"ok" => true, "result" => []}}
    end

    def send_message(_token, _chat_id, _text, _reply_to_message_id \\ nil, _parse_mode \\ nil) do
      {:ok, %{"ok" => true, "result" => %{"message_id" => 1}}}
    end

    def edit_message_text(_token, _chat_id, _message_id, _text, _parse_mode \\ nil) do
      {:ok, %{"ok" => true}}
    end

    def delete_message(_token, _chat_id, _message_id) do
      {:ok, %{"ok" => true}}
    end

    def answer_callback_query(_token, _cb_id, _opts), do: {:ok, %{"ok" => true}}
  end

  setup do
    _ = Application.stop(:lemon_gateway)
    _ = Application.stop(:lemon_router)
    _ = Application.stop(:lemon_channels)

    MockTelegramAPI.stop()
    {:ok, _} = MockTelegramAPI.start_link()

    on_exit(fn ->
      MockTelegramAPI.stop()
      _ = Application.stop(:lemon_gateway)
      _ = Application.stop(:lemon_router)
      _ = Application.stop(:lemon_channels)
      Application.delete_env(:lemon_gateway, Config)
      Application.delete_env(:lemon_gateway, :config_path)
      Application.delete_env(:lemon_gateway, :telegram)
    end)

    :ok
  end

  test "bootstraps lemon_channels (and deps) without starting legacy telegram transport" do
    Application.put_env(:lemon_gateway, :config_path, "/nonexistent/path.toml")

    Application.put_env(:lemon_gateway, Config, %{
      max_concurrent_runs: 1,
      default_engine: "echo",
      enable_telegram: true,
      bindings: [],
      telegram: %{
        bot_token: "test_token",
        poll_interval_ms: 50,
        dedupe_ttl_ms: 60_000,
        debounce_ms: 10
      }
    })

    Application.put_env(:lemon_gateway, :telegram, %{
      api_mod: MockTelegramAPI,
      poll_interval_ms: 50
    })

    assert {:ok, _apps} = Application.ensure_all_started(:lemon_gateway)

    # Wait for channels transport to come up.
    assert is_pid(wait_for_pid(LemonChannels.Adapters.Telegram.Transport, 2_000))

    # Ensure we did not also start the legacy poller/outbox.
    assert Process.whereis(LemonGateway.TransportSupervisor) == nil
    assert Process.whereis(LemonGateway.Telegram.Transport) == nil
    assert Process.whereis(LemonGateway.Telegram.Outbox) == nil
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
end

