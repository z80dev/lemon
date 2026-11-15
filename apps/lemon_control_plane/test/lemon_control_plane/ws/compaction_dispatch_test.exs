defmodule LemonControlPlane.WS.CompactionDispatchTest do
  use ExUnit.Case, async: false
  alias LemonControlPlane.WS.Connection

  defmodule SlowProvider do
    def compact_session(_key, _opts) do
      send(LemonControlPlane.WS.CompactionDispatchTest, {:compaction_started, self()})

      receive do
        :finish -> :ok
      after
        2000 -> {:error, :test_timeout}
      end
    end
  end

  test "model-backed compaction does not block heartbeat or response delivery" do
    Process.register(self(), __MODULE__)

    if Process.whereis(LemonControlPlane.Methods.Registry) == nil,
      do: start_supervised!(LemonControlPlane.Methods.Registry)

    old = Application.get_env(:lemon_core, :agent_runtime_provider)
    Application.put_env(:lemon_core, :agent_runtime_provider, SlowProvider)

    on_exit(fn ->
      if old,
        do: Application.put_env(:lemon_core, :agent_runtime_provider, old),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)
    end)

    state = %Connection{
      conn_id: "compaction-heartbeat",
      connected: true,
      auth: %{role: :operator, scopes: [:admin]},
      event_seq: 0,
      state_version: %{}
    }

    request =
      Jason.encode!(%{
        type: "req",
        id: "compact",
        method: "sessions.compact",
        params: %{sessionKey: "agent:compact:main", cwd: "/workspace"}
      })

    assert {:ok, pending_state} = Connection.handle_in({request, [opcode: :text]}, state)
    assert_receive {:compaction_started, worker}

    assert {:push, {:ping, ""}, heartbeat_state} =
             Connection.handle_info(:heartbeat, pending_state)

    Process.cancel_timer(heartbeat_state.heartbeat_timer_ref)
    send(worker, :finish)
    assert_receive {:method_result, token, {:ok, %{"success" => true}} = result}

    assert {:push, {:text, frame}, ^state} =
             Connection.handle_info({:method_result, token, result}, pending_state)

    assert Jason.decode!(frame)["ok"] == true
  end
end
