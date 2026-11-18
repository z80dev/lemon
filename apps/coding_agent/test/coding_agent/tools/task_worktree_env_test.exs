Code.require_file("../../support/task_worktree_case.ex", __DIR__)

defmodule CodingAgent.Tools.TaskWorktreeEnvTest do
  # Mutates the BEAM OS environment, so it cannot run concurrently.
  use CodingAgent.Tools.Task.WorktreeCase, async: false

  @env %{
    "LEMON_NODE_OPERATOR_TOKEN" => "leak-operator",
    "LEMON_SECRETS_MASTER_KEY" => "leak-master",
    "LEMON_OPENAI_API_KEY" => "leak-api",
    "OPENAI_API_KEY" => "ordinary-provider-key"
  }

  setup do
    saved = Map.new(Map.keys(@env), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(saved, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end)
  end

  test "workspace Git filters run by task worktree creation never see Lemon credentials",
       %{git: git, repo: repo, tmp_dir: tmp_dir} do
    dump = Path.join(tmp_dir, "filter-env")
    # A model with workspace shell access can configure a smudge filter.
    git!(git, repo, ["config", "filter.leak.smudge", "env >> '#{dump}'; cat"])
    File.write!(Path.join(repo, ".gitattributes"), "tracked.txt filter=leak\n")
    git!(git, repo, ["add", ".gitattributes"])
    git!(git, repo, ["-c", "core.hooksPath=/dev/null", "commit", "-qm", "Filter"])

    System.put_env(@env)
    assert {:ok, _prepared} = Worktree.prepare(repo, "env-filter")

    output = File.read!(dump)
    assert output =~ "OPENAI_API_KEY=ordinary-provider-key"

    for name <- ["LEMON_NODE_OPERATOR_TOKEN", "LEMON_SECRETS_MASTER_KEY", "LEMON_OPENAI_API_KEY"] do
      refute String.contains?(output, name <> "="), "Git filter inherited #{name}"
    end
  end
end
