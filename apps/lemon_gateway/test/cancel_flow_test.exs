defmodule LemonGateway.CancelFlowTest do
  use ExUnit.Case

  alias LemonGateway.Types.ChatScope

  test "cancel by progress message stops run" do
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    scope = %ChatScope{transport: :test, chat_id: 42, topic_id: nil}

    parent = self()

    run_pid =
      spawn(fn ->
        receive do
          {:"$gen_cast", {:cancel, reason}} ->
            send(parent, {:cancelled, reason})
        end
      end)

    LemonGateway.Store.put_progress_mapping(scope, 1001, run_pid)

    :ok = LemonGateway.Runtime.cancel_by_progress_msg(scope, 1001)

    assert_receive {:cancelled, :user_requested}, 1_000
  end
end
