defmodule LemonChannels.Adapters.Telegram.ApprovalRequestTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Adapters.Telegram.Transport.ApprovalRequest

  defmodule ApprovalRequestMockAPI do
    def send_message(_token, chat_id, text, opts, parse_mode) do
      send(self_pid(), {:send_message, chat_id, text, opts, parse_mode})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 123}}}
    end

    defp self_pid do
      :persistent_term.get({__MODULE__, :pid})
    end
  end

  setup do
    :persistent_term.put({ApprovalRequestMockAPI, :pid}, self())

    on_exit(fn ->
      :persistent_term.erase({ApprovalRequestMockAPI, :pid})
    end)

    :ok
  end

  test "sends approval request to the Telegram topic with inline actions" do
    state = %{
      account_id: "default",
      api_mod: ApprovalRequestMockAPI,
      token: "token"
    }

    payload = %{
      approval_id: "appr_123",
      pending: %{
        session_key: "agent:default:telegram:default:group:-1003842984060:thread:35",
        tool: "bash",
        action: %{"command" => "echo APPROVED"}
      }
    }

    assert :ok = ApprovalRequest.send(state, payload)

    assert_receive {:send_message, -1_003_842_984_060, text, opts, nil}

    assert text =~ "Approval requested: bash"
    assert text =~ "Action: echo APPROVED"
    assert opts["message_thread_id"] == 35

    assert %{"inline_keyboard" => [[approve, deny], [_session, _agent, _global]]} =
             opts["reply_markup"]

    assert approve["text"] == "Approve once"
    assert approve["callback_data"] == "appr_123|once"
    assert deny["callback_data"] == "appr_123|deny"
  end
end
