defmodule LemonChannels.Telegram.PerChatStateTest do
  use ExUnit.Case, async: false

  alias LemonChannels.Adapters.Telegram.Transport.PerChatState
  alias LemonChannels.Adapters.Telegram.Transport.ResumeSelection
  alias LemonCore.{ChatState, ResumeToken, RouterBridge}

  defmodule PerChatStateAbortRouter do
    use LemonCore.RouterBridge.Router

    def abort(session_key, reason) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:abort, session_key, reason})
      :persistent_term.get({__MODULE__, :result})
    end
  end

  setup do
    previous_bridge = Application.get_env(:lemon_core, :router_bridge)
    :persistent_term.put({PerChatStateAbortRouter, :test_pid}, self())
    :ok = RouterBridge.configure(router: PerChatStateAbortRouter)

    on_exit(fn ->
      :persistent_term.erase({PerChatStateAbortRouter, :test_pid})
      :persistent_term.erase({PerChatStateAbortRouter, :result})
      restore_router_bridge(previous_bridge)
    end)

    :ok
  end

  test "switching_session reads core chat state structs" do
    state = %ChatState{last_engine: "codex", last_resume_token: "thread-1"}

    refute ResumeSelection.switching_session?(state, %ResumeToken{
             engine: "codex",
             value: "thread-1"
           })

    assert ResumeSelection.switching_session?(state, %ResumeToken{
             engine: "claude",
             value: "thread-1"
           })
  end

  test "safe abort preserves definite and ambiguous mutation failures" do
    session_key = "telegram:per-chat-state"

    :persistent_term.put({PerChatStateAbortRouter, :result}, {:error, :outcome_unknown})
    assert {:error, :outcome_unknown} = PerChatState.safe_abort_session(session_key, :new_session)
    assert_receive {:abort, ^session_key, :new_session}

    :persistent_term.put({PerChatStateAbortRouter, :result}, {:error, :busy})
    assert {:error, :busy} = PerChatState.safe_abort_session(session_key, :user_requested)
    assert_receive {:abort, ^session_key, :user_requested}

    assert {:error, :invalid_session_key} = PerChatState.safe_abort_session(nil, :new_session)
    refute_receive {:abort, _, _}
  end

  defp restore_router_bridge(nil), do: Application.delete_env(:lemon_core, :router_bridge)
  defp restore_router_bridge(config), do: Application.put_env(:lemon_core, :router_bridge, config)
end
