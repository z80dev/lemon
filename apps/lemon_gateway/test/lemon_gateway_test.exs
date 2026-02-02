defmodule LemonGatewayTest do
  use ExUnit.Case

  alias LemonGateway.Event.Completed
  alias LemonGateway.Types.{ChatScope, Job}

  setup_all do
    {:ok, _} = Application.ensure_all_started(:lemon_gateway)
    :ok
  end

  test "submits a job and receives completion" do
    scope = %ChatScope{transport: :test, chat_id: 1, topic_id: nil}

    job = %Job{
      scope: scope,
      user_msg_id: 1,
      text: "hello",
      resume: nil,
      engine_hint: nil,
      meta: %{notify_pid: self()}
    }

    LemonGateway.submit(job)

    assert_receive {:lemon_gateway_run_completed, ^job, %Completed{ok: true, answer: "Echo: hello"}}, 1_000
  end
end
