defmodule LemonAi.SystemPromptTest do
  use ExUnit.Case, async: true

  alias LemonAi.{PromptDiagnostics, SystemPrompt}
  alias LemonAi.Types.Context

  test "text preserves binary bytes and concatenates blocks without separators" do
    blocks = [
      %{text: "Static\n\n", directory_derived: false},
      %{text: "Directory: /worktree/a", directory_derived: true},
      %{text: <<255>>, directory_derived: true}
    ]

    assert SystemPrompt.text(nil) == ""
    assert SystemPrompt.text([]) == ""
    assert SystemPrompt.text(" exact\n") == " exact\n"
    assert SystemPrompt.text(blocks) == "Static\n\nDirectory: /worktree/a" <> <<255>>
    assert Context.new(system_prompt: blocks).system_prompt == blocks
  end

  test "digest uses canonical ordered blocks, independent of map construction" do
    blocks = [%{text: "Static", directory_derived: false}]
    reconstructed = [Map.new([{:directory_derived, false}, {:text, "Static"}])]

    expected =
      {:system_prompt, 1, [{"Static", false}]}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert SystemPrompt.digest(blocks) == expected
    assert SystemPrompt.digest(reconstructed) == expected
    assert SystemPrompt.digest("Static") == expected
    assert SystemPrompt.digest(nil) == SystemPrompt.digest([])

    assert SystemPrompt.digest(<<255>>) ==
             SystemPrompt.digest([%{text: <<255>>, directory_derived: false}])
  end

  test "digest changes with text, order, boundaries, or directory provenance" do
    blocks = [
      %{text: "A", directory_derived: false},
      %{text: "B", directory_derived: true}
    ]

    for changed <- [
          [%{text: "A", directory_derived: false}, %{text: "C", directory_derived: true}],
          Enum.reverse(blocks),
          [%{text: "AB", directory_derived: false}],
          [%{text: "A", directory_derived: false}, %{text: "B", directory_derived: false}]
        ] do
      refute SystemPrompt.digest(changed) == SystemPrompt.digest(blocks)
    end
  end

  test "diagnostics preserve text sizing and hashes while exposing the block digest" do
    blocks = [
      %{text: "Static\n\n", directory_derived: false},
      %{text: "Directory", directory_derived: true}
    ]

    binary_stats = PromptDiagnostics.stats(Context.new(system_prompt: SystemPrompt.text(blocks)))
    block_stats = PromptDiagnostics.stats(Context.new(system_prompt: blocks))

    assert Map.delete(binary_stats, :system_prompt_digest) ==
             Map.delete(block_stats, :system_prompt_digest)

    assert block_stats.system_prompt_bytes == byte_size("Static\n\nDirectory")
    assert block_stats.system_prompt_digest == SystemPrompt.digest(blocks)
    refute block_stats.system_prompt_digest == binary_stats.system_prompt_digest
  end
end
