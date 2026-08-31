defmodule LemonCore.A2A.ProtocolTest do
  use ExUnit.Case, async: true

  alias LemonCore.A2A.Protocol

  test "builds and reads A2A v1 text messages" do
    message =
      Protocol.message("ROLE_USER", "hello", context_id: "ctx-1", message_id: "msg-1")

    assert message == %{
             "messageId" => "msg-1",
             "role" => "ROLE_USER",
             "contextId" => "ctx-1",
             "parts" => [%{"mediaType" => "text/plain", "text" => "hello"}]
           }

    assert Protocol.text(message) == {:ok, "hello"}
  end

  test "unwraps the v1 SendMessage task wrapper" do
    task = %{"id" => "task-1", "status" => %{"state" => "TASK_STATE_COMPLETED"}}
    assert Protocol.unwrap_task(%{"result" => %{"task" => task}}) == {:ok, task}
  end

  test "recognizes only terminal task states" do
    assert Protocol.terminal_state?("TASK_STATE_COMPLETED")
    assert Protocol.terminal_state?("TASK_STATE_CANCELED")
    refute Protocol.terminal_state?("TASK_STATE_WORKING")
    refute Protocol.terminal_state?("TASK_STATE_INPUT_REQUIRED")
  end
end
