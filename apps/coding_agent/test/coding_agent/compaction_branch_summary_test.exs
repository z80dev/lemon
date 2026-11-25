defmodule CodingAgent.CompactionBranchSummaryTest do
  # A checkpoint/rewind or navigation summary puts a `branch_summary` entry on
  # the active branch. Every compaction path (auto, manual, overflow recovery)
  # must still produce a summary afterwards, through the canonical journal
  # deserializer.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias CodingAgent.Compaction
  alias CodingAgent.Session
  alias CodingAgent.Session.{CompactionManager, Rewind}
  alias CodingAgent.SessionManager
  alias LemonAgent.Test.Mocks
  alias LemonAi.Types.{AssistantMessage, TextContent}

  @api :compaction_branch_summary_test
  @registered_name :compaction_branch_summary_test

  defmodule CapturingProvider do
    def stream(_model, context, _opts) do
      if pid = Process.whereis(:compaction_branch_summary_test) do
        send(pid, {:summary_request, context})
      end

      response = %AssistantMessage{
        content: [%TextContent{text: "GENERATED SUMMARY"}],
        stop_reason: :stop
      }

      {:ok, stream} = LemonAi.EventStream.start_link()
      LemonAi.EventStream.complete(stream, response)
      {:ok, stream}
    end
  end

  setup_all do
    LemonAi.ProviderRegistry.register(@api, CapturingProvider)
    on_exit(fn -> LemonAi.ProviderRegistry.unregister(@api) end)
  end

  setup do
    Process.register(self(), @registered_name)
    :ok
  end

  defp model, do: Mocks.mock_model(api: @api)

  defp turn(i) do
    [
      %{"role" => "user", "content" => String.duplicate("question#{i} ", 400), "timestamp" => i},
      %{
        "role" => "assistant",
        "content" => [
          %{"type" => "text", "text" => "reading"},
          %{
            "type" => "tool_call",
            "id" => "call#{i}",
            "name" => "read",
            "arguments" => %{"path" => "file#{i}.ex"}
          }
        ],
        "stop_reason" => "tool_use",
        "timestamp" => i
      },
      %{
        "role" => "tool_result",
        "tool_call_id" => "call#{i}",
        "tool_name" => "read",
        "content" => [%{"type" => "text", "text" => String.duplicate("body#{i} ", 400)}],
        "timestamp" => i
      },
      %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => String.duplicate("answer#{i} ", 400)}],
        "stop_reason" => "stop",
        "timestamp" => i
      }
    ]
  end

  defp append_turns(session, range) do
    range
    |> Enum.flat_map(&turn/1)
    |> Enum.reduce(session, &SessionManager.append_message(&2, &1))
  end

  # History: two turns, an earlier compaction, a checkpoint collapse (branch
  # summary on the active branch), then more turns.
  defp checkpointed_session(cwd) do
    session = cwd |> SessionManager.new() |> append_turns(1..2)
    [first | _] = SessionManager.get_branch(session)

    session =
      session
      |> SessionManager.append_compaction("EARLIER COMPACTION", first.id, 1_000, %{})
      |> append_turns(3..4)

    boundary = session.leaf_id

    {:ok, session} =
      session
      |> append_turns(5..6)
      |> Rewind.collapse_context(boundary, "CHECKPOINT FINDINGS", %{}, [])

    append_turns(session, 7..9)
  end

  defp summary_prompt do
    assert_receive {:summary_request, context}, 5_000

    context.messages
    |> Enum.map_join("\n", fn %LemonAi.Types.UserMessage{content: content} -> content end)
  end

  test "the active branch carries a branch summary", %{tmp_dir: tmp_dir} do
    messages = tmp_dir |> checkpointed_session() |> SessionManager.build_session_context()

    assert Enum.any?(messages.messages, &match?(%{"role" => "branch_summary"}, &1))
    assert Compaction.estimate_context_tokens(messages.messages) > 0

    assert Compaction.estimate_message_tokens(%{
             "role" => "branch_summary",
             "summary" => String.duplicate("s", 400)
           }) == 100
  end

  test "compaction summarizes a branch containing branch and compaction summaries",
       %{tmp_dir: tmp_dir} do
    session = checkpointed_session(tmp_dir)

    assert {:ok, %{summary: "GENERATED SUMMARY", first_kept_entry_id: kept}} =
             Compaction.compact(session, model(), keep_recent_tokens: 1_000)

    assert is_binary(kept)
    prompt = summary_prompt()
    assert prompt =~ "CHECKPOINT FINDINGS"
    assert prompt =~ "EARLIER COMPACTION"
    # Tool results keep their tool name in the summary transcript.
    assert prompt =~ "[Tool Result (read), is_error=false]"
    refute prompt =~ "[Tool Result ()"
  end

  test "auto compaction succeeds after a checkpoint", %{tmp_dir: tmp_dir} do
    session = checkpointed_session(tmp_dir)

    assert {:ok, %{summary: "GENERATED SUMMARY"}} =
             CompactionManager.auto_compaction_task_result(session, model(),
               keep_recent_tokens: 1_000
             )
  end

  test "overflow recovery compaction succeeds after a checkpoint", %{tmp_dir: tmp_dir} do
    session = checkpointed_session(tmp_dir)

    assert {:ok, %{summary: "GENERATED SUMMARY"}} =
             CompactionManager.overflow_recovery_compaction_task_result(session, model(),
               force: true,
               keep_recent_tokens: 1
             )
  end

  test "manual compaction succeeds after a checkpoint", %{tmp_dir: tmp_dir} do
    session_file = Path.join(tmp_dir, "session.jsonl")
    :ok = SessionManager.save_to_file(session_file, checkpointed_session(tmp_dir))

    pid =
      start_supervised!(
        Supervisor.child_spec(
          {Session,
           [
             cwd: tmp_dir,
             workspace_dir: Path.join(tmp_dir, "workspace"),
             tools: [],
             extension_inventory: {[], []},
             mcp_tools: [],
             session_file: session_file,
             model: model(),
             stream_fn: Mocks.mock_stream_fn_single(Mocks.assistant_message("ok"))
           ]},
          restart: :temporary
        )
      )

    assert :ok = Session.compact(pid, keep_recent_tokens: 1_000)

    compactions =
      pid
      |> Session.get_state()
      |> Map.fetch!(:session_manager)
      |> SessionManager.get_branch()
      |> Enum.filter(&(&1.type == :compaction))

    assert List.last(compactions).summary == "GENERATED SUMMARY"
  end
end
