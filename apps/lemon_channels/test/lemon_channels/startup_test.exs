defmodule LemonChannels.StartupTest do
  alias Elixir.LemonChannels, as: LemonChannels
  use ExUnit.Case, async: false

  # Minimal mock Telegram API for boot validation.
  defmodule StartupMockTelegramAPI do
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

  @gateway_config_key :"Elixir.LemonGateway.Config"

  setup do
    lock_dir =
      Path.join([
        System.tmp_dir!(),
        "lemon_channels_test_locks_#{System.unique_integer([:positive])}"
      ])

    env = LemonPlatformTest.Testing.HermeticEnv.snapshot_env(["LEMON_LOCK_DIR"])
    gateway = Application.fetch_env(:lemon_gateway, @gateway_config_key)
    adapters = Application.fetch_env(:lemon_channels, :adapters)
    running? = List.keymember?(Application.started_applications(), :lemon_channels, 0)

    on_exit(fn ->
      Application.stop(:lemon_channels)
      StartupMockTelegramAPI.stop()
      restore_env(:lemon_gateway, @gateway_config_key, gateway)
      restore_env(:lemon_channels, :adapters, adapters)
      LemonPlatformTest.Testing.HermeticEnv.restore_env(env)
      File.rm_rf!(lock_dir)
      if running?, do: :ok = Application.start(:lemon_channels)
    end)

    if running?, do: :ok = Application.stop(:lemon_channels)

    _ = File.mkdir_p(lock_dir)
    System.put_env("LEMON_LOCK_DIR", lock_dir)

    StartupMockTelegramAPI.stop()
    {:ok, _} = StartupMockTelegramAPI.start_link()

    Application.put_env(:lemon_gateway, @gateway_config_key, %{
      max_concurrent_runs: 1,
      enable_telegram: true,
      bindings: [],
      telegram: %{
        bot_token: "test_token",
        api_mod: StartupMockTelegramAPI,
        poll_interval_ms: 50,
        dedupe_ttl_ms: 60_000,
        debounce_ms: 10
      }
    })

    Application.put_env(:lemon_channels, :adapters, [LemonChannels.Adapters.Telegram])

    :ok
  end

  test "starting lemon_channels boots telegram transport without legacy poller" do
    assert {:ok, _apps} = Application.ensure_all_started(:lemon_channels)

    # Wait for channels transport to come up.
    assert is_pid(wait_for_pid(Elixir.LemonChannels.Adapters.Telegram.Transport, 5_000))

    # Ensure we did not also start the legacy gateway transport supervisor.
    assert Process.whereis(LemonGateway.TransportSupervisor) == nil
  end

  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)

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
