defmodule CodingAgent.Session.PromptJournalTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.{ContextUsage, PromptComposer, PromptJournal}
  alias CodingAgent.SessionManager
  alias LemonAi.SystemPrompt

  @moduletag :tmp_dir

  defp sections(footer \\ "directory") do
    [
      %{category: :system_prompt, label: "Shared", text: "shared", directory_derived: false},
      %{category: :context_files, label: "Project", text: footer, directory_derived: true}
    ]
  end

  defp reply(session, blocks) do
    message =
      PromptJournal.attach(
        %{"role" => "assistant", "content" => [], "timestamp" => 1},
        %{session_manager: session, response_system_prompt: blocks}
      )

    SessionManager.append_message(session, message)
  end

  test "matching ordered blocks adopt rebuilt sections; changed boundaries retain the journal", %{
    tmp_dir: dir
  } do
    sections = sections()
    text = CodingAgent.SystemPrompt.join_sections(sections)
    blocks = PromptComposer.prompt_blocks(text, sections)
    session = reply(SessionManager.new(dir), blocks)

    matched = PromptJournal.restore(session, text, sections)
    assert matched.system_prompt == text
    assert matched.prompt_sections == sections
    assert matched.journaled_prompt == nil
    assert PromptJournal.blocks(matched) == blocks

    changed = Enum.map(sections, &Map.put(&1, :directory_derived, true))
    restored = PromptJournal.restore(session, text, changed)
    assert restored.system_prompt == text
    assert restored.prompt_sections == []
    assert restored.journaled_prompt.blocks == blocks
    assert PromptJournal.blocks(restored) == blocks
    assert PromptJournal.planning_prompt(Map.put(restored, :session_manager, session)) == text
  end

  test "snapshots round-trip JSON and remain on their selected branch", %{tmp_dir: dir} do
    first = [%{text: "first", directory_derived: false}]
    second = [%{text: "second", directory_derived: true}]
    session = reply(SessionManager.new(dir), first)
    first_id = session.leaf_id
    session = reply(session, second)
    second_id = session.leaf_id
    selected = SessionManager.set_leaf_id(session, first_id)
    path = Path.join(dir, "branch.jsonl")
    assert :ok = SessionManager.save_to_file(path, selected)
    assert {:ok, loaded} = SessionManager.load_from_file(path)

    assert PromptJournal.latest(loaded).prompt == first
    assert PromptJournal.latest(SessionManager.set_leaf_id(loaded, second_id)).prompt == second
    assert PromptJournal.restore(loaded, "new prompt", []).system_prompt == "first"
  end

  test "binary prompts normalize without changing their digest", %{tmp_dir: dir} do
    session = reply(SessionManager.new(dir), "binary prompt")
    saved = PromptJournal.latest(session)
    assert saved.digest == SystemPrompt.digest("binary prompt")
    assert saved.prompt == [%{text: "binary prompt", directory_derived: false}]
  end

  test "retaining a prompt does not suppress a deliberate plan-mode change", %{tmp_dir: dir} do
    session = reply(SessionManager.new(dir), [%{text: "saved base", directory_derived: true}])
    restored = PromptJournal.restore(session, "changed base", [])
    state = Map.put(restored, :session_manager, session)
    assert PromptJournal.planning_prompt(state) == "saved base"

    planned =
      SessionManager.append_entry(
        session,
        SessionManager.SessionEntry.custom("lemon.plan", %{"mode" => "plan"})
      )

    prompt = PromptJournal.planning_prompt(%{state | session_manager: planned})
    assert String.starts_with?(prompt, "saved base")
    assert prompt =~ "Plan mode is active"
    refute prompt =~ "changed base"
  end

  test "legacy replies permit rebuilding instead of borrowing an older digest", %{tmp_dir: dir} do
    session =
      SessionManager.new(dir)
      |> reply([%{text: "old", directory_derived: true}])
      |> SessionManager.append_message(%{"role" => "assistant", "content" => []})

    assert PromptJournal.latest(session) == nil
    assert PromptJournal.restore(session, "new prompt", []).system_prompt == "new prompt"
    assert PromptJournal.cache_report(session).status == :unknown
  end

  test "corrupt snapshot digests are refused instead of silently replacing the prompt", %{
    tmp_dir: dir
  } do
    session = SessionManager.new(dir)

    message =
      PromptJournal.attach(%{"role" => "assistant"}, %{
        session_manager: session,
        response_system_prompt: [%{text: "saved", directory_derived: false}]
      })
      |> put_in(["system-prompt-digest", "digest"], String.duplicate("0", 64))

    session = SessionManager.append_message(session, message)

    assert_raise ArgumentError, "journaled system prompt digest does not match its blocks", fn ->
      PromptJournal.restore(session, "rebuilt", [])
    end
  end

  test "cache diagnostics compare boundaries without disclosing journaled text", %{tmp_dir: dir} do
    first = [%{text: "private instructions", directory_derived: false}]
    second = [%{text: "private instructions", directory_derived: true}]
    session = SessionManager.new(dir) |> reply(first) |> reply(second)
    report = PromptJournal.cache_report(session)

    assert report.status == :digest_changed
    assert report.digest == SystemPrompt.digest(second)
    assert report.previous_digest == SystemPrompt.digest(first)
    assert report.explanation =~ "digest changed"
    assert report.explanation =~ "cache miss"
    refute inspect(report) =~ "private instructions"
    assert PromptJournal.cache_report(reply(session, second)).status == :unchanged
    assert PromptJournal.cache_report(session, second, true).status == :restored
  end

  test "live and durable context usage expose the same prompt digest change", %{tmp_dir: dir} do
    first = [%{text: "shared", directory_derived: false}]
    second = [%{text: "shared", directory_derived: true}]
    manager = SessionManager.new(dir) |> reply(first) |> reply(second)
    state = %{session_manager: manager, model: nil, settings_manager: nil}

    messages = [
      %LemonAi.Types.AssistantMessage{
        content: [],
        usage: %LemonAi.Types.Usage{input: 10, output: 1}
      }
    ]

    agent = %{system_prompt: second, tools: [], messages: messages}
    live = ContextUsage.measure(state, agent)
    assert {:ok, durable} = ContextUsage.measure_durable(state, messages)
    assert live.prompt_cache == durable.prompt_cache
    assert live.prompt_cache.status == :digest_changed
    assert live.used_tokens == durable.used_tokens
  end
end
