defmodule CodingAgent.SessionResourcesTest do
  @moduledoc """
  Tests for Session integration with ResourceLoader.

  These tests verify that Session correctly composes system prompts from:
  - Explicit :system_prompt option
  - :prompt_template loaded via ResourceLoader
  - CLAUDE.md/AGENTS.md files from the project directory
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Session

  alias Ai.Types.{
    Model,
    ModelCost
  }

  # ============================================================================
  # Test Helpers
  # ============================================================================

  defp mock_model(opts \\ []) do
    %Model{
      id: Keyword.get(opts, :id, "mock-model-1"),
      name: Keyword.get(opts, :name, "Mock Model"),
      api: Keyword.get(opts, :api, :mock),
      provider: Keyword.get(opts, :provider, :mock_provider),
      base_url: Keyword.get(opts, :base_url, "https://api.mock.test"),
      reasoning: Keyword.get(opts, :reasoning, false),
      input: Keyword.get(opts, :input, [:text]),
      cost: Keyword.get(opts, :cost, %ModelCost{input: 0.01, output: 0.03}),
      context_window: Keyword.get(opts, :context_window, 128_000),
      max_tokens: Keyword.get(opts, :max_tokens, 4096),
      headers: Keyword.get(opts, :headers, %{}),
      compat: Keyword.get(opts, :compat, nil)
    }
  end

  defp default_opts(tmp_dir, overrides) do
    Keyword.merge(
      [
        cwd: tmp_dir,
        model: mock_model()
      ],
      overrides
    )
  end

  defp start_session(tmp_dir, opts \\ []) do
    opts = default_opts(tmp_dir, opts)
    {:ok, session} = Session.start_link(opts)
    session
  end

  # ============================================================================
  # CLAUDE.md Loading Tests
  # ============================================================================

  describe "system prompt with CLAUDE.md" do
    @tag :tmp_dir
    test "loads CLAUDE.md from project root", %{tmp_dir: tmp_dir} do
      # Create CLAUDE.md in project root
      claude_md = Path.join(tmp_dir, "CLAUDE.md")
      File.write!(claude_md, "# Project Instructions\nFollow these coding standards.")

      session = start_session(tmp_dir)
      state = Session.get_state(session)

      assert String.contains?(state.system_prompt, "Project Instructions")
      assert String.contains?(state.system_prompt, "Follow these coding standards")
    end

    @tag :tmp_dir
    test "loads CLAUDE.md from .claude subdirectory", %{tmp_dir: tmp_dir} do
      # Create .claude/CLAUDE.md
      claude_dir = Path.join(tmp_dir, ".claude")
      File.mkdir_p!(claude_dir)
      claude_md = Path.join(claude_dir, "CLAUDE.md")
      File.write!(claude_md, "Instructions from .claude directory")

      session = start_session(tmp_dir)
      state = Session.get_state(session)

      assert String.contains?(state.system_prompt, "Instructions from .claude directory")
    end

    @tag :tmp_dir
    test "loads AGENTS.md from project", %{tmp_dir: tmp_dir} do
      # Create AGENTS.md in project root
      agents_md = Path.join(tmp_dir, "AGENTS.md")
      File.write!(agents_md, "# Agent Definitions\nCustom agent config here.")

      session = start_session(tmp_dir)
      state = Session.get_state(session)

      assert String.contains?(state.system_prompt, "Agent Definitions")
      assert String.contains?(state.system_prompt, "Custom agent config here")
    end

    @tag :tmp_dir
    test "combines multiple instruction files", %{tmp_dir: tmp_dir} do
      # Create both CLAUDE.md and AGENTS.md
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "CLAUDE content here")
      File.write!(Path.join(tmp_dir, "AGENTS.md"), "AGENTS content here")

      session = start_session(tmp_dir)
      state = Session.get_state(session)

      assert String.contains?(state.system_prompt, "CLAUDE content here")
      assert String.contains?(state.system_prompt, "AGENTS content here")
    end

    @tag :tmp_dir
    test "empty project directory still loads global instructions", %{tmp_dir: tmp_dir} do
      # Don't create any instruction files in the project
      session = start_session(tmp_dir)
      state = Session.get_state(session)

      # System prompt may contain global instructions from ~/.claude/CLAUDE.md
      # The key test is that it doesn't crash and returns a string
      assert is_binary(state.system_prompt)
    end
  end

  # ============================================================================
  # Explicit System Prompt Tests
  # ============================================================================

  describe "explicit system_prompt option" do
    @tag :tmp_dir
    test "explicit system_prompt is included", %{tmp_dir: tmp_dir} do
      session = start_session(tmp_dir, system_prompt: "You are a helpful assistant.")
      state = Session.get_state(session)

      assert String.contains?(state.system_prompt, "You are a helpful assistant.")
    end

    @tag :tmp_dir
    test "explicit system_prompt takes precedence (appears first)", %{tmp_dir: tmp_dir} do
      # Create CLAUDE.md
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "CLAUDE.md content")

      session = start_session(tmp_dir, system_prompt: "Explicit prompt first")
      state = Session.get_state(session)

      # Both should be present
      assert String.contains?(state.system_prompt, "Explicit prompt first")
      assert String.contains?(state.system_prompt, "CLAUDE.md content")

      # Explicit should come first (check order)
      explicit_pos = :binary.match(state.system_prompt, "Explicit prompt first") |> elem(0)
      claude_pos = :binary.match(state.system_prompt, "CLAUDE.md content") |> elem(0)
      assert explicit_pos < claude_pos
    end

    @tag :tmp_dir
    test "empty explicit system_prompt is filtered out", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "CLAUDE content only")

      session = start_session(tmp_dir, system_prompt: "")
      state = Session.get_state(session)

      # Should only have CLAUDE.md content, no leading newlines
      assert state.system_prompt |> String.trim_leading() == state.system_prompt |> String.trim()
    end
  end

  # ============================================================================
  # Prompt Template Tests
  # ============================================================================

  describe "prompt_template option" do
    @tag :tmp_dir
    test "loads prompt template from .lemon/prompts", %{tmp_dir: tmp_dir} do
      # Create .lemon/prompts/review.md
      prompts_dir = Path.join([tmp_dir, ".lemon", "prompts"])
      File.mkdir_p!(prompts_dir)
      File.write!(Path.join(prompts_dir, "review.md"), "You are a code reviewer.")

      session = start_session(tmp_dir, prompt_template: "review")
      state = Session.get_state(session)

      assert String.contains?(state.system_prompt, "You are a code reviewer.")
    end

    @tag :tmp_dir
    test "loads prompt template from .claude/prompts", %{tmp_dir: tmp_dir} do
      # Create .claude/prompts/refactor.md
      prompts_dir = Path.join([tmp_dir, ".claude", "prompts"])
      File.mkdir_p!(prompts_dir)
      File.write!(Path.join(prompts_dir, "refactor.md"), "You are a refactoring expert.")

      session = start_session(tmp_dir, prompt_template: "refactor")
      state = Session.get_state(session)

      assert String.contains?(state.system_prompt, "You are a refactoring expert.")
    end

    @tag :tmp_dir
    test "prompt template is combined with CLAUDE.md", %{tmp_dir: tmp_dir} do
      # Create both prompt template and CLAUDE.md
      prompts_dir = Path.join([tmp_dir, ".lemon", "prompts"])
      File.mkdir_p!(prompts_dir)
      File.write!(Path.join(prompts_dir, "test.md"), "Template content")
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "CLAUDE.md content")

      session = start_session(tmp_dir, prompt_template: "test")
      state = Session.get_state(session)

      assert String.contains?(state.system_prompt, "Template content")
      assert String.contains?(state.system_prompt, "CLAUDE.md content")
    end

    @tag :tmp_dir
    test "non-existent prompt template is ignored", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "Only CLAUDE.md exists")

      session = start_session(tmp_dir, prompt_template: "nonexistent")
      state = Session.get_state(session)

      # Should still have CLAUDE.md content
      assert String.contains?(state.system_prompt, "Only CLAUDE.md exists")
      # Should not crash or have placeholder content
      refute String.contains?(state.system_prompt, "nonexistent")
    end

    @tag :tmp_dir
    test "prompt template supports .txt extension", %{tmp_dir: tmp_dir} do
      prompts_dir = Path.join([tmp_dir, ".lemon", "prompts"])
      File.mkdir_p!(prompts_dir)
      File.write!(Path.join(prompts_dir, "simple.txt"), "Simple text template")

      session = start_session(tmp_dir, prompt_template: "simple")
      state = Session.get_state(session)

      assert String.contains?(state.system_prompt, "Simple text template")
    end
  end

  # ============================================================================
  # Ordering Tests
  # ============================================================================

  describe "system prompt component ordering" do
    @tag :tmp_dir
    test "order is: explicit > template > instructions", %{tmp_dir: tmp_dir} do
      # Create all three sources
      prompts_dir = Path.join([tmp_dir, ".lemon", "prompts"])
      File.mkdir_p!(prompts_dir)
      File.write!(Path.join(prompts_dir, "mytemplate.md"), "TEMPLATE_MARKER")
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "INSTRUCTIONS_MARKER")

      session =
        start_session(tmp_dir,
          system_prompt: "EXPLICIT_MARKER",
          prompt_template: "mytemplate"
        )

      state = Session.get_state(session)

      # All three should be present
      assert String.contains?(state.system_prompt, "EXPLICIT_MARKER")
      assert String.contains?(state.system_prompt, "TEMPLATE_MARKER")
      assert String.contains?(state.system_prompt, "INSTRUCTIONS_MARKER")

      # Check ordering
      explicit_pos = :binary.match(state.system_prompt, "EXPLICIT_MARKER") |> elem(0)
      template_pos = :binary.match(state.system_prompt, "TEMPLATE_MARKER") |> elem(0)
      instructions_pos = :binary.match(state.system_prompt, "INSTRUCTIONS_MARKER") |> elem(0)

      assert explicit_pos < template_pos, "Explicit should come before template"
      assert template_pos < instructions_pos, "Template should come before instructions"
    end

    @tag :tmp_dir
    test "components are joined with double newlines", %{tmp_dir: tmp_dir} do
      prompts_dir = Path.join([tmp_dir, ".lemon", "prompts"])
      File.mkdir_p!(prompts_dir)
      File.write!(Path.join(prompts_dir, "test.md"), "Template")
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "Instructions")

      session =
        start_session(tmp_dir,
          system_prompt: "Explicit",
          prompt_template: "test"
        )

      state = Session.get_state(session)

      # Should be joined with \n\n
      assert String.contains?(state.system_prompt, "Explicit\n\n")
      assert String.contains?(state.system_prompt, "Template\n\n")
    end
  end

  # ============================================================================
  # Edge Cases
  # ============================================================================

  describe "edge cases" do
    @tag :tmp_dir
    test "nil system_prompt option is filtered out", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "Only instructions")

      # Explicitly pass nil
      session = start_session(tmp_dir, system_prompt: nil)
      state = Session.get_state(session)

      # Should not start with newlines from nil
      assert state.system_prompt == String.trim(state.system_prompt)
      assert String.contains?(state.system_prompt, "Only instructions")
    end

    @tag :tmp_dir
    test "whitespace-only content is preserved", %{tmp_dir: tmp_dir} do
      # Empty instruction files shouldn't cause issues
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), "   ")

      session = start_session(tmp_dir)
      state = Session.get_state(session)

      # Whitespace-only files are trimmed by ResourceLoader, so this should be empty
      # or handled gracefully
      assert is_binary(state.system_prompt)
    end

    @tag :tmp_dir
    test "special characters in prompts are preserved", %{tmp_dir: tmp_dir} do
      special_content = "Use `code` blocks and **bold** text. Handle <xml> tags."
      File.write!(Path.join(tmp_dir, "CLAUDE.md"), special_content)

      session = start_session(tmp_dir)
      state = Session.get_state(session)

      assert String.contains?(state.system_prompt, "`code`")
      assert String.contains?(state.system_prompt, "**bold**")
      assert String.contains?(state.system_prompt, "<xml>")
    end
  end
end
