defmodule CodingAgent.Session.PromptComposerTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.PromptComposer

  @moduletag :tmp_dir

  test "compose_system_prompt/6 keeps turn-specific skill relevance out of the prompt", %{
    tmp_dir: tmp_dir
  } do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "workspace agents")

    skill_dir = Path.join([tmp_dir, ".lemon", "skill", "github-pr-workflow"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: github-pr-workflow
      description: GitHub pull request lifecycle, CI checks, branches, commits, PR creation
      keywords:
        - github
        - pull request
        - ci
      ---

      Full body should stay behind read_skill.
      """
    )

    github_prompt =
      PromptComposer.compose_system_prompt(
        tmp_dir,
        nil,
        nil,
        workspace_dir,
        :main,
        "please open a GitHub pull request and monitor CI"
      )

    unrelated_prompt =
      PromptComposer.compose_system_prompt(
        tmp_dir,
        nil,
        nil,
        workspace_dir,
        :main,
        "explain an unrelated algorithm"
      )

    assert github_prompt == unrelated_prompt
    refute String.contains?(github_prompt, "<relevant-skills>")
    assert String.contains?(github_prompt, "<key>github-pr-workflow</key>")
    refute String.contains?(github_prompt, "Full body should stay behind read_skill.")
  end

  test "compose_system_prompt/7 puts the environment block after every static section", %{
    tmp_dir: tmp_dir
  } do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(tmp_dir, "AGENTS.md"), "project instructions marker")

    environment =
      CodingAgent.SystemPrompt.Environment.capture(tmp_dir,
        date: ~D[2026-09-27],
        shell: "/bin/zsh"
      )

    prompt =
      PromptComposer.compose_system_prompt(
        tmp_dir,
        "explicit prompt marker",
        nil,
        workspace_dir,
        :main,
        "",
        %{environment: environment, tool_names: ["read", "edit", "bash"]}
      )

    assert String.ends_with?(prompt, environment)
    assert environment =~ "Working directory: #{tmp_dir}"
    assert environment =~ "Shell: /bin/zsh"
    refute environment =~ "Today's date:"

    positions =
      Enum.map(
        [
          "explicit prompt marker",
          "## Working on code",
          "project instructions marker",
          "## Environment"
        ],
        fn marker -> prompt |> :binary.match(marker) |> elem(0) end
      )

    assert positions == Enum.sort(positions)
  end

  test "date, branch and dirty-file changes never change the system bytes", %{tmp_dir: cwd} do
    git = System.find_executable("git") || flunk("Git is required")
    {_, 0} = System.cmd(git, ["init", "-q", "-b", "before", cwd])
    workspace = Path.join(cwd, "workspace")
    File.mkdir_p!(workspace)
    environment = CodingAgent.SystemPrompt.Environment.capture(cwd)

    compose = fn ->
      PromptComposer.compose_system_prompt(
        cwd,
        nil,
        nil,
        workspace,
        :main,
        "",
        %{environment: environment, contributed_sections: []}
      )
    end

    first = compose.()
    before = CodingAgent.SystemPrompt.Environment.turn_section(cwd, date: ~D[2026-01-01])
    {_, 0} = System.cmd(git, ["-C", cwd, "symbolic-ref", "HEAD", "refs/heads/after"])
    File.write!(Path.join(cwd, "dirty.txt"), "changed")
    after_turn = CodingAgent.SystemPrompt.Environment.turn_section(cwd, date: ~D[2026-01-02])
    assert compose.() == first
    assert before.body =~ "2026-01-01"
    assert before.body =~ "before"
    assert after_turn.body =~ "2026-01-02"
    assert after_turn.body =~ "after"
    assert after_turn.body =~ "dirty.txt"
    assert {[], [^after_turn]} = LemonAgent.ContextRegistry.split([after_turn])
    refute first =~ "Today's date:"
    refute first =~ "Git status"
  end

  test "resume reuses durable orientation and cwd changes explicitly refresh it", %{tmp_dir: cwd} do
    alias CodingAgent.SessionManager
    path = Path.join(cwd, "session.jsonl")
    session = SessionManager.new(cwd) |> SessionManager.persist(path)

    {session, "original"} =
      SessionManager.capture_environment(session, cwd, fn _ -> "original" end)

    assert length(SessionManager.entries(session)) == 1
    {:ok, resumed} = SessionManager.load_from_file(path)

    {resumed, "original"} =
      SessionManager.capture_environment(resumed, cwd, fn _ -> flunk("recaptured on resume") end)

    assert length(SessionManager.entries(resumed)) == 1

    {changed, "refreshed"} =
      SessionManager.capture_environment(resumed, Path.join(cwd, "other"), fn _ -> "refreshed" end)

    assert length(SessionManager.entries(changed)) == 2

    {_, "new session"} =
      SessionManager.capture_environment(SessionManager.new(cwd), cwd, fn _ -> "new session" end)
  end
end
