defmodule CodingAgent.CompactionPruningTest do
  use ExUnit.Case, async: true

  alias CodingAgent.{Artifacts, Compaction, SessionManager}

  @tag :tmp_dir
  test "fixture pruning preserves every protocol envelope, recovers output and skips summary", %{
    tmp_dir: cwd
  } do
    session = SessionManager.new(cwd)
    {:ok, directory} = Artifacts.spill_dir(cwd, session_id: session.header.id)
    on_exit(fn -> File.rm_rf!(directory) end)

    output = [%{"type" => "text", "text" => String.duplicate("old output ", 20_000)}]

    call = %{
      "role" => "assistant",
      "content" => [
        %{
          "type" => "tool_call",
          "id" => "call-1",
          "name" => "read",
          "arguments" => %{"path" => "fixture"}
        }
      ]
    }

    result = %{
      "role" => "tool_result",
      "tool_call_id" => "call-1",
      "tool_use_id" => "call-1",
      "tool_name" => "read",
      "is_error" => false,
      "content" => output
    }

    recent = %{"role" => "user", "content" => String.duplicate("recent ", 24_000)}
    session = Enum.reduce([call, result, recent], session, &SessionManager.append_message(&2, &1))
    before = SessionManager.build_session_context(session).messages

    # nil is deliberately not a usable summary model: success proves no provider call.
    assert {:ok, compacted} = Compaction.compact(session, nil, recovery_target: 45_000)
    assert compacted.first_kept_entry_id == nil
    assert map_size(compacted.pruned) == 1
    projected = SessionManager.append_pruning(session, compacted.pruned)
    assert [^call, pruned, ^recent] = SessionManager.build_session_context(projected).messages
    assert Map.delete(pruned, "content") == Map.delete(result, "content")
    [%{"text" => reference}] = pruned["content"]
    [uri] = Regex.run(~r/artifact:\/\/[^\s]+/, reference)
    assert {:ok, path} = Artifacts.resolve(uri, cwd, session_id: session.header.id)
    assert Jason.decode!(File.read!(path)) == output
    after_tokens = Compaction.estimate_context_tokens([call, pruned, recent])
    before_tokens = Compaction.estimate_context_tokens(before)
    assert before_tokens - after_tokens > 50_000

    IO.puts(
      "#569 fixture estimated tokens: before=#{before_tokens} after=#{after_tokens} saved=#{before_tokens - after_tokens}"
    )

    journal = Path.join(cwd, "pruned.jsonl")
    assert :ok = SessionManager.save_to_file(journal, projected)
    assert {:ok, resumed} = SessionManager.load_from_file(journal)
    assert SessionManager.build_session_context(resumed).messages == [call, pruned, recent]
    # Navigation before the pruning marker restores original evidence.
    assert SessionManager.build_session_context(projected, session.leaf_id).messages == before
    assert SessionManager.build_session_context(session).messages == before
  end

  @tag :tmp_dir
  test "newest 40k window and sub-50-token results are untouched", %{tmp_dir: cwd} do
    small = %{"role" => "tool_result", "tool_use_id" => "small", "content" => "ok"}

    recent = %{
      "role" => "tool_result",
      "tool_use_id" => "recent",
      "content" => String.duplicate("x", 170_000)
    }

    session =
      Enum.reduce(
        [small, recent],
        SessionManager.new(cwd),
        &SessionManager.append_message(&2, &1)
      )

    assert {_, replacements} = Compaction.prune_tool_results(session)
    assert replacements == %{}
  end
end
