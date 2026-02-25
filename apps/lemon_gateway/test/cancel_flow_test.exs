defmodule LemonGateway.CancelFlowTest do
  use ExUnit.Case

  alias LemonGateway.Types.ChatScope

  test "cancel by progress message stops run" do
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)

    scope = %ChatScope{transport: :test, chat_id: 42, topic_id: nil}
    run_id = "run_cancel_flow_#{System.unique_integer([:positive])}"

    parent = self()

    _run_pid =
      spawn(fn ->
        # Register in RunRegistry so cancel_by_progress_msg can look up the PID
        Registry.register(LemonGateway.RunRegistry, run_id, %{})
        send(parent, :registered)

        receive do
          {:"$gen_cast", {:cancel, reason}} ->
            send(parent, {:cancelled, reason})
        end
      end)

    assert_receive :registered, 1_000

    LemonGateway.Store.put_progress_mapping(scope, 1001, run_id)

    :ok = LemonGateway.Runtime.cancel_by_progress_msg(scope, 1001)

    assert_receive {:cancelled, :user_requested}, 1_000
  end
end
