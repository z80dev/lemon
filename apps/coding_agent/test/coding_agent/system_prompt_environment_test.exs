defmodule CodingAgent.SystemPromptEnvironmentTest do
  # The large filesystem fixture must not contend with async file_server users.
  use ExUnit.Case, async: false

  alias CodingAgent.SystemPrompt.Environment

  @moduletag :tmp_dir

  describe "Environment.capture/2" do
    test "reports branch and a bounded status snapshot with the date last", %{tmp_dir: tmp_dir} do
      git = git!()
      {_, 0} = System.cmd(git, ["init", "-q", "-b", "feature-x", tmp_dir])
      File.write!(Path.join(tmp_dir, "untracked.ex"), "x")

      block = Environment.capture(tmp_dir, date: ~D[2026-01-02])

      assert block =~ "Git repository: yes (branch: No commits yet on feature-x)"
      assert block =~ "Git status at session start (a snapshot"
      assert block =~ "?? untracked.ex"
      assert String.ends_with?(block, "Today's date: 2026-01-02")
    end

    test "marks a confirmed plain directory as not a repository" do
      dir = Path.join(System.tmp_dir!(), "lemon-env-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      block = Environment.capture(dir, git_executable: git!(), date: ~D[2026-01-02])

      assert block =~ "Working directory: #{dir}"
      assert block =~ "Git repository: no"
    end

    test "nested cwd identifies the linked worktree root and indexes sibling guides", %{
      tmp_dir: tmp_dir
    } do
      git = git!()
      repo = Path.join(tmp_dir, "repository")
      worktree = Path.join(tmp_dir, "linked-worktree")
      {_, 0} = System.cmd(git, ["init", "-q", "-b", "main", repo])

      {_, 0} =
        System.cmd(git, [
          "-C",
          repo,
          "-c",
          "user.name=Test",
          "-c",
          "user.email=test@example.invalid",
          "commit",
          "--allow-empty",
          "-qm",
          "initial"
        ])

      {_, 0} = System.cmd(git, ["-C", repo, "worktree", "add", "-qb", "feature", worktree])
      cwd = Path.join(worktree, "apps/current/src")
      File.mkdir_p!(cwd)
      guide = write_guide(worktree, "apps/sibling/AGENTS.md", "do-not-inline-this-guide")
      write_guide(worktree, "apps/current/.claude/CLAUDE.md", "another-guide-body")
      {root_output, 0} = System.cmd(git, ["-C", cwd, "rev-parse", "--show-toplevel"])
      root = String.trim(root_output)

      block = Environment.capture(cwd, date: ~D[2026-01-02])

      assert block =~ "Working directory: #{cwd}"
      assert block =~ "Git worktree root: #{root}"
      assert block =~ "Workspace snapshot root: #{root}"
      assert block =~ Path.join(root, "apps/sibling/AGENTS.md")
      assert block =~ Path.join(root, "apps/current/.claude/CLAUDE.md")
      refute block =~ "do-not-inline-this-guide"
      refute block =~ "another-guide-body"
      assert File.regular?(guide)
    end

    test "Git discovery excludes ignored and generated guides", %{tmp_dir: tmp_dir} do
      git = git!()
      {_, 0} = System.cmd(git, ["init", "-q", tmp_dir])
      File.write!(Path.join(tmp_dir, ".gitignore"), "ignored/\n")
      write_guide(tmp_dir, "src/AGENTS.md", "local rules")
      write_guide(tmp_dir, "src/.lemon/CLAUDE.md", "local config rules")
      write_guide(tmp_dir, "ignored/CLAUDE.md", "ignored rules")

      generated = ~w(node_modules deps _build vendor cache .cache)
      Enum.each(generated, &write_guide(tmp_dir, "#{&1}/nested/AGENTS.md", "generated rules"))
      # Even tracked generated files must not become editing guidance.
      {_, 0} = System.cmd(git, ["-C", tmp_dir, "add", "vendor/nested/AGENTS.md"])

      block = Environment.capture(tmp_dir, date: ~D[2026-01-02])

      assert block =~ Path.join(tmp_dir, "src/AGENTS.md")
      assert block =~ Path.join(tmp_dir, "src/.lemon/CLAUDE.md")
      refute block =~ Path.join(tmp_dir, "ignored/CLAUDE.md")

      Enum.each(generated, fn dir ->
        refute block =~ Path.join(tmp_dir, "#{dir}/nested/AGENTS.md")
      end)
    end

    test "unavailable Git is not reported as a non-repository and fallback skips symlinks", %{
      tmp_dir: tmp_dir
    } do
      write_guide(tmp_dir, "src/nested/AGENTS.md", "local rules")
      write_guide(tmp_dir, "src/.lemon/CLAUDE.md", "config rules")

      Enum.each(~w(.git node_modules deps _build vendor cache .cache), fn dir ->
        write_guide(tmp_dir, "#{dir}/nested/CLAUDE.md", "generated rules")
      end)

      File.ln_s!(Path.join(tmp_dir, "src"), Path.join(tmp_dir, "linked"))
      File.ln_s!(Path.join(tmp_dir, "src/nested/AGENTS.md"), Path.join(tmp_dir, "src/CLAUDE.md"))

      block = Environment.capture(tmp_dir, git_executable: nil, date: ~D[2026-01-02])

      assert block =~ "Git repository: unavailable"
      refute block =~ "Git repository: no"
      assert block =~ "Git ignore rules unavailable"
      assert block =~ Path.join(tmp_dir, "src/nested/AGENTS.md")
      assert block =~ Path.join(tmp_dir, "src/.lemon/CLAUDE.md")
      refute block =~ Path.join(tmp_dir, "linked/nested/AGENTS.md")
      refute block =~ Path.join(tmp_dir, "src/CLAUDE.md")

      Enum.each(~w(.git node_modules deps _build vendor cache .cache), fn dir ->
        refute block =~ Path.join(tmp_dir, "#{dir}/nested/CLAUDE.md")
      end)
    end

    test "Git timeout and failed executable lookup are unavailable, not no repository", %{
      tmp_dir: tmp_dir
    } do
      executable = Path.join(tmp_dir, "slow-git")
      File.write!(executable, "#!/bin/sh\nexec sleep 2\n")
      File.chmod!(executable, 0o755)

      timed_out = Environment.capture(tmp_dir, git_executable: executable, git_timeout_ms: 10)
      missing = Environment.capture(tmp_dir, git_executable: Path.join(tmp_dir, "missing-git"))

      assert timed_out =~ "Git repository: unavailable (timeout)"
      assert missing =~ "Git repository: unavailable"
      refute timed_out =~ "Git repository: no"
      refute missing =~ "Git repository: no"
    end

    test "filesystem probe unavailability stays distinct from an empty completed scan", %{
      tmp_dir: tmp_dir
    } do
      opts = [git_executable: nil, shell: "/bin/sh", date: ~D[2026-01-02]]

      unavailable =
        Environment.capture(tmp_dir, Keyword.put(opts, :filesystem_probe, fn _scan -> nil end))

      completed =
        Environment.capture(
          tmp_dir,
          Keyword.put(opts, :filesystem_probe, fn scan -> {:ok, scan.()} end)
        )

      assert unavailable =~ "filesystem scan unavailable"
      assert unavailable =~ "instruction index unavailable"
      refute completed =~ "filesystem scan unavailable"
      refute completed =~ "instruction index unavailable"
    end

    test "instruction and layout caps are labelled and capture ordering is stable", %{
      tmp_dir: tmp_dir
    } do
      for index <- 1..205 do
        dir = "guide-#{String.pad_leading(Integer.to_string(index), 3, "0")}"
        write_guide(tmp_dir, "#{dir}/AGENTS.md", "rules")
      end

      opts = [
        git_executable: nil,
        shell: "/bin/zsh",
        date: ~D[2026-01-02],
        # Exercise the real traversal and rendering, not a race against the
        # production probe deadline (whose unavailable result is valid).
        filesystem_probe: fn scan -> {:ok, scan.()} end
      ]

      block = Environment.capture(tmp_dir, opts)

      assert Environment.capture(tmp_dir, opts) == block
      assert block =~ "instruction index truncated"
      assert block =~ "workspace layout truncated"
      assert block =~ Path.join(tmp_dir, "guide-001/AGENTS.md")
      assert block =~ Path.join(tmp_dir, "guide-200/AGENTS.md")
      refute block =~ Path.join(tmp_dir, "guide-201/AGENTS.md")
      assert length(:binary.matches(block, "/AGENTS.md\"")) == 200
      assert String.ends_with?(block, "Today's date: 2026-01-02")
    end
  end

  defp git!,
    do:
      System.find_executable("git") ||
        flunk("Git is required for repository discovery regressions")

  defp write_guide(root, relative_path, content) do
    path = Path.join(root, relative_path)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content, [:raw])
    path
  end
end
