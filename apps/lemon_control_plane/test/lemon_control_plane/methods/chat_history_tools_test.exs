defmodule LemonControlPlane.Methods.ChatHistoryToolsTest do
  use ExUnit.Case, async: false
  alias LemonControlPlane.Methods.ChatHistory
  alias LemonCore.AgentRuntime
  alias LemonAi.Types.{AssistantMessage, ToolCall, ToolResultMessage, TextContent}

  defmodule Provider do
    def session_history(_key, _cwd), do: {:ok, Process.get(:native_history_entries, [])}

    def child_session_history(key, child_id) do
      send(Process.get(:history_observer), {:child_history, key, child_id})

      case Process.get(:child_history) do
        {^key, ^child_id, entries} -> {:ok, entries}
        _ -> {:error, :session_not_found}
      end
    end
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

  describe "childSessionId" do
    setup do
      Process.put(:history_observer, self())

      Process.put(
        :child_history,
        {"agent:default:parent", "child-native-id",
         [
           %{
             type: :message,
             id: "child-user",
             message: %{"role" => "user", "content" => "child prompt", "timestamp" => 1}
           },
           %{
             type: :message,
             id: "child-answer",
             message: %{"role" => "assistant", "content" => "child answer", "timestamp" => 2}
           }
         ]}
      )

      :ok
    end

    test "returns the delegated child's transcript scoped to the caller's session" do
      assert {:ok,
              %{
                "sessionKey" => "agent:default:parent",
                "childSessionId" => "child-native-id",
                "messages" => messages
              }} =
               ChatHistory.handle(
                 %{
                   "sessionKey" => "agent:default:parent",
                   "childSessionId" => "child-native-id",
                   "cwd" => File.cwd!()
                 },
                 %{}
               )

      assert_received {:child_history, "agent:default:parent", "child-native-id"}
      assert Enum.map(messages, & &1["role"]) == ["user", "assistant"]
      assert Enum.map(messages, & &1["content"]) == ["child prompt", "child answer"]
    end

    test "pages like the owned history" do
      assert {:ok, %{"messages" => [last]}} =
               ChatHistory.handle(
                 %{
                   "sessionKey" => "agent:default:parent",
                   "childSessionId" => "child-native-id",
                   "limit" => 1
                 },
                 %{}
               )

      assert last["content"] == "child answer"
    end

    test "another session's key or an unknown child is not found, never a fallback read" do
      for params <- [
            %{"sessionKey" => "agent:default:stranger", "childSessionId" => "child-native-id"},
            %{"sessionKey" => "agent:default:parent", "childSessionId" => "other-child"}
          ] do
        assert {:error, {:not_found, _message, _details}} = ChatHistory.handle(params, %{})
      end
    end

    test "rejects a non-string childSessionId" do
      assert {:error, {:invalid_params, _message, _}} =
               ChatHistory.handle(
                 %{"sessionKey" => "agent:default:parent", "childSessionId" => 7},
                 %{}
               )

      assert {:error, {:invalid_params, _message, _}} =
               ChatHistory.handle(
                 %{"sessionKey" => "agent:default:parent", "childSessionId" => ""},
                 %{}
               )
    end
  end
end
