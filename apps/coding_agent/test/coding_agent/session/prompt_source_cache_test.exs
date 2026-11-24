defmodule CodingAgent.Session.PromptSourceCacheTest do
  # Changes HOME and LEMON_AGENT_DIR, which instruction and rule discovery read.
  use ExUnit.Case, async: false

  alias CodingAgent.Session.PromptComposer
  alias CodingAgent.SystemPrompt

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    previous = Map.new(["HOME", "LEMON_AGENT_DIR"], &{&1, System.get_env(&1)})
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(home)
    System.put_env("HOME", home)
    System.put_env("LEMON_AGENT_DIR", Path.join(tmp_dir, "agent"))

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    repo = Path.join(tmp_dir, "repo")
    CodingAgent.TestGitRepo.init!(repo)

    files = %{
      agents: write!(Path.join(repo, "AGENTS.md"), "Project guide. See @docs/style.md."),
      style: write!(Path.join(repo, "docs/style.md"), "Imported style guide."),
      global: write!(Path.join(home, ".lemon/AGENTS.md"), "Global guide."),
      always: write!(Path.join(repo, ".cursor/rules/always.mdc"), always_rule("one")),
      book: write!(Path.join(repo, ".lemon/rules/db.md"), "---\nglobs: [\"*.sql\"]\n---\ndb")
    }

    # Older than the current second, so the stat cache trusts them.
    past = System.os_time(:second) - 60
    Enum.each(Map.values(files), &File.touch!(&1, past))

    test_pid = self()
    handler = "prompt-source-reads-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:coding_agent, :prompt_sources, :read],
      fn _event, %{bytes: bytes}, _meta, _config ->
        if self() == test_pid, do: send(test_pid, {:prompt_source_read, bytes})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, repo: repo, workspace: Path.join(tmp_dir, "workspace"), files: files}
  end

  test "a second turn with no file changes reads no instruction or rule file", %{
    repo: repo,
    workspace: workspace
  } do
    first = compose(repo, workspace)
    first_reads = drain_reads()

    assert first =~ "Project guide."
    assert first =~ "Imported style guide."
    assert first =~ "Global guide."
    assert first =~ "always rule one"
    assert first =~ "- db\n  Globs: *.sql"
    assert first_reads == 5

    second = compose(repo, workspace)

    assert drain_reads() == 0
    assert second == first
  end

  test "editing a rule changes the prompt on the next turn", %{
    repo: repo,
    workspace: workspace,
    files: files
  } do
    first = compose(repo, workspace)
    assert first =~ "always rule one"

    # Same size, written within the second of the previous read.
    File.write!(files.always, always_rule("two"))
    second = compose(repo, workspace)
    assert second =~ "always rule two"
    refute second =~ "always rule one"

    File.write!(files.style, "Imported style guide, revised.")
    third = compose(repo, workspace)
    assert third =~ "Imported style guide, revised."
  end

  defp compose(repo, workspace) do
    repo
    |> PromptComposer.compose_sections(nil, nil, workspace, :main, "", %{session_mode: :coding})
    |> SystemPrompt.join_sections()
  end

  defp drain_reads(count \\ 0) do
    receive do
      {:prompt_source_read, _bytes} -> drain_reads(count + 1)
    after
      0 -> count
    end
  end

  defp always_rule(word), do: "---\nalwaysApply: true\n---\nalways rule #{word}"

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end
end
