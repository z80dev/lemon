defmodule LemonAgent.PromptBlockContextTest do
  use ExUnit.Case, async: true

  test "context measurements match the concatenated provider prompt" do
    blocks = [
      %{text: "Shared coding guidance", directory_derived: false},
      %{text: "\n\nWorking directory: /worktree", directory_derived: true}
    ]

    text = LemonAi.SystemPrompt.text(blocks)
    assert LemonAgent.Context.estimate_size([], blocks) == String.length(text)
    assert LemonAgent.Context.stats([], blocks).system_prompt_chars == String.length(text)

    assert LemonAgent.Context.estimate_size([], blocks) ==
             LemonAgent.Context.estimate_size([], text)
  end
end
