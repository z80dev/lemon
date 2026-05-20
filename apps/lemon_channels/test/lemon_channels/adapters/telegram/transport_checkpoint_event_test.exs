defmodule LemonChannels.Adapters.Telegram.TransportCheckpointEventTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport

  test "pushes redacted checkpoint event notices for tracked sessions" do
    parent = self()

    state = %{
      reaction_runs: %{
        "session:checkpoint" => %{chat_id: 123, thread_id: 456, user_msg_id: 789}
      },
      checkpoint_event_sender: fn chat_id, thread_id, user_msg_id, text ->
        send(parent, {:checkpoint_notice, chat_id, thread_id, user_msg_id, text})
        :ok
      end
    }

    event = %LemonCore.Event{
      type: :checkpoint_restored,
      ts_ms: System.system_time(:millisecond),
      payload: %{
        checkpoint_id: "chk_push",
        restored_count: 1,
        paths: ["/private/file.ex"],
        content: "secret"
      },
      meta: %{session_key: "session:checkpoint"}
    }

    assert {:noreply, returned} = Transport.handle_info(event, state)
    assert returned == state

    assert_receive {:checkpoint_notice, 123, 456, 789,
                    "Checkpoint Event\nrestored chk_push (1 paths)"}
  end
end
