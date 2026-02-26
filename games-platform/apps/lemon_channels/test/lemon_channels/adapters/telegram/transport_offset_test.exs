defmodule LemonChannels.Adapters.Telegram.TransportOffsetTest do
  use ExUnit.Case, async: false

  defmodule EmptyUpdatesAPI do
    def get_updates(_token, _offset, _timeout_ms) do
      {:ok, %{"ok" => true, "result" => []}}
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
    token = "test_token_" <> Integer.to_string(System.unique_integer([:positive]))

    {:ok, _pid} =
      LemonChannels.Adapters.Telegram.Transport.start_link(
        config: %{
          bot_token: token,
          api_mod: EmptyUpdatesAPI,
          poll_interval_ms: 10,
          offset: 123
        }
      )

    Process.sleep(60)

    state = :sys.get_state(LemonChannels.Adapters.Telegram.Transport)
    assert state.offset == 123
  end
end
