defmodule LemonOmp.ProjectionTest do
  use ExUnit.Case, async: true

  alias LemonOmp.Projection

  defp new(attrs \\ []) do
    Projection.new(
      Keyword.merge(
        [
          id: "omp_test",
          cwd: "/work",
          prompt: "Fix the build\nthen run tests",
          owner: %{kind: :operator}
        ],
        attrs
      )
    )
  end

  defp apply_all(state, events) do
    Enum.reduce(events, state, fn {type, frame}, acc ->
      Projection.apply_event(acc, type, Map.put(frame, "type", type))
    end)
  end

  defp running(state \\ new()), do: apply_all(state, [{"agent_start", %{}}])

  defp tool_start(id, name, intent \\ nil),
    do: {"tool_execution_start", %{"toolCallId" => id, "toolName" => name, "intent" => intent}}

  defp tool_end(id, name, extra \\ %{}),
    do: {"tool_execution_end", Map.merge(%{"toolCallId" => id, "toolName" => name}, extra)}

  defp assistant_end(text, usage \\ nil, extra \\ %{}) do
    message =
      Map.merge(
        %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => text}],
          "usage" => usage,
          "stopReason" => "stop"
        },
        extra
      )

    {"message_end", %{"message" => message}}
  end

  describe "new/1" do
    test "starts with a title from the first prompt line" do
      state = new()
      assert state.status == :starting
      assert state.title == "Fix the build"
      assert is_integer(state.started_at)

      long = String.duplicate("t", 500)
      assert String.length(new(prompt: long).title) == 120
      assert new(prompt: "  \n  ").title == nil
      assert new(prompt: nil).title == nil
    end
  end

  describe "turn lifecycle" do
    test "agent_start runs, turn_start counts turns" do
      state = apply_all(new(), [{"agent_start", %{}}, {"turn_start", %{}}, {"turn_start", %{}}])
      assert state.status == :running
      assert state.activity == "Thinking"
      assert state.turns == 2
    end

    test "agent_end defers settling until prompt_result" do
      state =
        apply_all(running(), [assistant_end("All done"), {"agent_end", %{"isTerminal" => true}}])

      assert state.status == :running
      assert state.settling
      assert state.activity == "Finishing turn"

      state =
        apply_all(state, [{"prompt_result", %{"status" => "completed", "agentInvoked" => true}}])

      assert state.status == :idle
      refute state.settling
      assert state.activity == nil
      assert state.last_turn == :completed
      assert state.result == "All done"
    end

    test "redirect holds the aborted verdict running until a fresh agent_start" do
      state =
        %{running() | redirecting: true}
        |> apply_all([
          {"agent_end", %{"isTerminal" => true}},
          {"prompt_result", %{"status" => "aborted"}},
          {"session_settled", %{}}
        ])

      assert state.status == :running
      assert state.last_turn == :aborted
      assert state.activity == "Redirecting turn"
      assert state.settling

      state = apply_all(state, [{"agent_start", %{}}, {"turn_start", %{}}])
      assert state.status == :running
      refute state.settling
      refute state.redirecting

      state =
        apply_all(state, [
          assistant_end("New result"),
          {"agent_end", %{"isTerminal" => true}},
          {"prompt_result", %{"status" => "completed"}}
        ])

      assert state.status == :idle
      assert state.last_turn == :completed
      assert state.result == "New result"
    end

    test "a non-terminal agent_end does not start settling" do
      state = apply_all(running(), [{"agent_end", %{"isTerminal" => false}}])
      assert state.status == :running
      refute state.settling
    end

    test "agent_end outside a turn is ignored" do
      state = apply_all(new(), [{"agent_end", %{"isTerminal" => true}}])
      assert state.status == :starting
      refute state.settling
    end

    test "session_settled settles without changing the verdict" do
      state = apply_all(running(), [{"agent_end", %{}}, {"session_settled", %{}}])
      assert state.status == :idle
      assert state.last_turn == nil
    end

    test "prompt_result records aborted and error verdicts with the error message" do
      aborted = apply_all(running(), [{"prompt_result", %{"status" => "aborted"}}])
      assert aborted.last_turn == :aborted

      errored =
        apply_all(running(), [
          {"prompt_result",
           %{"status" => "error", "error" => %{"message" => "rate \e[31mlimited\e[0m"}}}
        ])

      assert errored.last_turn == :error
      assert errored.error == "rate limited"

      # An unknown status keeps the previous verdict.
      odd = apply_all(errored, [{"agent_start", %{}}, {"prompt_result", %{"status" => "weird"}}])
      assert odd.last_turn == :error
    end

    test "agent_start clears a previous error" do
      state =
        apply_all(running(), [
          assistant_end("", nil, %{"stopReason" => "error", "errorMessage" => "boom"})
        ])

      assert state.error == "boom"
      assert apply_all(state, [{"agent_start", %{}}]).error == nil
    end

    test "settle/1 and finish/3 never reopen ended sessions" do
      closed = Projection.finish(running(), :closed, %{code: 0, reason: :closed})
      assert closed.status == :closed
      assert closed.exit == %{code: 0, reason: :closed}
      assert is_integer(closed.ended_at)
      assert Projection.settle(closed).status == :closed

      failed =
        Projection.finish(running(), :failed, %{
          code: 3,
          reason: :crashed,
          error: "omp exited \e[1mbadly"
        })

      assert failed.status == :failed
      assert failed.error == "omp exited badly"
      assert failed.active_tools == []
      assert failed.activity == nil
    end
  end

  describe "tools" do
    test "tracks active tools, recent tools and activity" do
      state =
        apply_all(running(), [
          tool_start("c1", "bash", "Running tests"),
          tool_start("c2", "read")
        ])

      assert state.tool_calls == 2
      assert Enum.map(state.active_tools, & &1.id) == ["c1", "c2"]
      assert state.activity == "Running read"

      state = apply_all(state, [tool_end("c2", "read")])
      assert state.activity == "Running bash — Running tests"
      assert [%{name: "read", is_error: false, duration_ms: ms}] = state.recent_tools
      assert is_integer(ms) and ms >= 0

      state = apply_all(state, [tool_end("c1", "bash", %{"isError" => true})])
      assert state.active_tools == []
      assert state.activity == "Thinking"

      assert [%{name: "read"}, %{name: "bash", intent: "Running tests", is_error: true}] =
               state.recent_tools
    end

    test "bounds active and recent tools, newest last" do
      starts = for i <- 1..30, do: tool_start("c#{i}", "t#{i}")
      state = apply_all(running(), starts)

      assert length(state.active_tools) == 16
      assert List.last(state.active_tools).id == "c30"
      assert state.tool_calls == 30

      ends = for i <- 15..30, do: tool_end("c#{i}", "t#{i}")
      state = apply_all(state, ends)

      assert length(state.recent_tools) == 8
      assert List.last(state.recent_tools).name == "t30"
      assert hd(state.recent_tools).name == "t23"
    end

    test "an end without a matching start still records the tool" do
      state = apply_all(running(), [tool_end("ghost", "edit")])
      assert [%{name: "edit", intent: nil, duration_ms: nil}] = state.recent_tools
    end
  end

  describe "todos" do
    @phases [
      %{
        "name" => "Tasks",
        "tasks" => [
          %{"content" => "Read README.md", "status" => "completed"},
          %{"content" => "Write tests", "status" => "in_progress"},
          %{"status" => "pending"}
        ]
      },
      %{"name" => "Later", "tasks" => [%{"content" => "Ship", "status" => "pending"}]},
      "not a phase"
    ]

    test "come from the todo tool's result details" do
      state =
        apply_all(running(), [
          tool_end("t", "todo", %{"result" => %{"details" => %{"phases" => @phases}}})
        ])

      assert state.todos == [
               %{phase: "Tasks", content: "Read README.md", status: "completed"},
               %{phase: "Tasks", content: "Write tests", status: "in_progress"},
               %{phase: "Later", content: "Ship", status: "pending"}
             ]

      assert apply_all(state, [{"todo_auto_clear", %{}}]).todos == []
    end

    test "other tools' phases are ignored" do
      state =
        apply_all(running(), [
          tool_end("t", "bash", %{"result" => %{"details" => %{"phases" => @phases}}})
        ])

      assert state.todos == []
    end

    test "are bounded" do
      tasks =
        for i <- 1..80,
            do: %{"content" => "task #{i} " <> String.duplicate("x", 400), "status" => "pending"}

      phases = [%{"name" => "Big", "tasks" => tasks}]

      state =
        apply_all(running(), [
          tool_end("t", "todo", %{"result" => %{"details" => %{"phases" => phases}}})
        ])

      assert length(state.todos) == 50
      assert Enum.all?(state.todos, &(String.length(&1.content) <= 200))
    end
  end

  describe "subagents" do
    test "follow lifecycle and progress events by index or id" do
      state =
        apply_all(running(), [
          {"subagent_lifecycle",
           %{
             "payload" => %{
               "index" => 0,
               "id" => "sa-1",
               "agent" => "explore",
               "status" => "started",
               "task" => "Map the repo"
             }
           }},
          {"subagent_progress", %{"payload" => %{"index" => 0, "description" => "Reading lib/"}}},
          {"subagent_lifecycle",
           %{"payload" => %{"id" => "sa-2", "agent" => "task", "status" => "started"}}},
          {"subagent_lifecycle", %{"payload" => %{"index" => 0, "status" => "completed"}}},
          {"subagent_lifecycle", %{"payload" => %{"status" => "started"}}},
          {"subagent_progress", %{"payload" => "nope"}}
        ])

      wire = Projection.to_wire(state)

      assert wire["subagents"] == [
               %{
                 "id" => "sa-1",
                 "agent" => "explore",
                 "status" => "completed",
                 "description" => "Reading lib/"
               },
               %{"id" => "sa-2", "agent" => "task", "status" => "running", "description" => nil}
             ]
    end

    test "are bounded" do
      events =
        for i <- 1..30 do
          {"subagent_lifecycle",
           %{"payload" => %{"index" => i, "agent" => "a#{i}", "status" => "started"}}}
        end

      state = apply_all(running(), events)
      assert map_size(state.subagents) == 20

      # Known subagents keep updating at the cap.
      state =
        apply_all(state, [
          {"subagent_lifecycle", %{"payload" => %{"index" => 1, "status" => "failed"}}}
        ])

      assert hd(Projection.to_wire(state)["subagents"])["status"] == "failed"
    end
  end

  describe "usage" do
    test "accumulates from assistant message_end and is replaced by stats" do
      usage = %{
        "input" => 100,
        "output" => 20,
        "cacheRead" => 50,
        "cacheWrite" => 5,
        "totalTokens" => 175,
        "cost" => %{"total" => 0.25}
      }

      state =
        apply_all(running(), [
          assistant_end("one", usage, %{"provider" => "anthropic", "model" => "claude"}),
          assistant_end("two", usage),
          {"message_end", %{"message" => %{"role" => "user", "usage" => usage}}},
          assistant_end("bad", %{"input" => -5, "output" => "lots", "cost" => "free"})
        ])

      assert state.usage == %{
               input: 200,
               output: 40,
               cache_read: 100,
               cache_write: 10,
               total_tokens: 350,
               cost: 0.5
             }

      assert state.model == "anthropic/claude"
      assert state.last_text == "bad"

      state =
        Projection.apply_stats(state, %{
          "sessionId" => "01abc",
          "tokens" => %{
            "input" => 7,
            "output" => 3,
            "cacheRead" => 0,
            "cacheWrite" => 0,
            "total" => 10
          },
          "cost" => 0.01,
          "contextUsage" => %{"percent" => 12.345}
        })

      assert state.usage == %{
               input: 7,
               output: 3,
               cache_read: 0,
               cache_write: 0,
               total_tokens: 10,
               cost: 0.01
             }

      assert state.omp_session_id == "01abc"
      assert state.context_percent == 12.35

      assert Projection.apply_stats(state, %{"no" => "tokens"}) == state
    end
  end

  describe "text" do
    test "streams deltas while running and keeps the latest assistant text" do
      state =
        apply_all(running(), [
          {"message_update",
           %{"assistantMessageEvent" => %{"type" => "text_delta", "delta" => "Hel"}}},
          {"message_update",
           %{"assistantMessageEvent" => %{"type" => "text_delta", "delta" => "lo"}}}
        ])

      assert state.activity == "Writing response"
      assert Projection.to_wire(state)["lastText"] == "Hello"

      state = apply_all(state, [assistant_end("Hello world")])
      assert state.stream_text == ""
      assert Projection.to_wire(state)["lastText"] == "Hello world"
    end

    test "bounds last text to its tail and the result to its head" do
      text = String.duplicate("a", 3_000) <> "END"

      state =
        apply_all(running(), [assistant_end(text), {"prompt_result", %{"status" => "completed"}}])

      assert String.length(state.last_text) == 2_000
      assert String.starts_with?(state.last_text, "…")
      assert String.ends_with?(state.last_text, "END")
      assert state.result == state.last_text
    end

    test "other message_update kinds update activity only" do
      state =
        apply_all(running(), [
          {"message_update", %{"assistantMessageEvent" => %{"type" => "toolcall_start"}}}
        ])

      assert state.activity == "Preparing a tool call"
    end
  end

  describe "state and model events" do
    test "apply_state merges identity, todos and context" do
      state =
        Projection.apply_state(new(), %{
          "sessionId" => "01xyz",
          "model" => %{"provider" => "openai", "id" => "gpt-5"},
          "thinkingLevel" => "high",
          "sessionName" => "Named \u202Esession",
          "contextUsage" => %{"percent" => 3},
          "todoPhases" => [
            %{"name" => "P", "tasks" => [%{"content" => "c", "status" => "pending"}]}
          ]
        })

      assert state.omp_session_id == "01xyz"
      assert state.model == "openai/gpt-5"
      assert state.thinking == "high"
      assert state.title == "Named session"
      assert state.context_percent == 3.0
      assert state.todos == [%{phase: "P", content: "c", status: "pending"}]
    end

    test "model_changed and compaction/retry activities" do
      state =
        apply_all(running(), [{"model_changed", %{"model" => %{"provider" => "x", "id" => "y"}}}])

      assert state.model == "x/y"
      assert apply_all(state, [{"model_changed", %{"model" => 5}}]).model == "x/y"
      assert apply_all(state, [{"auto_compaction_start", %{}}]).activity == "Compacting context"

      assert apply_all(state, [{"auto_retry_start", %{}}]).activity ==
               "Retrying after a provider error"
    end

    test "unknown events only touch updated_at" do
      state = new()
      next = Projection.apply_event(state, "brand_new_event", %{"x" => 1})
      assert %{next | updated_at: state.updated_at} == state
    end
  end

  describe "clean/2" do
    test "strips ANSI, control and bidi-override characters" do
      dirty =
        "\e[31mred\e[0m \e]0;window title\a ok\x07\x00\x1B bell \u202Eevil\u202C \u2066iso\u2069 \u200Fmark\u061C"

      assert Projection.clean(dirty, nil) == "red  ok bell evil iso mark"
    end

    test "keeps newlines and tabs, normalizes CRLF" do
      assert Projection.clean("a\r\nb\tc\nd", nil) == "a\nb\tc\nd"
    end

    test "clips with an ellipsis" do
      assert Projection.clean("abcdef", 4) == "abc…"
      assert Projection.clean("abc", 4) == "abc"
      assert Projection.clean("ééééé", 3) == "éé…"
    end

    test "non-strings become empty" do
      assert Projection.clean(nil, 10) == ""
      assert Projection.clean(42, 10) == ""
      assert Projection.clean(%{"a" => 1}, 10) == ""
    end

    test "invalid UTF-8 keeps the valid text" do
      cleaned = Projection.clean(<<0x9C, "fatal: ", 0xFF, "disk full">>, nil)
      assert String.valid?(cleaned)
      assert cleaned =~ "fatal: "
      assert cleaned =~ "disk full"
    end

    test "untrusted event strings are cleaned on the way in" do
      state =
        apply_all(running(), [
          tool_start("c\e[2J1", "ba\u202Esh", "do \e[1mthings\e[0m\x00"),
          assistant_end("hi \e]8;;http://evil\e\\link\e]8;;\e\\")
        ])

      assert [%{id: "c1", name: "bash", intent: "do things"}] = state.active_tools
      assert state.last_text == "hi link"
      assert state.activity == "Running bash — do things"
    end
  end

  describe "approvals" do
    test "bounds untrusted details and preserves waiting activity across events" do
      state =
        new(approval_mode: "always-ask")
        |> running()
        |> Projection.request_approval(
          "ap1",
          "bash\e[31m",
          String.duplicate("x", 3_000) <> "\u202e"
        )
        |> Projection.apply_event("message_update", %{
          "assistantMessageEvent" => %{"type" => "text_delta", "delta" => "still working"}
        })

      wire = Projection.to_wire(state)
      assert wire["approvalMode"] == "always-ask"
      assert wire["activity"] == "Waiting for approval: bash"
      assert [%{"id" => "ap1", "tool" => "bash", "details" => details}] = wire["pendingApprovals"]
      assert String.length(details) == 2_000
      refute details =~ "\u202e"
      assert Projection.summary(wire) =~ "exec.approval.resolve"
      assert Projection.summary(wire) =~ "Lemon's approval prompts"

      state = Projection.resolve_approval(state, "ap1", :approved)
      assert state.pending_approvals == []
      assert state.approvals == %{approved: 1, denied: 0, expired: 0}
      assert Projection.to_wire(state)["activity"] == "Writing response"
      assert Projection.resolve_approval(state, "ap1", :approved).approvals.approved == 1

      state = Projection.request_approval(state, "ap2", "write", "details")
      assert Projection.resolve_approval(state, "ap2", nil).approvals == state.approvals
    end
  end

  describe "to_wire/1" do
    test "is JSON-encodable with camelCase keys" do
      state =
        new(owner: %{kind: :agent, session_key: "agent:main:x"}, model: "m", thinking: "low")
        |> apply_all([
          {"agent_start", %{}},
          tool_start("c1", "todo", "Plan"),
          tool_end("c1", "todo", %{
            "result" => %{
              "details" => %{
                "phases" => [
                  %{"name" => "P", "tasks" => [%{"content" => "a", "status" => "pending"}]}
                ]
              }
            }
          }),
          {"subagent_lifecycle", %{"payload" => %{"index" => 0, "agent" => "explore"}}},
          tool_start("c2", "bash"),
          assistant_end("text", %{"totalTokens" => 3, "cost" => %{"total" => 0.1}})
        ])
        |> Projection.finish(:failed, %{code: 1, reason: :crashed, error: "boom"})

      wire = Projection.to_wire(state)
      assert {:ok, json} = Jason.encode(wire)
      assert Jason.decode!(json) == wire

      assert Map.keys(wire) |> Enum.sort() ==
               Enum.sort(
                 ~w(id ompSessionId title cwd model thinking approvalMode owner status lastTurn activity
                 startedAt updatedAt endedAt turns toolCalls activeTools recentTools todos subagents
                 usage contextPercent lastText result error declinedPrompts pendingApprovals approvals exit)
               )

      assert wire["owner"] == %{"kind" => "agent", "sessionKey" => "agent:main:x"}
      assert wire["status"] == "failed"
      assert wire["exit"] == %{"code" => 1, "reason" => "crashed"}
      assert wire["usage"]["totalTokens"] == 3
      assert [%{"name" => "todo", "intent" => "Plan", "isError" => false}] = wire["recentTools"]
      assert Projection.to_wire(new())["owner"] == %{"kind" => "operator"}
    end
  end

  describe "summary/1" do
    test "reports what the session is doing" do
      wire =
        running()
        |> apply_all([
          {"turn_start", %{}},
          tool_start("c1", "bash", "Running tests"),
          tool_end("c0", "edit", %{"isError" => true}),
          tool_end("t", "todo", %{
            "result" => %{
              "details" => %{
                "phases" => [
                  %{
                    "name" => "P",
                    "tasks" => [
                      %{"content" => "first", "status" => "completed"},
                      %{"content" => "second", "status" => "pending"}
                    ]
                  }
                ]
              }
            }
          }),
          {"subagent_lifecycle",
           %{"payload" => %{"index" => 0, "agent" => "explore", "status" => "started"}}},
          assistant_end("Working on it", %{"totalTokens" => 1234, "cost" => %{"total" => 0.0123}})
        ])
        |> Map.put(:declined_prompts, 2)
        |> Projection.apply_stats(%{
          "tokens" => %{"total" => 1234},
          "cost" => 0.0123,
          "contextUsage" => %{"percent" => 41.5}
        })
        |> Projection.to_wire()

      summary = Projection.summary(wire)

      assert summary =~ "omp session omp_test"
      assert summary =~ "Title: Fix the build"
      assert summary =~ "Workspace: /work"
      assert summary =~ "Status: running"
      assert summary =~ "Current activity: Running bash — Running tests"
      assert summary =~ "Progress: 1 turns, 1 tool calls, todos 1/2 done"
      assert summary =~ "Usage: 1234 tokens, $0.0123, context 41.5%"
      assert summary =~ "Running: Running bash — Running tests"
      assert summary =~ "Recent tools: edit (failed), todo"
      assert summary =~ "  [completed] first"
      assert summary =~ "Subagents: explore (running)"
      assert summary =~ "Declined 2 interactive omp prompt(s)"
      assert summary =~ "Latest output:\nWorking on it"
    end

    test "reports the settled result of an idle or closed session" do
      state =
        running()
        |> apply_all([
          assistant_end("Final answer"),
          {"prompt_result", %{"status" => "completed"}}
        ])

      idle = Projection.summary(Projection.to_wire(state))
      assert idle =~ "Status: idle (last turn completed; open for follow-ups)"
      assert idle =~ "Last result:\nFinal answer"

      closed = Projection.finish(state, :closed, %{code: 0, reason: :closed})

      assert Projection.summary(Projection.to_wire(closed)) =~
               "closed (last turn completed; resumable)"

      assert Projection.summary(Projection.to_wire(new())) =~ "Status: starting"
    end
  end
end
