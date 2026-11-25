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
    PromptJournal.append_reply(
      session,
      %{"role" => "assistant", "content" => [], "timestamp" => 1},
      %{session_manager: session, response_system_prompt: blocks}
    )
  end

  defp snapshots(session),
    do: Enum.filter(SessionManager.entries(session), &(&1.custom_type == "lemon.prompt_snapshot"))

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
    saved = [%{text: "saved", directory_derived: false}]
    session = reply(SessionManager.new(dir), saved)
    [snapshot] = snapshots(session)
    other = [%{text: "other", directory_derived: false}]
    tampered = %{snapshot | data: %{snapshot.data | "prompt" => other}}
    session = %{session | by_id: Map.put(session.by_id, snapshot.id, tampered)}

    assert_raise ArgumentError, "journaled system prompt digest does not match its blocks", fn ->
      PromptJournal.restore(session, "rebuilt", [])
    end

    missing = %{session | by_id: Map.delete(session.by_id, snapshot.id)}

    assert_raise ArgumentError, "journaled system prompt snapshot is missing", fn ->
      PromptJournal.restore(missing, "rebuilt", [])
    end
  end

  test "new journals store one prompt snapshot per unchanged digest", %{tmp_dir: dir} do
    prompt = [%{text: String.duplicate("stable instructions ", 2_500), directory_derived: false}]
    path = Path.join(dir, "unchanged.jsonl")
    session = SessionManager.persist(SessionManager.new(dir), path)
    session = Enum.reduce(1..100, session, fn _, session -> reply(session, prompt) end)
    :ok = SessionManager.close(session)

    assert [_] = snapshots(session)
    # 100 replies used to write the prompt (and an equal base prompt) 200 times.
    assert File.stat!(path).size < 2 * byte_size(SystemPrompt.text(prompt))

    assert {:ok, loaded} = SessionManager.load_from_file(path)
    assert PromptJournal.latest(loaded).prompt == prompt
    assert PromptJournal.latest(loaded).base_prompt == SystemPrompt.text(prompt)
    refute Map.has_key?(hd(snapshots(loaded)).data, "base_prompt")

    replies =
      Enum.filter(SessionManager.entries(loaded), &(&1.type == :message))
      |> Enum.map(& &1.message["system-prompt-digest"])

    assert Enum.uniq(replies) == [
             %{"version" => 2, "digest" => SystemPrompt.digest(prompt), "plan_revision" => nil}
           ]
  end

  test "a digest returning on its branch reuses that branch's snapshot", %{tmp_dir: dir} do
    first = [%{text: "first", directory_derived: false}]
    second = [%{text: "second", directory_derived: false}]
    session = SessionManager.new(dir) |> reply(first) |> reply(second) |> reply(first)
    assert length(snapshots(session)) == 2
    assert PromptJournal.latest(session).prompt == first
    assert PromptJournal.cache_report(session).previous_digest == SystemPrompt.digest(second)
  end

  test "rewrite and fork paths keep each reply's snapshot", %{tmp_dir: dir} do
    first = [%{text: "first", directory_derived: false}]
    second = [%{text: "second", directory_derived: true}]
    session = reply(SessionManager.new(dir), first)
    branch_point = session.leaf_id
    session = reply(session, first)
    first_leaf = session.leaf_id
    session = session |> SessionManager.set_leaf_id(branch_point) |> reply(second)

    rewritten = Path.join(dir, "rewritten.jsonl")
    assert :ok = SessionManager.save_to_file(rewritten, session)
    assert {:ok, loaded} = SessionManager.load_from_file(rewritten)
    assert length(snapshots(loaded)) == 2
    assert PromptJournal.latest(loaded).prompt == second
    assert PromptJournal.latest(SessionManager.set_leaf_id(loaded, first_leaf)).prompt == first

    fork = Path.join(dir, "fork.jsonl")
    assert {:ok, _} = SessionManager.fork_file(rewritten, fork, leaf_id: first_leaf)
    assert {:ok, forked} = SessionManager.load_from_file(fork)
    assert [_] = snapshots(forked)
    assert PromptJournal.latest(forked).prompt == first
  end

  test "a pre-change journal still restores its inline prompt and plan overlay", %{tmp_dir: dir} do
    path = Path.join(dir, "v1.jsonl")

    File.write!(
      path,
      "../../fixtures/journals/prompt_snapshot_v1.jsonl"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> String.replace("__CWD__", dir)
    )

    assert {:ok, session} = SessionManager.load_from_file(path)
    saved = PromptJournal.latest(session)
    plan = SessionManager.latest_custom_entry(session, "lemon.plan")
    assert saved.plan_revision == plan.id

    assert saved.base_prompt ==
             "Fixture base instructions captured before the prompt snapshot change."

    assert SystemPrompt.text(saved.prompt) =~ "Fixture overlay journaled before the change."

    restored = PromptJournal.restore(session, "a rebuilt base", [])
    assert restored.system_prompt == SystemPrompt.text(saved.prompt)
    assert restored.base_system_prompt == saved.base_prompt
    assert restored.journaled_prompt == %{blocks: saved.prompt, plan_revision: plan.id}

    state = Map.put(restored, :session_manager, session)
    assert PromptJournal.planning_prompt(state) == SystemPrompt.text(saved.prompt)

    # The next reply journals the same prompt once, in the shared format.
    next = reply(session, saved.prompt)
    assert [_] = snapshots(next)
    assert PromptJournal.latest(next).prompt == saved.prompt
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
