defmodule LemonControlPlane.ACP.SessionUpdatesTest do
  use ExUnit.Case, async: true

  alias LemonControlPlane.ACP.SessionUpdates
  alias LemonAi.Types.{AssistantMessage, TextContent, Usage}
  alias LemonAgent.Types.AgentToolResult

  test "native bus starts, streams, completes tools and publishes todo plan" do
    state = SessionUpdates.new("session", cwd: "/workspace")

    {updates, state} =
      SessionUpdates.map_event(
        state,
        action("tool_1", "read", %{"path" => "README.md"}, :started)
      )

    assert [start] = Enum.map(updates, &update/1)
    assert start["sessionUpdate"] == "tool_call"
    assert start["kind"] == "read"
    assert start["status"] == "pending"

    {updates, state} =
      SessionUpdates.map_event(state, action("tool_1", "read", %{}, :completed, "file content"))

    assert [finish] = Enum.map(updates, &update/1)
    assert finish["status"] == "completed"
    assert finish["content"] == [text("file content")]

    {updates, state} =
      SessionUpdates.map_event(
        state,
        {:tool_execution_start, "edit", "edit", %{"path" => "README.md"}}
      )

    assert hd(updates) |> update() |> Map.get("locations") == [
             %{"path" => "/workspace/README.md"}
           ]

    result = %AgentToolResult{
      content: [%TextContent{text: "Edited"}],
      details: %{path: "README.md", oldText: "before", newText: "after", first_changed_line: 1}
    }

    {updates, state} =
      SessionUpdates.map_event(state, {:tool_execution_end, "edit", "edit", result, false})

    assert %{
             "type" => "diff",
             "path" => "/workspace/README.md",
             "oldText" => "before",
             "newText" => "after"
           } in update(hd(updates))["content"]

    assert update(hd(updates))["locations"] == [%{"path" => "/workspace/README.md", "line" => 1}]

    {updates, state} =
      SessionUpdates.map_event(
        state,
        {:tool_execution_start, "bash", "bash", %{"command" => "printf hello"}}
      )

    assert update(hd(updates))["title"] == "$ printf hello"
    assert update(hd(updates))["kind"] == "execute"

    {updates, state} =
      SessionUpdates.map_event(
        state,
        {:tool_execution_update, "bash", "bash", %{"command" => "printf hello"}, "hel"}
      )

    assert update(hd(updates))["status"] == "in_progress"
    assert update(hd(updates))["content"] == [text("$ printf hello"), text("hel")]

    {updates, state} =
      SessionUpdates.map_event(
        state,
        {:tool_execution_end, "bash", "bash", %{details: %{terminalId: "term"}}, false}
      )

    assert %{"type" => "terminal", "terminalId" => "term"} in update(hd(updates))["content"]

    todos = [
      %{content: "Ship", status: "in_progress"},
      %{content: "Removed", status: "abandoned"},
      %{content: "Credentials", status: "blocked", phase: "Release", blocker: "Need access"}
    ]

    {_, state} =
      SessionUpdates.map_event(
        state,
        {:tool_execution_start, "todo", "todo", %{action: "write", todos: todos}}
      )

    {updates, state} =
      SessionUpdates.map_event(
        state,
        {:tool_execution_end, "todo", "todo", %{content: [], details: %{todos: todos}}, false}
      )

    assert [tool] = Enum.map(updates, &update/1)
    assert tool["status"] == "completed"
    {[notification], _state} = SessionUpdates.map_event(state, {:todos_changed, todos})
    plan = update(notification)

    assert plan == %{
             "sessionUpdate" => "plan",
             "entries" => [
               %{"content" => "Ship", "priority" => "medium", "status" => "in_progress"},
               %{"content" => "Removed", "priority" => "medium", "status" => "abandoned"},
               %{
                 "content" => "Credentials",
                 "priority" => "medium",
                 "status" => "blocked",
                 "phase" => "Release",
                 "blocker" => "Need access"
               }
             ]
           }
  end

  test "streamed text and thought chunks keep message identity and final text does not duplicate" do
    state = SessionUpdates.new("session")

    message = %AssistantMessage{
      content: [%TextContent{text: "hello"}],
      usage: %Usage{input: 10, output: 2, total_tokens: 12}
    }

    {_, state} = SessionUpdates.map_event(state, {:message_start, message})

    {text_updates, state} =
      SessionUpdates.map_event(
        state,
        {:message_update, message, {:text_delta, 0, "hello", message}}
      )

    {thought_updates, state} =
      SessionUpdates.map_event(
        state,
        {:message_update, message, {:thinking_delta, 0, "thinking", message}}
      )

    assert update(hd(text_updates))["messageId"] == update(hd(thought_updates))["messageId"]
    assert update(hd(thought_updates))["sessionUpdate"] == "agent_thought_chunk"
    assert {[], ^state} = SessionUpdates.map_event(state, {:message_end, message})

    {updates, state} =
      SessionUpdates.map_event(state, %{
        type: :engine_completed,
        payload: %{ok: true, answer: "hello", usage: %{total_tokens: 12}}
      })

    assert [%{"sessionUpdate" => "session_info_update", "token_count" => %{"totalTokens" => 12}}] =
             Enum.map(updates, &Map.take(update(&1), ["sessionUpdate", "token_count"]))

    assert {[], _} =
             SessionUpdates.map_event(state, %{
               type: :run_completed,
               payload: %{completed: %{answer: "hello"}}
             })
  end

  test "untrusted large raw outputs and rich collections remain bounded and UTF8" do
    output = String.duplicate("🙂", 100_000)

    result = %{
      content: [%{type: "text", text: output}],
      details: %{nested: Enum.map(1..1000, fn _ -> %{text: output} end)}
    }

    updates =
      updates_for(
        "session",
        {:tool_execution_end, "id", "read", result, false}
      )

    assert [notification] = updates
    encoded = Jason.encode!(notification)
    assert byte_size(encoded) < 40_000
    assert String.valid?(encoded)
    assert byte_size(hd(update(notification)["content"])["content"]["text"]) <= 4_000
  end

  test "large file snapshots are not emitted as truncated typed diffs" do
    result = %{
      details: %{
        path: "file",
        oldText: String.duplicate("a", 17_000),
        newText: "new",
        diff: "-old\n+new"
      }
    }

    [notification] =
      updates_for(
        "session",
        {:tool_execution_end, "id", "edit", result, false},
        cwd: "/workspace"
      )

    assert Enum.all?(update(notification)["content"], &(&1["type"] != "diff"))
    assert text("-old\n+new") in update(notification)["content"]
  end

  test "internal resource subjects never become editor paths" do
    [notification] =
      updates_for(
        "session",
        {:tool_execution_start, "id", "write", %{path: "xd://tool", content: "{}"}},
        cwd: "/workspace"
      )

    assert update(notification)["kind"] == "execute"
    refute Map.has_key?(update(notification), "locations")
    assert update(notification)["title"] == "xd://tool"
  end

  test "usage, compaction and failed tools use client supported updates" do
    [notification] =
      updates_for("session", %{
        type: :usage,
        payload: %{contextWindow: 200_000, context_tokens: 123, total_tokens: 500}
      })

    assert update(notification)["sessionUpdate"] == "usage_update"
    assert update(notification)["used"] == 123

    [notification] =
      updates_for(
        "session",
        {:compaction_complete, %{id: "compact", summary: "short"}}
      )

    assert update(notification) == %{
             "sessionUpdate" => "compaction_update",
             "compactionId" => "compact",
             "status" => "completed",
             "summary" => "short"
           }

    [notification] =
      updates_for(
        "session",
        {:tool_execution_end, "id", "bash", "failed", true}
      )

    assert update(notification)["status"] == "failed"
  end

  test "operator projection preserves complete diffs beyond preview size" do
    original = String.duplicate("x", 8_000)
    details = %{path: "/workspace/file", oldText: original, newText: original <> "y"}
    projected = CodingAgent.Session.Presentation.operator_details(details)
    assert projected.oldText == original
    assert projected.newText == original <> "y"

    oversized =
      CodingAgent.Session.Presentation.operator_details(%{
        details
        | oldText: String.duplicate("x", 17_000)
      })

    refute Map.has_key?(oversized, :oldText)
    refute Map.has_key?(oversized, :newText)
  end

  test "retry notices do not suppress a final non-streamed answer" do
    state = SessionUpdates.new("session")

    {notices, state} =
      SessionUpdates.map_event(state, {:provider_retry, %{attempt: 1, delay_ms: 100}})

    assert update(hd(notices))["sessionUpdate"] == "notice"

    {updates, _state} =
      SessionUpdates.map_event(state, %{
        type: :run_completed,
        payload: %{completed: %{ok: true, answer: "done"}}
      })

    assert update(hd(updates))["content"]["text"] == "done"
  end

  test "subagent progress retains child identity and valid lifecycle state" do
    result = %AgentToolResult{
      content: [%TextContent{text: "Reading"}],
      details: %{session_id: "child", task_id: "task", status: "running"}
    }

    {updates, _state} =
      SessionUpdates.map_event(
        SessionUpdates.new("parent"),
        {:tool_execution_update, "call", "task", %{}, result}
      )

    assert %{"sessionUpdate" => "subagent_update", "sessionId" => "child", "state" => "running"} in Enum.map(
             updates,
             &update/1
           )
  end

  test "latest request context gauge is distinct from cumulative usage" do
    messages = [
      %AssistantMessage{usage: %Usage{input: 10, output: 5, total_tokens: 15}},
      %AssistantMessage{usage: %Usage{input: 20, output: 3, cache_read: 7, total_tokens: 30}}
    ]

    usage = CodingAgent.Session.Presentation.build_usage(messages)
    assert usage.total_tokens == 45
    assert usage.context_tokens == 30

    {updates, _state} =
      SessionUpdates.map_event(
        SessionUpdates.new("session", context_window: 200_000),
        {:agent_end, messages}
      )

    assert update(hd(updates))["sessionUpdate"] == "usage_update"
    assert update(hd(updates))["used"] == 30
  end

  test "native images and deletion diffs use valid ACP content fields" do
    result = %AgentToolResult{
      content: [%LemonAi.Types.ImageContent{mime_type: "image/png", data: "eA=="}],
      details: %{path: "/workspace/deleted", oldText: "old"}
    }

    [notification] =
      updates_for(
        "session",
        {:tool_execution_end, "delete", "delete", result, false}
      )

    assert %{
             "type" => "content",
             "content" => %{"type" => "image", "mimeType" => "image/png", "data" => "eA=="}
           } in update(notification)["content"]

    assert %{
             "type" => "diff",
             "path" => "/workspace/deleted",
             "oldText" => "old",
             "newText" => ""
           } in update(notification)["content"]
  end

  test "thought deltas continue beyond the cumulative preview bound" do
    presentation = CodingAgent.Session.Presentation

    {:emit, _start, accumulator} =
      presentation.reasoning_action(
        {:thinking_start, 0, nil},
        presentation.new_reasoning_accumulator()
      )

    piece = String.duplicate("t", 1_000)

    {accumulator, mapper, emitted} =
      Enum.reduce(1..40, {accumulator, SessionUpdates.new("session"), []}, fn _,
                                                                              {accumulator,
                                                                               mapper, emitted} ->
        {:emit, action, accumulator} =
          presentation.reasoning_action({:thinking_delta, 0, piece, nil}, accumulator)

        {updates, mapper} =
          SessionUpdates.map_event(mapper, %{
            type: :engine_action,
            payload: %{action: action, phase: action.phase}
          })

        {accumulator, mapper, emitted ++ updates}
      end)

    {:emit, action, _accumulator} =
      presentation.reasoning_action(
        {:thinking_end, 0, String.duplicate(piece, 40), nil},
        accumulator
      )

    {updates, _mapper} =
      SessionUpdates.map_event(mapper, %{
        type: :engine_action,
        payload: %{action: action, phase: action.phase}
      })

    assert updates == []
    assert Enum.map_join(emitted, &update(&1)["content"]["text"]) == String.duplicate(piece, 40)
  end

  @tag :tmp_dir
  test "result hooks cannot forge actual or absent ACP mutation lines", %{tmp_dir: cwd} do
    path = Path.join(cwd, "target.txt")

    for details <- [%{first_changed_line: 999_999}, %{"first_changed_line" => 999_999}, %{}] do
      File.write!(path, "one\ntwo\nneedle\n")
      hooks = [on_tool_result: [fn _ -> {:replace, %{details: details}} end]]
      context = %{cwd: cwd, session_id: "line-proof"}

      edit =
        CodingAgent.Extensions.ToolHooks.wrap_tool(
          CodingAgent.Tools.Edit.tool(cwd),
          hooks,
          context
        )

      args = %{"path" => path, "old_text" => "needle", "new_text" => "pin"}
      result = edit.execute.("edit", args, nil, nil)
      refute result.is_error
      assert File.read!(path) == "one\ntwo\npin\n"
      state = SessionUpdates.new("line-proof", cwd: cwd)
      {_, state} = SessionUpdates.map_event(state, {:tool_execution_start, "edit", "edit", args})

      {[notification | _], _} =
        SessionUpdates.map_event(state, {:tool_execution_end, "edit", "edit", result, false})

      assert update(notification)["locations"] == [%{"path" => path, "line" => 3}]

      read =
        CodingAgent.Extensions.ToolHooks.wrap_tool(
          CodingAgent.Tools.Read.tool(cwd),
          hooks,
          context
        )

      args = %{"path" => path}
      result = read.execute.("read", args, nil, nil)
      refute result.is_error
      state = SessionUpdates.new("line-proof", cwd: cwd)
      {_, state} = SessionUpdates.map_event(state, {:tool_execution_start, "read", "read", args})

      {[notification | _], _} =
        SessionUpdates.map_event(state, {:tool_execution_end, "read", "read", result, false})

      assert update(notification)["locations"] == [%{"path" => path}]
    end
  end

  test "raw tool output omits hidden thinking and malformed locations stay bounded" do
    result = %AgentToolResult{
      content: [
        %TextContent{text: "visible", text_signature: "private"},
        %LemonAi.Types.ThinkingContent{thinking: "hidden"}
      ],
      details: %{
        path: "/workspace/file",
        first_changed_line: %{text: String.duplicate("x", 100_000)}
      }
    }

    [notification] =
      updates_for(
        "session",
        {:tool_execution_end, "call", "read", result, false}
      )

    assert update(notification)["rawOutput"]["content"] == [
             %{"type" => "text", "text" => "visible"}
           ]

    assert update(notification)["locations"] == [%{"path" => "/workspace/file"}]
    assert byte_size(Jason.encode!(notification)) < 40_000
  end

  test "multi-response costs add every component instead of replacing the previous response" do
    merged =
      CodingAgent.Session.Presentation.merge_usage(
        %{
          "cost" => %{"input" => 0.1, "output" => 0.2, "total" => 0.3, "cache_write_long" => 0.04}
        },
        %{
          cost: %LemonAi.Types.Cost{
            input: 0.3,
            output: 0.4,
            total: 0.7,
            cache_read: 0.2,
            cache_write: 0.1
          }
        }
      )

    assert_in_delta merged.cost.input, 0.4, 0.000001
    assert_in_delta merged.cost.output, 0.6, 0.000001
    assert_in_delta merged.cost.total, 1.0, 0.000001
    assert merged.cost.cache_read == 0.2
    assert merged.cost.cache_write == 0.1
    assert merged.cost.cache_write_long == 0.04
    refute Map.has_key?(merged, "cost")
  end

  test "plans preserve native priorities and canonical structured state" do
    entries = [
      %{content: "Urgent", status: "in_progress", priority: "high"},
      %{content: "Later", status: "pending", priority: "low"}
    ]

    result = %{
      details: %{todos: [%{content: "Filtered", status: "pending"}], plan: %{entries: entries}}
    }

    [tool] = updates_for("session", {:tool_execution_end, "todo", "todo", result, false})
    assert update(tool)["sessionUpdate"] == "tool_call_update"
    [notification] = updates_for("session", {:todos_changed, entries})

    assert update(notification)["entries"] == [
             %{"content" => "Urgent", "status" => "in_progress", "priority" => "high"},
             %{"content" => "Later", "status" => "pending", "priority" => "low"}
           ]
  end

  test "oversized plan entries obey the rendered collection budget" do
    entries =
      Enum.map(1..100, fn _ -> %{content: String.duplicate("x", 4_000), status: "pending"} end)

    [notification] = updates_for("session", {:todos_changed, entries})

    assert length(update(notification)["entries"]) < 100
    assert byte_size(Jason.encode!(update(notification)["entries"])) < 66_000
  end

  test "semantic cancellation emits no fabricated assistant error but real failures remain visible" do
    state = SessionUpdates.new("session")
    {[], cancelled} = SessionUpdates.map_event(state, {:cancel_requested})

    {[], _state} =
      SessionUpdates.map_event(cancelled, %{
        type: :run_completed,
        payload: %{ok: false, error: "acp_cancel"}
      })

    assert [] ==
             updates_for("session", %{
               type: :run_completed,
               payload: %{ok: false, error: :acp_cancel}
             })

    [notice] =
      updates_for("session", %{
        type: :run_completed,
        payload: %{ok: false, error: "Provider denied the request"}
      })

    assert update(notice)["sessionUpdate"] == "notice"
    assert update(notice)["severity"] == "error"
    assert update(notice)["description"] == "Provider denied the request"
  end

  test "permission previews describe bounded proposals without inventing file snapshots" do
    for {name, args, label} <- [
          {"edit", %{path: "file", old_string: "before", new_string: "after"},
           "Requested replacement fragments"},
          {"write", %{path: "file", content: String.duplicate("x", 10_000)},
           "Proposed file content"},
          {"patch", %{patch_text: "*** Begin Patch\n*** End Patch"}, "Requested patch"}
        ] do
      notification = SessionUpdates.tool_call("session", "call", name, args, cwd: "/workspace")

      assert [%{"type" => "content", "content" => %{"type" => "text", "text" => preview}}] =
               update(notification)["content"]

      assert String.starts_with?(preview, label)
      assert byte_size(preview) <= 4_000
    end
  end

  test "live tool cards retain explicit native identity for permission and history correlation" do
    start = %{
      type: :engine_action,
      payload: %{
        phase: :started,
        action: %{
          id: "tool_call_native",
          kind: "command",
          detail: %{tool_call_id: "call_native", name: "bash", args: %{command: "pwd"}}
        }
      }
    }

    finish = %{
      type: :engine_action,
      payload: %{
        phase: :completed,
        ok: true,
        action: %{
          id: "tool_call_native",
          kind: "command",
          detail: %{tool_call_id: "call_native", name: "bash", result: "/workspace"}
        }
      }
    }

    {[start], mapper} = SessionUpdates.map_event(SessionUpdates.new("session"), start)
    {[finish], _mapper} = SessionUpdates.map_event(mapper, finish)
    assert update(start)["toolCallId"] == "call_native"
    assert update(finish)["toolCallId"] == "call_native"
    assert text("$ pwd") in update(finish)["content"]
  end

  defp updates_for(session_id, event, opts \\ []) do
    {updates, _state} = SessionUpdates.map_event(SessionUpdates.new(session_id, opts), event)
    updates
  end

  defp update(notification), do: notification["params"]["update"]
  defp text(value), do: %{"type" => "content", "content" => %{"type" => "text", "text" => value}}

  defp action(id, name, args, phase, result \\ nil) do
    %{
      type: :engine_action,
      payload: %{
        phase: phase,
        ok: true,
        action: %{id: id, kind: "tool", detail: %{name: name, args: args, result: result}}
      }
    }
  end
end
