defmodule CodingAgent.SystemPromptTest do
  use ExUnit.Case, async: false

  alias CodingAgent.SystemPrompt

  @tag :tmp_dir
  test "injects workspace files into prompt", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "AGENTS content here")
    File.write!(Path.join(workspace_dir, "SOUL.md"), "SOUL content here")

    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        bootstrap_max_chars: 10_000
      })

    assert String.contains?(prompt, "## Workspace Files (injected)")
    assert String.contains?(prompt, "AGENTS content here")
    assert String.contains?(prompt, "SOUL content here")
  end

  @tag :tmp_dir
  test "keeps the system prompt stable across unrelated skill contexts", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")

    skill_dir = Path.join([tmp_dir, ".lemon", "skill", "github-pr-workflow"])
    File.mkdir_p!(skill_dir)

    skill_body = "Follow the complete GitHub PR lifecycle details."

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: github-pr-workflow
      description: GitHub pull request lifecycle, CI checks, branches, commits, PR creation, merge readiness
      keywords:
        - github
        - pull request
        - pr
        - ci
      ---

      #{skill_body}
      """
    )

    github_prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main,
        skill_context: "please create a GitHub pull request and watch CI"
      })

    unrelated_prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main,
        skill_context: "explain an unrelated database migration"
      })

    assert github_prompt == unrelated_prompt
    refute String.contains?(github_prompt, "<relevant-skills>")
    assert String.contains?(github_prompt, "<available_skills>")
    assert String.contains?(github_prompt, "github-pr-workflow")
    refute String.contains?(github_prompt, skill_body)
  end

  @tag :tmp_dir
  test "omits relevance-selected skill hints without skill context", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")

    skill_dir = Path.join([tmp_dir, ".lemon", "skill", "github-pr-workflow"])
    File.mkdir_p!(skill_dir)

    File.write!(
      Path.join(skill_dir, "SKILL.md"),
      """
      ---
      name: github-pr-workflow
      description: GitHub pull request lifecycle
      ---

      Follow the full workflow.
      """
    )

    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main
      })

    refute String.contains?(prompt, "<relevant-skills>")
    assert String.contains?(prompt, "<available_skills>")
    assert String.contains?(prompt, "github-pr-workflow")
  end

  @tag :tmp_dir
  test "subagent scope excludes memory and soul context", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "AGENTS content here")
    File.write!(Path.join(workspace_dir, "TOOLS.md"), "TOOLS content here")
    File.write!(Path.join(workspace_dir, "SOUL.md"), "SOUL content here")
    File.write!(Path.join(workspace_dir, "MEMORY.md"), "MEMORY content here")
    File.write!(Path.join(workspace_dir, "USER.md"), "Private user preferences")

    for scope <- [:subagent, "subagent"] do
      prompt =
        SystemPrompt.build(tmp_dir, %{
          workspace_dir: workspace_dir,
          session_scope: scope
        })

      assert String.contains?(prompt, "AGENTS content here")
      assert String.contains?(prompt, "TOOLS content here")
      refute String.contains?(prompt, "SOUL content here")
      refute String.contains?(prompt, "MEMORY content here")
      refute String.contains?(prompt, "Private user preferences")
    end
  end

  @tag :tmp_dir
  test "empty workspace produces no workspace context section", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)

    # Missing assistant-home files must not become apparent repository context.
    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :subagent
      })

    assert String.contains?(prompt, "## Boundaries")
    # SOUL.md is filtered out by subagent scope, so no persona instruction
    refute String.contains?(prompt, "embody its persona")
    refute String.contains?(prompt, "## Workspace Files (injected)")
    refute String.contains?(prompt, "[MISSING]")
  end

  @tag :tmp_dir
  test "SOUL.md triggers persona instruction", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "SOUL.md"), "Be quirky and fun.")

    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main
      })

    assert String.contains?(prompt, "## Workspace Files (injected)")
    assert String.contains?(prompt, "embody its persona and tone")
    assert String.contains?(prompt, "Be quirky and fun.")
  end

  @tag :tmp_dir
  test "SOUL.md absent does not have persona instruction", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents content")
    File.write!(Path.join(workspace_dir, "TOOLS.md"), "tools content")

    # Use subagent scope so SOUL.md is filtered out of workspace context entirely.
    # This is the scenario where the persona instruction should NOT appear.
    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :subagent
      })

    refute String.contains?(prompt, "embody its persona and tone")
    refute String.contains?(prompt, "embody")
    # The workspace context section is still present with the allowed files
    assert String.contains?(prompt, "## Workspace Files (injected)")
    assert String.contains?(prompt, "agents content")
    assert String.contains?(prompt, "tools content")
  end

  @tag :tmp_dir
  test "session scope defaults to main for invalid values", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")

    for invalid_scope <- [:invalid, "random", :foo, "bar", nil, 42] do
      prompt =
        SystemPrompt.build(tmp_dir, %{
          workspace_dir: workspace_dir,
          session_scope: invalid_scope
        })

      assert String.contains?(prompt, "Session scope: main"),
             "Expected scope: main for invalid input #{inspect(invalid_scope)}"

      # Main sessions get the full memory workflow, not the subagent restriction
      assert String.contains?(prompt, "use `recall`"),
             "Expected main memory workflow for invalid input #{inspect(invalid_scope)}"

      refute String.contains?(prompt, "This is a subagent session."),
             "Should not contain subagent notice for invalid input #{inspect(invalid_scope)}"
    end
  end

  @tag :tmp_dir
  test "runtime section shows session scope", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")

    main_prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main
      })

    assert String.contains?(main_prompt, "## Runtime")
    assert String.contains?(main_prompt, "Session scope: main")

    subagent_prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :subagent
      })

    assert String.contains?(subagent_prompt, "## Runtime")
    assert String.contains?(subagent_prompt, "Session scope: subagent")
  end

  @tag :tmp_dir
  test "JSON persona snapshots retain destination USER additions and deletions across bootstraps", %{
    tmp_dir: tmp_dir
  } do
    workspace_dir = Path.join(tmp_dir, "destination-workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "TOOLS.md"), "destination-local-tool-instructions")

    snapshot =
      %{
        "AGENTS.md" => "controller-agent-instructions",
        "IDENTITY.md" => "controller-identity",
        "README.md" => "controller-profile-job",
        "SOUL.md" => "controller-persona"
      }
      |> Jason.encode!()
      |> Jason.decode!()

    opts = %{
      workspace_dir: workspace_dir,
      profile_instructions: snapshot,
      session_scope: :main
    }

    user_path = Path.join(workspace_dir, "USER.md")
    initial_prompt = SystemPrompt.build(tmp_dir, opts)
    assert initial_prompt =~ "controller-persona"
    refute File.exists?(user_path)

    remember =
      LemonSkills.Tools.Remember.tool(tmp_dir,
        workspace_dir: workspace_dir,
        session_scope: :main
      )

    retained_fact = "Prefers concise weekly updates."
    removed_fact = "Prefers handmade wooden birthday gifts."

    for {fact, call_id} <- [{retained_fact, "remember-retained"}, {removed_fact, "remember-removed"}] do
      assert %{details: %{target: "user", action: "add", changed: true}} =
               remember.execute.(call_id, %{"target" => "user", "text" => fact}, nil, nil)
    end

    assert File.read!(user_path) =~ retained_fact
    assert File.read!(user_path) =~ removed_fact
    next_prompt = SystemPrompt.build(tmp_dir, opts)
    assert next_prompt =~ retained_fact
    assert next_prompt =~ removed_fact
    assert next_prompt =~ "controller-persona"
    assert next_prompt =~ "destination-local-tool-instructions"

    for scope <- [:subagent, "subagent"] do
      child_prompt = SystemPrompt.build(tmp_dir, %{opts | session_scope: scope})
      assert child_prompt =~ "controller-agent-instructions"
      assert child_prompt =~ "destination-local-tool-instructions"
      refute child_prompt =~ retained_fact
      refute child_prompt =~ removed_fact
      refute child_prompt =~ "controller-persona"
      refute child_prompt =~ "controller-identity"
      refute child_prompt =~ "controller-profile-job"
    end

    assert {:ok, entries} = LemonSkills.WorkspacePreferences.list(workspace_dir)
    entry = Enum.find(entries, &(&1["kind"] == "user" and &1["text"] == removed_fact))
    assert entry
    id = entry["id"]

    assert {:ok, %{id: ^id, revision: revision}} =
             LemonSkills.WorkspacePreferences.preview_delete(workspace_dir, id)

    assert {:ok, %{"deleted" => true, "id" => ^id}} =
             LemonSkills.WorkspacePreferences.delete(workspace_dir, id, revision)

    refute File.read!(user_path) =~ removed_fact
    after_delete_prompt = SystemPrompt.build(tmp_dir, opts)
    refute after_delete_prompt =~ removed_fact
    assert after_delete_prompt =~ retained_fact
    assert after_delete_prompt =~ "controller-persona"
    assert {:error, :not_found} = LemonSkills.WorkspacePreferences.get(workspace_dir, id)
  end
end
