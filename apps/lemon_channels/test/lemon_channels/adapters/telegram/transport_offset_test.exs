defmodule LemonChannels.Adapters.Telegram.TransportOffsetTest do
  use ExUnit.Case, async: false

  defmodule EmptyUpdatesAPI do
    def get_updates(token, offset, _timeout_ms) do
      send(:persistent_term.get({__MODULE__, token}), {:poll_started, self(), offset})

      receive do
        :respond_empty -> {:ok, %{"ok" => true, "result" => []}}
      end
    end

    def send_message(_token, _chat_id, _text, _reply_to_or_opts \\ nil, _parse_mode \\ nil) do
      {:ok, %{"ok" => true, "result" => %{"message_id" => 1}}}
    end

    def edit_message_text(_token, _chat_id, _message_id, _text, _parse_mode_or_opts \\ nil) do
      {:ok, %{"ok" => true}}
    end

    def delete_message(_token, _chat_id, _message_id), do: {:ok, %{"ok" => true}}
    def answer_callback_query(_token, _cb_id, _opts \\ %{}), do: {:ok, %{"ok" => true}}
  end

  setup do
    unless Process.whereis(LemonChannels.Adapters.Telegram.AsyncSupervisor) do
      start_supervised!({Task.Supervisor, name: LemonChannels.Adapters.Telegram.AsyncSupervisor})
    end

    on_exit(fn ->
      if pid = Process.whereis(LemonChannels.Adapters.Telegram.Transport) do
        # Transport may already be dead by the time on_exit runs.
        try do
          GenServer.stop(pid, :normal)
        catch
          :exit, _ -> :ok
        end
      end
    end)

    :ok
  end

  test "does not advance offset when getUpdates returns an empty batch" do
    token = "offset-test-#{System.pid()}-#{System.unique_integer([:positive])}"
    :persistent_term.put({EmptyUpdatesAPI, token}, self())
    on_exit(fn -> :persistent_term.erase({EmptyUpdatesAPI, token}) end)

    {:ok, pid} =
      LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: token,
          api_mod: EmptyUpdatesAPI,
          poll_interval_ms: 60_000,
          offset: 123
        }
      )

    assert_receive {:poll_started, worker, 123}, 1_000
    finish_poll(worker)
    state = await_poll_applied(pid)
    assert state.offset == 123
  end

  test "a drain pause stops fetching so unfetched updates stay at Telegram" do
    token = "offset-test-#{System.pid()}-#{System.unique_integer([:positive])}"
    :persistent_term.put({EmptyUpdatesAPI, token}, self())
    on_exit(fn -> :persistent_term.erase({EmptyUpdatesAPI, token}) end)

    {:ok, pid} =
      LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{bot_token: token, api_mod: EmptyUpdatesAPI, poll_interval_ms: 60_000, offset: 7}
      )

    assert_receive {:poll_started, worker, 7}, 1_000
    assert :ok = GenServer.call(pid, :drain_pause)
    finish_poll(worker)
    assert await_poll_applied(pid).offset == 7

    send(pid, :poll)
    assert :sys.get_state(pid).drain_paused?
    refute_receive {:poll_started, _, _}, 0
  end

  defp finish_poll(worker) do
    monitor = Process.monitor(worker)
    send(worker, :respond_empty)
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 1_000
  end

  defp await_poll_applied(pid) do
    state = :sys.get_state(pid)
    if state[:poll_task], do: await_poll_applied(pid), else: state
  end
end
