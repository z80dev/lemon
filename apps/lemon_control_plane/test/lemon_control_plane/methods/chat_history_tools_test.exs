defmodule LemonControlPlane.Methods.ChatHistoryToolsTest do
  use ExUnit.Case, async: false
  alias LemonControlPlane.Methods.ChatHistory
  alias LemonCore.AgentRuntime
  alias LemonAi.Types.{AssistantMessage, ToolCall, ToolResultMessage, TextContent}

  defmodule Provider do
    def session_history(_key, _cwd), do: {:ok, Process.get(:native_history_entries, [])}
  end

  setup do
    previous = Application.get_env(:lemon_core, :agent_runtime_provider)
    :ok = AgentRuntime.register(Provider)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:lemon_core, :agent_runtime_provider, previous),
        else: Application.delete_env(:lemon_core, :agent_runtime_provider)
    end)

    :ok
  end

  test "native call and terminal cancellation reach history with actual output and identity" do
    Process.put(:native_history_entries, [
      %{
        type: :message,
        id: "call-message",
        message: %AssistantMessage{
          content: [
            %ToolCall{
              id: "native-call",
              name: "bash",
              arguments: %{"command" => "echo STARTED; sleep 30"}
            }
          ],
          timestamp: 101
        }
      },
      %{
        type: :message,
        id: "result-message",
        message: %ToolResultMessage{
          tool_call_id: "native-call",
          tool_name: "bash",
          is_error: true,
          content: [%TextContent{text: "STARTED\n"}],
          details: %{cancelled: true, outcome: "unknown", partial: true},
          timestamp: 201
        }
      }
    ])

    assert {:ok, %{"messages" => [call, result]}} =
             ChatHistory.handle(
               %{"sessionKey" => "agent:default:history-tools", "cwd" => File.cwd!()},
               %{}
             )

    assert call["role"] == "tool_use"
    assert result["role"] == "tool_result"
    assert call["toolCallId"] == result["toolCallId"]
    assert result["arguments"]["command"] == "echo STARTED; sleep 30"
    assert result["cancelled"] == true
    assert result["ok"] == false
    assert result["content"] == "STARTED\n"
    assert result["details"]["outcome"] == "unknown"
    assert result["durationMs"] == nil
  end

  test "legacy cancellation closes only the unmatched tool, preserving real completed tools" do
    key = "agent:default:history-tools-#{System.unique_integer([:positive])}"

    LemonCore.RunHistoryStore.put(key, 100, "legacy-run", %{
      started_at: 100,
      summary: %{prompt: "Read and run", completed: %{ok: false, answer: "", error: :acp_cancel}},
      events: [
        %{
          phase: :updated,
          action: %{
            id: "bash-action",
            kind: :tool,
            title: "bash",
            detail: %{
              tool_call_id: "bash-native",
              name: "bash",
              args: %{"command" => "echo STARTED; sleep 30"},
              partial_result: %{content: [%{type: :text, text: "STARTED\n"}], details: %{}}
            }
          }
        },
        %{
          phase: :completed,
          ok: true,
          action: %{
            id: "read-action",
            kind: :tool,
            title: "read",
            detail: %{
              tool_call_id: "read-native",
              name: "read",
              args: %{"path" => "sample.txt"},
              result_full: "ACTUAL FILE"
            }
          }
        }
      ]
    })

    assert {:ok, %{"messages" => rows}} = ChatHistory.handle(%{"sessionKey" => key}, %{})
    [read, bash] = Enum.filter(rows, &(&1["role"] == "tool_result"))
    assert read["toolCallId"] == "read-native"
    assert read["ok"] == true
    refute read["cancelled"]
    assert read["content"] == "ACTUAL FILE"
    assert bash["toolCallId"] == "bash-native"
    assert bash["phase"] == "completed"
    assert bash["cancelled"]
    assert bash["content"] == "STARTED\n"
    assert bash["details"]["outcome"] == "unknown"
  end
end
