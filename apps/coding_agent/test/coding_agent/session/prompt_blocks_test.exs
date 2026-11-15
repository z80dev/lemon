defmodule CodingAgent.Session.PromptBlocksTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Session.PromptComposer

  test "compaction estimates ordered blocks exactly like their concatenated request" do
    blocks = [
      %{text: "Static prefix", directory_derived: false},
      %{text: "\n\nDirectory footer", directory_derived: true}
    ]

    assert CodingAgent.Compaction.request_context_usage([], blocks) ==
             CodingAgent.Compaction.request_context_usage([], LemonAi.SystemPrompt.text(blocks))
  end

  @tag :tmp_dir
  test "different worktree directories share a byte-identical static block", %{tmp_dir: root} do
    workspace = Path.join(root, "home")
    File.mkdir_p!(workspace)

    prompts =
      for name <- ["worktree-one", "worktree-two"] do
        cwd = Path.join(root, name)
        File.mkdir_p!(cwd)
        File.write!(Path.join(cwd, "AGENTS.md"), "Instructions for #{name}")

        sections =
          PromptComposer.compose_sections(cwd, nil, nil, workspace, :subagent, "", %{
            session_mode: :coding,
            contributed_sections: [],
            environment: "Working directory: #{cwd}"
          })

        text = CodingAgent.SystemPrompt.join_sections(sections)
        blocks = PromptComposer.prompt_blocks(text, sections)
        assert Enum.map_join(blocks, "", & &1.text) == text
        assert [%{directory_derived: false}, %{directory_derived: true}] = blocks
        blocks
      end

    [first, second] = prompts
    assert hd(first).text == hd(second).text
    refute List.last(first).text == List.last(second).text
    refute hd(first).text =~ root
  end

  test "unmatched overlays never claim a shared static prefix" do
    sections = [
      %{category: :system_prompt, label: "Static", text: "base", directory_derived: false}
    ]

    assert PromptComposer.prompt_blocks("base\n\nplan", sections) == [
             %{text: "base\n\nplan", directory_derived: true}
           ]
  end

  test "footer owns separators and empty directory content adds no block" do
    sections = [
      %{category: :system_prompt, label: "Static", text: "base", directory_derived: false},
      %{category: :system_prompt, label: "Directory", text: "local", directory_derived: true}
    ]

    assert PromptComposer.prompt_blocks("base\n\nlocal", sections) == [
             %{text: "base", directory_derived: false},
             %{text: "\n\nlocal", directory_derived: true}
           ]

    assert PromptComposer.prompt_blocks("base", [hd(sections)]) == [
             %{text: "base", directory_derived: false}
           ]
  end
end
