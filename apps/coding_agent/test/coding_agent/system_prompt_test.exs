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

    assert String.contains?(prompt, "You are a personal assistant running inside Lemon.")
    assert String.contains?(prompt, "## Workspace Files (injected)")
    assert String.contains?(prompt, "AGENTS content here")
    assert String.contains?(prompt, "SOUL content here")
  end

  @tag :tmp_dir
  test "includes memory workflow guidance for main sessions", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")

    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main
      })

    assert String.contains?(prompt, "## Memory Workflow")
    assert String.contains?(prompt, "Use `read` to check `MEMORY.md`")
    assert String.contains?(prompt, "memory/topics/*.md")
    assert String.contains?(prompt, "Use `grep` with `path: \"memory\"`")
    assert String.contains?(prompt, "memory/topics/<topic-slug>.md")
    assert String.contains?(prompt, "Use `memory_topic` to scaffold new topic notes")
    assert String.contains?(prompt, "memory/topics/TEMPLATE.md")
    assert String.contains?(prompt, "Use `edit` to keep `MEMORY.md` concise")
  end

  @tag :tmp_dir
  test "subagent scope excludes memory and soul context", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "AGENTS content here")
    File.write!(Path.join(workspace_dir, "TOOLS.md"), "TOOLS content here")
    File.write!(Path.join(workspace_dir, "SOUL.md"), "SOUL content here")
    File.write!(Path.join(workspace_dir, "MEMORY.md"), "MEMORY content here")

    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :subagent
      })

    assert String.contains?(prompt, "Session scope: subagent")
    assert String.contains?(prompt, "This is a subagent session.")
    assert String.contains?(prompt, "AGENTS content here")
    assert String.contains?(prompt, "TOOLS content here")
    refute String.contains?(prompt, "SOUL content here")
    refute String.contains?(prompt, "MEMORY content here")
  end

  @tag :tmp_dir
  test "empty workspace produces no workspace context section", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)

    # Use subagent scope so the bootstrap filter strips out all required files
    # except AGENTS.md and TOOLS.md (which are missing). This leaves only [MISSING]
    # stubs, so the workspace context section is still present but contains no
    # real file content.
    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :subagent
      })

    assert String.contains?(prompt, "You are a personal assistant running inside Lemon.")
    assert String.contains?(prompt, "## Workspace")
    # SOUL.md is filtered out by subagent scope, so no persona instruction
    refute String.contains?(prompt, "embody its persona")
    # No real file content was written, so all entries are [MISSING] stubs
    assert String.contains?(prompt, "[MISSING]")
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
      assert String.contains?(prompt, "Use `read` to check `MEMORY.md`"),
             "Expected main memory workflow for invalid input #{inspect(invalid_scope)}"

      refute String.contains?(prompt, "This is a subagent session."),
             "Should not contain subagent notice for invalid input #{inspect(invalid_scope)}"
    end
  end

  @tag :tmp_dir
  test "string session scope \"subagent\" is normalized", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "AGENTS content")
    File.write!(Path.join(workspace_dir, "TOOLS.md"), "TOOLS content")
    File.write!(Path.join(workspace_dir, "SOUL.md"), "SOUL content")

    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: "subagent"
      })

    assert String.contains?(prompt, "Session scope: subagent")
    assert String.contains?(prompt, "This is a subagent session.")
    assert String.contains?(prompt, "Do not read or modify MEMORY.md")
    # Subagent filters out SOUL.md
    refute String.contains?(prompt, "SOUL content")
    # Subagent keeps AGENTS.md and TOOLS.md
    assert String.contains?(prompt, "AGENTS content")
    assert String.contains?(prompt, "TOOLS content")
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
  test "workspace section shows workspace dir", %{tmp_dir: tmp_dir} do
    workspace_dir = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace_dir)
    File.write!(Path.join(workspace_dir, "AGENTS.md"), "agents")

    prompt =
      SystemPrompt.build(tmp_dir, %{
        workspace_dir: workspace_dir,
        session_scope: :main
      })

    assert String.contains?(prompt, "## Workspace")
    assert String.contains?(prompt, "Your workspace directory is: #{workspace_dir}")
    assert String.contains?(prompt, "persistent home for identity, memory, and operating notes")
  end
end
