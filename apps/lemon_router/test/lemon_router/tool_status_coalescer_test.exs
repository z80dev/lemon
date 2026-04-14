defmodule LemonRouter.ToolStatusCoalescerTest do
  alias Elixir.LemonRouter, as: LemonRouter
  use ExUnit.Case, async: false

  alias LemonCore.DeliveryIntent
  alias LemonCore.DeliveryRoute
  alias Elixir.LemonRouter.StreamCoalescer
  alias Elixir.LemonRouter.ToolStatusCoalescer

  defmodule ToolStatusCoalescerTestTelegramPlugin do
    @moduledoc false

    def id, do: "telegram"

    def meta do
      %{
        name: "Test Telegram",
        capabilities: %{
          edit_support: true,
          chunk_limit: 4096
        }
      }
    end

    def deliver(payload) do
      pid = :persistent_term.get({__MODULE__, :test_pid}, nil)
      if is_pid(pid), do: send(pid, {:delivered, payload})
      {:ok, %{"ok" => true, "result" => %{"message_id" => 1001}}}
    end
  end

  defmodule ToolStatusIntentDispatcherStub do
    @moduledoc false

    def dispatch(%DeliveryIntent{} = intent) do
      case :persistent_term.get({__MODULE__, :test_pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:dispatched_intent, intent})
        _ -> :ok
      end

      :ok
    end
  end

  setup do
    if is_nil(Process.whereis(Elixir.LemonRouter.CoalescerRegistry)) do
      {:ok, _} = Registry.start_link(keys: :unique, name: Elixir.LemonRouter.CoalescerRegistry)
    end

    if is_nil(Process.whereis(Elixir.LemonRouter.CoalescerSupervisor)) do
      {:ok, _} =
        DynamicSupervisor.start_link(
          strategy: :one_for_one,
          name: Elixir.LemonRouter.CoalescerSupervisor
        )
    end

    if is_nil(Process.whereis(Elixir.LemonRouter.ToolStatusRegistry)) do
      {:ok, _} = Registry.start_link(keys: :unique, name: Elixir.LemonRouter.ToolStatusRegistry)
    end

    if is_nil(Process.whereis(Elixir.LemonRouter.ToolStatusSupervisor)) do
      {:ok, _} =
        DynamicSupervisor.start_link(
          strategy: :one_for_one,
          name: Elixir.LemonRouter.ToolStatusSupervisor
        )
    end

    if is_nil(Process.whereis(LemonChannels.Registry)) do
      {:ok, _} = LemonChannels.Registry.start_link([])
    end

    if is_nil(Process.whereis(LemonChannels.Outbox)) do
      {:ok, _} = LemonChannels.Outbox.start_link([])
    end

    if is_nil(Process.whereis(LemonChannels.Outbox.RateLimiter)) do
      {:ok, _} = LemonChannels.Outbox.RateLimiter.start_link([])
    end

    if is_nil(Process.whereis(LemonChannels.Outbox.Dedupe)) do
      {:ok, _} = LemonChannels.Outbox.Dedupe.start_link([])
    end

    if is_nil(Process.whereis(LemonChannels.PresentationState)) do
      {:ok, _} = LemonChannels.PresentationState.start_link([])
    end

    :persistent_term.put({__MODULE__.ToolStatusCoalescerTestTelegramPlugin, :test_pid}, self())

    existing = LemonChannels.Registry.get_plugin("telegram")
    _ = LemonChannels.Registry.unregister("telegram")

    :ok =
      LemonChannels.Registry.register(__MODULE__.ToolStatusCoalescerTestTelegramPlugin)

    on_exit(fn ->
      _ =
        :persistent_term.erase({__MODULE__.ToolStatusCoalescerTestTelegramPlugin, :test_pid})

      if is_pid(Process.whereis(LemonChannels.Registry)) do
        _ = LemonChannels.Registry.unregister("telegram")

        if is_atom(existing) and not is_nil(existing) do
          _ = LemonChannels.Registry.register(existing)
        end
      end
    end)

    :ok
  end

  test "starts coalescer and accepts action events" do
    session_key = "agent:test:telegram:bot:dm:123"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    ev = %{
      engine: "lemon",
      action: %{
        id: "a1",
        kind: "tool",
        title: "Read: foo.txt",
        detail: %{}
      },
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, ev,
               meta: %{status_msg_id: 123}
             )

    assert [{_pid, _}] =
             Registry.lookup(Elixir.LemonRouter.ToolStatusRegistry, {session_key, channel_id})
  end

  test "filters note actions" do
    session_key = "agent:test2:telegram:bot:dm:456"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    ev = %{
      engine: "lemon",
      action: %{id: "n1", kind: "note", title: "thinking", detail: %{}},
      phase: :completed,
      ok: true,
      message: nil,
      level: nil
    }

    assert :ok = ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, ev)
    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)
  end

  test "retains more than forty actions" do
    session_key = "agent:test:telegram:bot:dm:many-actions"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    for idx <- 1..45 do
      ev = %{
        engine: "lemon",
        action: %{id: "a#{idx}", kind: "tool", title: "Action #{idx}", detail: %{}},
        phase: :started,
        ok: nil,
        message: nil,
        level: nil
      }

      assert :ok = ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, ev)
    end

    [{pid, _}] = Registry.lookup(Elixir.LemonRouter.ToolStatusRegistry, {session_key, channel_id})
    state = :sys.get_state(pid)

    assert length(state.order) == 45
    assert Enum.take(state.order, 3) == ["a1", "a2", "a3"]
    assert Enum.take(state.order, -3) == ["a43", "a44", "a45"]
  end

  test "does not overwrite status_msg_id with nil meta updates" do
    session_key = "agent:test3:telegram:bot:dm:789"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    ev = %{
      engine: "lemon",
      action: %{id: "a1", kind: "tool", title: "Test tool", detail: %{}},
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, ev,
               meta: %{status_msg_id: 111}
             )

    [{pid, _}] = Registry.lookup(Elixir.LemonRouter.ToolStatusRegistry, {session_key, channel_id})
    state = :sys.get_state(pid)
    assert state.meta[:status_msg_id] == 111

    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, ev,
               meta: %{status_msg_id: nil}
             )

    state2 = :sys.get_state(pid)
    assert state2.meta[:status_msg_id] == 111
  end

  test "finalize_run marks running actions as completed" do
    session_key = "agent:finalize:telegram:bot:dm:321"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    started = %{
      engine: "lemon",
      action: %{id: "a1", kind: "tool", title: "Test tool", detail: %{}},
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    assert :ok = ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, started)

    [{pid, _}] = Registry.lookup(Elixir.LemonRouter.ToolStatusRegistry, {session_key, channel_id})
    state = :sys.get_state(pid)
    assert state.actions["a1"].phase == :started

    assert :ok = ToolStatusCoalescer.finalize_run(session_key, channel_id, run_id, true)

    assert eventually(fn ->
             state2 = :sys.get_state(pid)
             state2.actions["a1"].phase == :completed and state2.actions["a1"].ok == true
           end)
  end

  test "expands embedded task current_action into a child action" do
    session_key = "agent:embedded:telegram:bot:dm:654"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    ev = %{
      engine: "lemon",
      action: %{
        id: "task_1",
        kind: "subagent",
        title: "task: Read AGENTS.md in lemon repo",
        detail: %{
          name: "task",
          partial_result: %AgentCore.Types.AgentToolResult{
            content: [%Ai.Types.TextContent{type: :text, text: "pwd"}],
            details: %{
              status: "running",
              description: "Read AGENTS.md in lemon repo",
              engine: "claude",
              current_action: %{title: "pwd", kind: "command", phase: "started"}
            },
            trust: :trusted
          }
        }
      },
      phase: :updated,
      ok: nil,
      message: nil,
      level: nil
    }

    assert :ok = ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, ev)
    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)

    [{pid, _}] = Registry.lookup(Elixir.LemonRouter.ToolStatusRegistry, {session_key, channel_id})
    state = :sys.get_state(pid)

    child_action =
      state.actions
      |> Map.values()
      |> Enum.find(fn action ->
        action[:detail][:parent_tool_use_id] == "task_1"
      end)

    assert child_action.title == "pwd"
    assert child_action.kind == "command"
    assert child_action.phase == :started
    assert child_action.caller_engine == "claude"
    assert String.contains?(state.last_text, "▸ task: Read AGENTS.md in lemon repo")
    assert String.contains?(state.last_text, "  ▸ pwd")
  end

  test "expands embedded codex task current_action into a child action" do
    session_key = "agent:embedded:telegram:bot:dm:655"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    ev = %{
      engine: "lemon",
      action: %{
        id: "task_codex_1",
        kind: "subagent",
        title: "task(codex): inspect repo",
        detail: %{
          name: "task",
          partial_result: %AgentCore.Types.AgentToolResult{
            content: [%Ai.Types.TextContent{type: :text, text: "Read: AGENTS.md"}],
            details: %{
              status: "running",
              description: "inspect repo",
              engine: "codex",
              current_action: %{title: "Read: AGENTS.md", kind: "tool", phase: "completed"}
            },
            trust: :trusted
          }
        }
      },
      phase: :updated,
      ok: nil,
      message: nil,
      level: nil
    }

    assert :ok = ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, ev)
    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)

    [{pid, _}] = Registry.lookup(Elixir.LemonRouter.ToolStatusRegistry, {session_key, channel_id})
    state = :sys.get_state(pid)

    child_action =
      state.actions
      |> Map.values()
      |> Enum.find(fn action ->
        action[:detail][:parent_tool_use_id] == "task_codex_1"
      end)

    assert child_action.title == "Read: AGENTS.md"
    assert child_action.kind == "tool"
    assert child_action.phase == :completed
    assert child_action.ok == true
    assert child_action.caller_engine == "codex"
    assert String.contains?(state.last_text, "▸ task(codex): inspect repo")
    assert String.contains?(state.last_text, "  ✓ Read: AGENTS.md")
  end

  test "skips internal task poll action and renders its current_action as a child" do
    session_key = "agent:embedded:telegram:bot:dm:656"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    started = %{
      engine: "lemon",
      action: %{
        id: "task_codex_root",
        kind: "subagent",
        title: "task(codex): inspect repo",
        detail: %{name: "task"}
      },
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    poll_completed = %{
      engine: "lemon",
      action: %{
        id: "task_poll_1",
        kind: "subagent",
        title: "task: ",
        detail: %{
          name: "task",
          args: %{"action" => "poll", "task_id" => "task-store-1"},
          parent_tool_use_id: "task_codex_root",
          result_meta: %{
            task_id: "task-store-1",
            engine: "codex",
            current_action: %{title: "Read: AGENTS.md", kind: "tool", phase: "completed"}
          }
        }
      },
      phase: :completed,
      ok: true,
      message: nil,
      level: nil
    }

    assert :ok = ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, started)

    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, poll_completed)

    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)

    [{pid, _}] = Registry.lookup(Elixir.LemonRouter.ToolStatusRegistry, {session_key, channel_id})
    state = :sys.get_state(pid)

    refute Enum.any?(state.order, &(&1 == "task_poll_1"))

    child_action =
      state.actions
      |> Map.values()
      |> Enum.find(fn action ->
        action[:detail][:parent_tool_use_id] == "task_codex_root"
      end)

    assert child_action.title == "Read: AGENTS.md"
    assert child_action.kind == "tool"
    assert child_action.phase == :completed
    assert child_action.caller_engine == "codex"
    assert String.contains?(state.last_text, "▸ task(codex): inspect repo")
    assert String.contains?(state.last_text, "  ✓ Read: AGENTS.md")
    refute String.contains?(state.last_text, "\n✓ task: ")
  end

  test "poll current_action dedupes against an already projected child action" do
    session_key = "agent:embedded:telegram:bot:dm:657"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"
    surface = {:status_task, "task_codex_root_live"}

    started = %{
      engine: "lemon",
      action: %{
        id: "task_codex_root_live",
        kind: "subagent",
        title: "task(codex): inspect repo",
        detail: %{name: "task"}
      },
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    projected = %{
      engine: "codex",
      action: %{
        id: "taskproj:child_run_1:read_1",
        kind: "tool",
        title: "Read: AGENTS.md",
        detail: %{parent_tool_use_id: "task_codex_root_live", child_run_id: "child_run_1"}
      },
      phase: :completed,
      ok: true,
      message: nil,
      level: nil
    }

    poll_completed = %{
      engine: "lemon",
      action: %{
        id: "task_poll_live_1",
        kind: "subagent",
        title: "task: ",
        detail: %{
          name: "task",
          args: %{"action" => "poll", "task_id" => "task-store-1"},
          parent_tool_use_id: "task_codex_root_live",
          result_meta: %{
            task_id: "task-store-1",
            run_id: "child_run_1",
            engine: "codex",
            current_action: %{title: "Read: AGENTS.md", kind: "tool", phase: "completed"},
            action_detail: %{child_run_id: "child_run_1"}
          }
        }
      },
      phase: :completed,
      ok: true,
      message: nil,
      level: nil
    }

    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, started,
               surface: surface
             )

    assert :ok =
             ToolStatusCoalescer.ingest_projected_child_action(
               session_key,
               channel_id,
               run_id,
               surface,
               projected
             )

    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, poll_completed,
               surface: surface
             )

    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id, surface: surface)

    [{pid, _}] =
      Registry.lookup(Elixir.LemonRouter.ToolStatusRegistry, {session_key, channel_id, surface})

    state = :sys.get_state(pid)

    matching_children =
      state.actions
      |> Map.values()
      |> Enum.filter(fn action ->
        action[:detail][:parent_tool_use_id] == "task_codex_root_live" and
          action[:title] == "Read: AGENTS.md"
      end)

    assert length(matching_children) == 1
    refute Enum.any?(state.order, &(&1 == "task_poll_live_1"))
  end

  test "telegram tool status creates a new message when only progress_msg_id is present (no status_msg_id)" do
    session_key = "agent:tool-status:telegram:bot:group:12345:thread:777"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"
    progress_msg_id = 9001

    started = %{
      engine: "lemon",
      action: %{id: "a1", kind: "tool", title: "Read: foo.txt", detail: %{}},
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    # When only progress_msg_id is provided (without status_msg_id),
    # the coalescer should create a new status message instead of trying to edit the user's message
    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, started,
               meta: %{user_msg_id: 9, progress_msg_id: progress_msg_id}
             )

    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)

    # Should create a new text message (not edit) since status_msg_id is nil
    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :text,
                      peer: %{id: "12345", thread_id: "777"},
                      reply_to: "9",
                      meta: %{run_id: ^run_id, intent_kind: :tool_status_snapshot}
                    }},
                   1_000

    route = telegram_route("bot", :group, "12345", "777")

    assert eventually(fn ->
             LemonChannels.PresentationState.get(route, run_id, :status).platform_message_id ==
               1001
           end)

    # Now subsequent updates should edit the status message
    completed = %{started | phase: :completed, ok: true}
    assert :ok = ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, completed)
    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :edit,
                      peer: %{id: "12345", thread_id: "777"},
                      content: %{message_id: "1001", text: text},
                      meta: %{run_id: ^run_id, intent_kind: :tool_status_snapshot}
                    }},
                   1_000

    assert String.contains?(text, "working")
  end

  test "anchored tool status edits the handed-off answer message and finalizes in place" do
    session_key = "agent:tool-status:telegram:bot:group:12345:thread:778"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"
    route = telegram_route("bot", :group, "12345", "778")
    prefix = "Found the key files. Let me read the markdown renderer and the formatter:"

    StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 1, prefix,
      meta: %{user_msg_id: 9}
    )

    StreamCoalescer.flush(session_key, channel_id)

    assert eventually(fn ->
             LemonChannels.PresentationState.get(route, run_id, :answer).platform_message_id ==
               1001
           end)

    assert {:ok, ^prefix} = StreamCoalescer.handoff_turn(session_key, channel_id, run_id, :status)

    assert :ok =
             ToolStatusCoalescer.anchor_segment(session_key, channel_id, run_id, prefix,
               meta: %{user_msg_id: 9}
             )

    started = %{
      engine: "lemon",
      action: %{id: "a1", kind: "tool", title: "Read: markdown.ex", detail: %{}},
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    assert :ok = ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, started)
    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :edit,
                      content: %{message_id: "1001", text: text},
                      meta: %{run_id: ^run_id, intent_kind: :tool_status_snapshot}
                    }},
                   1_000

    assert String.contains?(text, prefix <> "\n\n")
    assert String.contains?(text, "Read: markdown.ex")

    assert :ok = ToolStatusCoalescer.commit_segment(session_key, channel_id, run_id)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :edit,
                      content: %{message_id: "1001", text: final_text},
                      meta: %{reply_markup: %{"inline_keyboard" => []}}
                    }},
                   1_000

    assert String.contains?(final_text, prefix <> "\n\n")
    assert String.contains?(final_text, "Read: markdown.ex")
  end

  test "anchored tool status keeps tool lines visible when the handed-off prefix is very long" do
    session_key = "agent:tool-status:telegram:bot:group:12345:thread:7781"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"
    route = telegram_route("bot", :group, "12345", "7781")
    prefix = String.duplicate("thinking block ", 350)

    StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 1, prefix,
      meta: %{user_msg_id: 9}
    )

    StreamCoalescer.flush(session_key, channel_id)

    assert eventually(fn ->
             LemonChannels.PresentationState.get(route, run_id, :answer).platform_message_id ==
               1001
           end)

    assert {:ok, ^prefix} = StreamCoalescer.handoff_turn(session_key, channel_id, run_id, :status)

    assert :ok =
             ToolStatusCoalescer.anchor_segment(session_key, channel_id, run_id, prefix,
               meta: %{user_msg_id: 9}
             )

    started = %{
      engine: "lemon",
      action: %{id: "a1", kind: "tool", title: "Read: markdown.ex", detail: %{}},
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    assert :ok = ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, started)
    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :edit,
                      content: %{message_id: "1001", text: text},
                      meta: %{run_id: ^run_id, intent_kind: :tool_status_snapshot}
                    }},
                   1_000

    assert String.contains?(text, "Read: markdown.ex")
    assert String.length(text) <= LemonChannels.Telegram.Truncate.max_length()
    refute String.starts_with?(text, prefix <> "\n\n")
  end

  test "task-specific surface keeps its message separate from generic status" do
    session_key = "agent:tool-status:telegram:bot:group:12345:thread:779"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"
    route = telegram_route("bot", :group, "12345", "779")
    surface = {:status_task, "task_1"}
    prefix = "Inspecting the repo layout"

    StreamCoalescer.ingest_delta(session_key, channel_id, run_id, 1, prefix,
      meta: %{user_msg_id: 9}
    )

    StreamCoalescer.flush(session_key, channel_id)

    assert eventually(fn ->
             LemonChannels.PresentationState.get(route, run_id, :answer).platform_message_id ==
               1001
           end)

    assert {:ok, ^prefix} = StreamCoalescer.handoff_turn(session_key, channel_id, run_id, surface)

    assert :ok =
             ToolStatusCoalescer.anchor_segment(session_key, channel_id, run_id, prefix,
               meta: %{user_msg_id: 9},
               surface: surface
             )

    started = %{
      engine: "lemon",
      action: %{
        id: "task_1",
        kind: "subagent",
        title: "task(claude): inspect repo",
        detail: %{name: "task"}
      },
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, started,
               surface: surface
             )

    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id, surface: surface)

    assert eventually(fn ->
             LemonChannels.PresentationState.get(route, run_id, surface).platform_message_id ==
               1001
           end)

    assert is_nil(LemonChannels.PresentationState.get(route, run_id, :status).platform_message_id)
  end

  test "ingest_projected_child_action renders nested child lines under existing task surface" do
    session_key = "agent:tool-status:telegram:bot:group:12345:thread:780"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"
    surface = {:status_task, "task_root"}

    started = %{
      engine: "lemon",
      action: %{
        id: "task_root",
        kind: "subagent",
        title: "task(codex): inspect repo",
        detail: %{name: "task"}
      },
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    projected = %{
      engine: "codex",
      action: %{
        id: "taskproj:child_1:read_1",
        kind: "tool",
        title: "Read: AGENTS.md",
        detail: %{
          parent_tool_use_id: "task_root",
          child_run_id: "child_1",
          task_id: "task-store-1"
        }
      },
      phase: :completed,
      ok: true,
      message: nil,
      level: nil
    }

    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, started,
               surface: surface
             )

    assert :ok =
             ToolStatusCoalescer.ingest_projected_child_action(
               session_key,
               channel_id,
               run_id,
               surface,
               projected
             )

    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id, surface: surface)

    [{pid, _}] =
      Registry.lookup(Elixir.LemonRouter.ToolStatusRegistry, {session_key, channel_id, surface})

    state = :sys.get_state(pid)

    assert String.contains?(state.last_text, "task(codex): inspect repo")
    assert String.contains?(state.last_text, "Read: AGENTS.md")
  end

  test "finalize_run does not create status output when there are no tool actions" do
    session_key = "agent:tool-status:telegram:bot:group:12345:thread:777"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"
    progress_msg_id = 9002

    # finalize_run should be a no-op when no tool actions were ingested.
    assert :ok =
             ToolStatusCoalescer.finalize_run(session_key, channel_id, run_id, true,
               meta: %{user_msg_id: 9, progress_msg_id: progress_msg_id}
             )

    refute_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      meta: %{run_id: ^run_id}
                    }},
                   300
  end

  test "finalize_run does not emit synthetic done on failed runs without tool actions" do
    session_key = "agent:tool-status:telegram:bot:group:12345:thread:777"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    assert :ok =
             ToolStatusCoalescer.finalize_run(session_key, channel_id, run_id, false,
               meta: %{user_msg_id: 9, progress_msg_id: 9003}
             )

    refute_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      meta: %{run_id: ^run_id}
                    }},
                   300
  end

  test "telegram tool status falls back to a dedicated status message when progress_msg_id is nil" do
    session_key = "agent:tool-status:telegram:bot:group:12345:thread:777"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    started = %{
      engine: "lemon",
      action: %{id: "a1", kind: "tool", title: "Read: foo.txt", detail: %{}},
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, started,
               meta: %{user_msg_id: 9}
             )

    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :text,
                      peer: %{id: "12345", thread_id: "777"},
                      reply_to: "9",
                      meta: %{reply_markup: reply_markup}
                    }},
                   1_000

    assert reply_markup == %{
             "inline_keyboard" => [
               [
                 %{
                   "text" => "cancel",
                   "callback_data" => "lemon:cancel:#{run_id}"
                 }
               ]
             ]
           }

    route = telegram_route("bot", :group, "12345", "777")

    assert eventually(fn ->
             LemonChannels.PresentationState.get(route, run_id, :status).platform_message_id ==
               1001
           end)

    assert :ok = ToolStatusCoalescer.finalize_run(session_key, channel_id, run_id, true)

    assert_receive {:delivered,
                    %LemonChannels.OutboundPayload{
                      channel_id: "telegram",
                      kind: :edit,
                      peer: %{id: "12345", thread_id: "777"},
                      content: %{message_id: "1001"},
                      meta: %{reply_markup: %{"inline_keyboard" => []}, run_id: ^run_id}
                    }},
                   1_000
  end

  test "flush emits a semantic tool status intent via configurable dispatcher" do
    previous_dispatcher = Application.get_env(:lemon_router, :dispatcher)
    Application.put_env(:lemon_router, :dispatcher, ToolStatusIntentDispatcherStub)
    :persistent_term.put({ToolStatusIntentDispatcherStub, :test_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({ToolStatusIntentDispatcherStub, :test_pid})

      if is_nil(previous_dispatcher) do
        Application.delete_env(:lemon_router, :dispatcher)
      else
        Application.put_env(:lemon_router, :dispatcher, previous_dispatcher)
      end
    end)

    session_key = "agent:tool-status:telegram:bot:group:12345:thread:777"
    channel_id = "telegram"
    run_id = "run_#{System.unique_integer([:positive])}"

    started = %{
      engine: "lemon",
      action: %{id: "a1", kind: "tool", title: "Read: foo.txt", detail: %{}},
      phase: :started,
      ok: nil,
      message: nil,
      level: nil
    }

    assert :ok =
             ToolStatusCoalescer.ingest_action(session_key, channel_id, run_id, started,
               meta: %{user_msg_id: 9}
             )

    assert :ok = ToolStatusCoalescer.flush(session_key, channel_id)

    assert_receive {:dispatched_intent,
                    %DeliveryIntent{
                      intent_id: intent_id,
                      run_id: ^run_id,
                      session_key: ^session_key,
                      kind: :tool_status_snapshot,
                      route: %DeliveryRoute{
                        channel_id: "telegram",
                        account_id: "bot",
                        peer_kind: :group,
                        peer_id: "12345",
                        thread_id: "777"
                      },
                      body: %{text: text, seq: 1},
                      controls: %{allow_cancel?: true},
                      meta: %{surface: :status, user_msg_id: 9}
                    }},
                   1_000

    assert String.starts_with?(intent_id, "#{run_id}:status:")
    assert String.ends_with?(intent_id, ":1:tool_status_snapshot")
    assert String.contains?(text, "Read: foo.txt")
  end

  defp telegram_route(account_id, peer_kind, peer_id, thread_id) do
    %DeliveryRoute{
      channel_id: "telegram",
      account_id: account_id,
      peer_kind: peer_kind,
      peer_id: peer_id,
      thread_id: thread_id
    }
  end

  defp eventually(fun, timeout_ms \\ 500) when is_function(fun, 0) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_eventually(fun, deadline)
  end

  defp do_eventually(fun, deadline) do
    if fun.() do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(10)
        do_eventually(fun, deadline)
      end
    end
  end
end
