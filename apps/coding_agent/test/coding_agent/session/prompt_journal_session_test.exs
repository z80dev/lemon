defmodule CodingAgent.Session.PromptJournalSessionTest do
  use ExUnit.Case, async: false

  alias CodingAgent.{Session, SessionManager, SettingsManager}
  alias CodingAgent.Session.PromptJournal
  alias LemonAgent.Test.Mocks
  alias LemonAi.SystemPrompt

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.write!(Path.join(dir, "AGENTS.md"), "Original repository instructions.")
    path = Path.join(dir, "session.jsonl")
    assert :ok = SessionManager.save_to_file(path, SessionManager.new(dir))
    %{path: path}
  end

  defp start_session(dir, path, stream, extra \\ []) do
    settings = %{SettingsManager.load(dir) | compaction_enabled: false}

    session =
      start_supervised!(
        {Session,
         Keyword.merge(
           [
             cwd: dir,
             workspace_dir: Path.join(dir, "workspace"),
             session_file: path,
             model: Mocks.mock_model(),
             stream_fn: stream,
             settings_manager: settings,
             system_prompt: "Shared system instructions.",
             tools: [],
             mcp_tools: [],
             extension_inventory: {[], []},
             project_memory_capture: false
           ],
           extra
         )}
      )

    Session.subscribe(session)
    session
  end

  defp capture_stream(owner, responses) do
    calls = :counters.new(1, [:atomics])

    fn model, context, options ->
      send(owner, {:request_prompt, context.system_prompt})
      :counters.add(calls, 1, 1)
      message = Enum.fetch!(responses, :counters.get(calls, 1) - 1)
      Mocks.mock_stream_fn_single(message).(model, context, options)
    end
  end

  defp assistant_entries(session) do
    session
    |> SessionManager.get_branch()
    |> Enum.filter(&match?(%{type: :message, message: %{"role" => "assistant"}}, &1))
  end

  test "every tool and final reply journals the exact request blocks in its own append", %{
    tmp_dir: dir,
    path: path
  } do
    stream =
      capture_stream(self(), [
        Mocks.assistant_message_with_tool_calls([
          Mocks.tool_call("echo", %{"text" => "hello"}, id: "echo-call")
        ]),
        Mocks.assistant_message("done")
      ])

    session = start_session(dir, path, stream, tools: [Mocks.echo_tool()])
    assert :ok = Session.prompt(session, "Echo hello.")
    assert_receive {:request_prompt, first}, 5_000
    assert_receive {:request_prompt, second}, 5_000
    assert_receive {:session_event, _, {:agent_end, _}, _}, 5_000
    assert is_list(first)
    assert first == second
    refute_receive {:session_event, _, {:system_prompt, _}, _}, 0
    assert {:ok, journal} = SessionManager.load_from_file(path)
    replies = assistant_entries(journal)
    assert length(replies) == 2

    for entry <- replies do
      snapshot = entry.message["system-prompt-digest"]
      assert snapshot["digest"] == SystemPrompt.digest(first)
      assert snapshot["prompt"] == Jason.decode!(Jason.encode!(first))
    end
  end

  test "resume accepts a matching rebuild and pins a changed rebuild through the next request", %{
    tmp_dir: dir,
    path: path
  } do
    session = start_session(dir, path, capture_stream(self(), [Mocks.assistant_message("first")]))
    assert :ok = Session.prompt(session, "First reply.")
    assert_receive {:request_prompt, original}, 5_000
    assert_receive {:session_event, _, {:agent_end, _}, _}, 5_000
    stop_supervised!(Session)

    matched =
      start_session(dir, path, capture_stream(self(), [Mocks.assistant_message("unused")]))

    assert Session.get_state(matched).journaled_prompt == nil
    assert LemonAgent.Agent.get_state(Session.get_state(matched).agent).system_prompt == original
    stop_supervised!(Session)

    File.write!(Path.join(dir, "AGENTS.md"), "Changed repository instructions.")

    resumed =
      start_session(dir, path, capture_stream(self(), [Mocks.assistant_message("second")]))

    state = Session.get_state(resumed)
    assert state.journaled_prompt.blocks == original
    assert state.system_prompt == SystemPrompt.text(original)
    assert {:ok, usage} = Session.context_usage(resumed)
    assert usage.prompt_cache.status == :restored
    assert usage.prompt_cache.explanation =~ "journaled prompt was retained"

    assert :ok = Session.prompt(resumed, "Continue after resume.")
    assert_receive {:request_prompt, ^original}, 5_000
    assert_receive {:session_event, _, {:agent_end, _}, _}, 5_000
    assert {:ok, journal} = SessionManager.load_from_file(path)
    assert PromptJournal.latest(journal).prompt == original
  end

  test "a live prompt change remains diagnosable after the reply and after process retirement", %{
    tmp_dir: dir,
    path: path
  } do
    session =
      start_session(
        dir,
        path,
        capture_stream(self(), [
          Mocks.assistant_message("first"),
          Mocks.assistant_message("second")
        ])
      )

    assert :ok = Session.prompt(session, "First reply.")
    assert_receive {:request_prompt, first}, 5_000
    assert_receive {:session_event, _, {:agent_end, _}, _}, 5_000
    File.write!(Path.join(dir, "AGENTS.md"), "Changed repository instructions.")
    assert :ok = Session.prompt(session, "Second reply.")
    assert_receive {:request_prompt, second}, 5_000
    assert_receive {:session_event, _, {:agent_end, _}, _}, 5_000
    refute first == second
    assert {:ok, usage} = Session.context_usage(session)
    assert usage.prompt_cache.status == :digest_changed
    assert usage.prompt_cache.digest == SystemPrompt.digest(second)
    assert usage.prompt_cache.previous_digest == SystemPrompt.digest(first)
    stop_supervised!(Session)
    assert {:ok, journal} = SessionManager.load_from_file(path)
    assert PromptJournal.cache_report(journal) == usage.prompt_cache
  end
end
