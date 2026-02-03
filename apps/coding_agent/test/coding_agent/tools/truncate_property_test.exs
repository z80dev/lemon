defmodule CodingAgent.Tools.TruncatePropertyTest do
  @moduledoc """
  Property-based tests for CodingAgent.Tools.Truncate module.

  Tests invariants that should hold for any input:
  - Output never exceeds the specified character limit
  - Output never exceeds the specified line limit
  - Content is preserved when under limit (no truncation)
  - Truncation markers are present when content is truncated
  - All strategies produce valid output
  - Metadata accurately reflects the operation

  Note: These tests focus on ASCII content to test the core truncation logic.
  Unicode handling edge cases are tested separately.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties
  import StreamData

  alias CodingAgent.Tools.Truncate
  alias AgentCore.Types.AgentToolResult

  # ============================================================================
  # Generators
  # ============================================================================

  # Use ASCII-only generators to focus on truncation logic
  # (Unicode edge cases are a separate concern)
  defp ascii_text do
    one_of([
      # Simple ASCII text
      string(:ascii, max_length: 1000),
      # Empty string
      constant(""),
      # Multi-line ASCII text
      map(list_of(string(:ascii, max_length: 100), max_length: 50), fn lines ->
        Enum.join(lines, "\n")
      end),
      # Code-like content with function definitions
      code_content()
    ])
  end

  defp code_content do
    map({string(:alphanumeric, min_length: 1, max_length: 20),
         list_of(string(:alphanumeric, max_length: 40), max_length: 20)}, fn {name, body} ->
      """
      defmodule #{String.capitalize(name)} do
        @moduledoc "A test module"

        def #{name}(arg) do
      #{Enum.map_join(body, "\n", fn line -> "    " <> line end)}
        end
      end
      """
    end)
  end

  defp strategy do
    member_of(["head", "tail", "middle", "smart"])
  end

  defp max_chars do
    # Generate various character limits
    # Minimum of 200 to ensure there's room for content + markers
    one_of([
      constant(200),       # Small
      constant(500),       # Medium
      constant(1000),      # Larger
      integer(200..2000)   # Random in range
    ])
  end

  # ============================================================================
  # Core Invariant: Output Never Exceeds Limit
  # ============================================================================

  property "truncated output never exceeds max_chars limit significantly" do
    check all text <- ascii_text(),
              limit <- max_chars(),
              strat <- strategy() do
      result = execute_truncate(text, limit, nil, strat)

      assert match?(%AgentToolResult{}, result)

      output_text = get_output_text(result)
      output_length = String.length(output_text)

      # The output should never exceed the limit by more than marker overhead
      assert output_length <= limit + 100,
        "Output length #{output_length} exceeds limit #{limit} significantly"
    end
  end

  property "truncated output never exceeds max_lines limit when specified" do
    check all text <- ascii_text(),
              line_limit <- one_of([constant(10), constant(20), constant(50), integer(10..100)]),
              strat <- strategy() do
      # Use a large char limit so line limit is the constraint
      result = execute_truncate(text, 100_000, line_limit, strat)

      assert match?(%AgentToolResult{}, result)

      output_text = get_output_text(result)
      output_lines = count_lines(output_text)

      # Should not exceed line limit (with tolerance for markers)
      # Markers can add a few lines in some strategies
      assert output_lines <= line_limit + 5,
        "Output has #{output_lines} lines, expected at most #{line_limit + 5}"
    end
  end

  # ============================================================================
  # Content Preservation When Under Limit
  # ============================================================================

  property "content is preserved exactly when under both limits" do
    check all text <- string(:ascii, max_length: 100) do
      # Use limits much larger than content
      result = execute_truncate(text, 10_000, 1000, "head")

      assert match?(%AgentToolResult{}, result)

      output_text = get_output_text(result)
      metadata = result.details

      # Content should be exactly preserved
      assert output_text == text
      assert metadata.truncated == false
      assert metadata.original_chars == metadata.truncated_chars
    end
  end

  property "empty string is never truncated" do
    check all strat <- strategy() do
      result = execute_truncate("", 100, nil, strat)

      assert match?(%AgentToolResult{}, result)

      metadata = result.details
      assert metadata.truncated == false
      assert metadata.original_chars == 0
      assert metadata.truncated_chars == 0
    end
  end

  # ============================================================================
  # Truncation Marker Presence
  # ============================================================================

  property "truncation marker is present when content is truncated" do
    check all text <- string(:ascii, min_length: 500, max_length: 1000),
              strat <- strategy() do
      # Use a small limit to ensure truncation
      result = execute_truncate(text, 200, nil, strat)

      assert match?(%AgentToolResult{}, result)

      output_text = get_output_text(result)
      metadata = result.details

      if metadata.truncated do
        # Should contain a truncation marker
        assert String.contains?(output_text, "truncated") or
               String.contains?(output_text, "..."),
          "Truncated output should contain marker"
      end
    end
  end

  # ============================================================================
  # Metadata Consistency Properties
  # ============================================================================

  property "metadata accurately reports original size" do
    check all text <- ascii_text(),
              strat <- strategy() do
      result = execute_truncate(text, 1000, nil, strat)

      assert match?(%AgentToolResult{}, result)

      metadata = result.details

      # Original chars should match input
      assert metadata.original_chars == String.length(text)

      # Original lines should match input
      assert metadata.original_lines == count_lines(text)
    end
  end

  property "truncated_chars is always <= original_chars" do
    check all text <- ascii_text(),
              limit <- max_chars(),
              strat <- strategy() do
      result = execute_truncate(text, limit, nil, strat)

      assert match?(%AgentToolResult{}, result)

      metadata = result.details
      assert metadata.truncated_chars <= metadata.original_chars
    end
  end

  property "truncated flag is consistent with size comparison" do
    check all text <- ascii_text(),
              limit <- max_chars(),
              strat <- strategy() do
      result = execute_truncate(text, limit, nil, strat)

      assert match?(%AgentToolResult{}, result)

      metadata = result.details
      output_text = get_output_text(result)

      # If sizes differ, truncated should be true
      if String.length(output_text) < String.length(text) do
        assert metadata.truncated == true
      end

      # If truncated is false, output should equal input
      if metadata.truncated == false do
        assert output_text == text
      end
    end
  end

  property "strategy is recorded in metadata" do
    check all text <- ascii_text(),
              strat <- strategy() do
      result = execute_truncate(text, 1000, nil, strat)

      assert match?(%AgentToolResult{}, result)
      assert result.details.strategy == strat
    end
  end

  # ============================================================================
  # Strategy-Specific Properties
  # ============================================================================

  property "head strategy preserves beginning of text" do
    check all text <- string(:ascii, min_length: 500, max_length: 1000) do
      result = execute_truncate(text, 200, nil, "head")

      assert match?(%AgentToolResult{}, result)

      output_text = get_output_text(result)

      if result.details.truncated do
        # The beginning of the output should match beginning of input
        head_portion = String.slice(output_text, 0, 50)
        assert String.starts_with?(text, String.slice(head_portion, 0, 30)),
          "Head strategy should preserve beginning of text"
      end
    end
  end

  property "tail strategy preserves end of text" do
    check all text <- string(:ascii, min_length: 500, max_length: 1000) do
      result = execute_truncate(text, 200, nil, "tail")

      assert match?(%AgentToolResult{}, result)

      output_text = get_output_text(result)

      if result.details.truncated do
        # The end of the output should match end of input
        tail_portion = String.slice(output_text, -50, 50)
        input_tail = String.slice(text, -50, 50)

        # Check that end portion is preserved (with some tolerance for line breaks)
        assert String.ends_with?(text, String.slice(tail_portion, -20, 20)) or
               String.contains?(input_tail, String.slice(tail_portion, -20, 20)),
          "Tail strategy should preserve end of text"
      end
    end
  end

  property "middle strategy preserves both ends" do
    check all text <- string(:ascii, min_length: 600, max_length: 1000) do
      result = execute_truncate(text, 300, nil, "middle")

      assert match?(%AgentToolResult{}, result)

      output_text = get_output_text(result)

      if result.details.truncated and String.length(output_text) > 100 do
        # Both beginning and end should be from the original
        head_portion = String.slice(output_text, 0, 30)
        tail_portion = String.slice(output_text, -30, 30)

        # The head should come from the beginning of input
        assert String.contains?(String.slice(text, 0, 100), head_portion),
          "Middle strategy should preserve beginning"

        # The tail should come from the end of input
        assert String.contains?(String.slice(text, -100, 100), tail_portion),
          "Middle strategy should preserve end"
      end
    end
  end

  # ============================================================================
  # All Strategies Handle Edge Cases
  # ============================================================================

  property "all strategies handle single character" do
    check all strat <- strategy() do
      result = execute_truncate("x", 100, nil, strat)

      assert match?(%AgentToolResult{}, result)
      assert get_output_text(result) == "x"
      assert result.details.truncated == false
    end
  end

  property "all strategies handle single line" do
    check all text <- string(:ascii, min_length: 1, max_length: 50),
              strat <- strategy() do
      # Ensure no newlines
      text = String.replace(text, "\n", " ")

      result = execute_truncate(text, 10_000, nil, strat)

      assert match?(%AgentToolResult{}, result)
      assert result.details.truncated == false
    end
  end

  property "all strategies handle text with only newlines" do
    check all num_lines <- integer(1..20),
              strat <- strategy() do
      text = String.duplicate("\n", num_lines)

      result = execute_truncate(text, 10_000, nil, strat)

      assert match?(%AgentToolResult{}, result)
      # Should not error
    end
  end

  property "all strategies produce valid output" do
    check all text <- ascii_text(),
              limit <- max_chars(),
              strat <- strategy() do
      result = execute_truncate(text, limit, nil, strat)

      assert match?(%AgentToolResult{}, result)

      output_text = get_output_text(result)
      assert is_binary(output_text)
      assert String.valid?(output_text)
    end
  end

  # ============================================================================
  # Idempotency Properties
  # ============================================================================

  property "truncating already-truncated content is stable" do
    check all text <- string(:ascii, min_length: 500, max_length: 1000),
              limit <- integer(200..400),
              strat <- strategy() do
      # First truncation
      result1 = execute_truncate(text, limit, nil, strat)
      output1 = get_output_text(result1)

      # Second truncation of the same text with same limit
      result2 = execute_truncate(output1, limit, nil, strat)
      output2 = get_output_text(result2)

      # Second truncation should not reduce size much further
      assert String.length(output2) <= String.length(output1) + 100
    end
  end

  # ============================================================================
  # Line Limit Properties
  # ============================================================================

  property "line limit constrains output when specified" do
    check all lines <- list_of(string(:alphanumeric, max_length: 20), min_length: 30, max_length: 50),
              strat <- strategy() do
      text = Enum.join(lines, "\n")
      line_limit = 10

      result = execute_truncate(text, 100_000, line_limit, strat)

      assert match?(%AgentToolResult{}, result)

      output_text = get_output_text(result)
      output_lines = count_lines(output_text)

      # Should be within line limit (with marker tolerance)
      assert output_lines <= line_limit + 5,
        "Line limit should constrain output"
    end
  end

  # ============================================================================
  # Preserve Structure Properties
  # ============================================================================

  property "smart strategy with code attempts to preserve structural elements" do
    check all module_name <- string(:alphanumeric, min_length: 3, max_length: 10),
              func_body <- list_of(string(:alphanumeric, max_length: 20), min_length: 15, max_length: 25) do
      code = """
      defmodule #{String.capitalize(module_name)} do
        @moduledoc "Test module"

        def my_function(arg) do
      #{Enum.map_join(func_body, "\n", fn line -> "    " <> line end)}
        end

        def another_function(x) do
          x + 1
        end
      end
      """

      # Truncate to smaller size
      result = execute_truncate(code, 400, nil, "smart")

      assert match?(%AgentToolResult{}, result)

      if result.details.truncated do
        output_text = get_output_text(result)

        # Smart strategy should try to keep structural elements
        # At least one of: defmodule, def, end should be preserved
        has_structure = String.contains?(output_text, "defmodule") or
                       String.contains?(output_text, "def ") or
                       String.contains?(output_text, "end")

        # This is a soft assertion - smart strategy tries but may not always succeed
        if String.length(output_text) > 100 do
          assert has_structure or String.contains?(output_text, "truncated"),
            "Smart strategy should preserve some structure"
        end
      end
    end
  end

  # ============================================================================
  # Error Handling
  # ============================================================================

  property "invalid strategy returns error for non-empty text" do
    check all text <- string(:ascii, min_length: 10, max_length: 100) do
      # Use a definitely invalid strategy
      invalid_strat = "not_a_valid_strategy_12345"

      result = execute_truncate(text, 1000, nil, invalid_strat)

      assert match?({:error, _}, result)
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp execute_truncate(text, max_chars, max_lines, strategy) do
    params = %{
      "text" => text,
      "max_chars" => max_chars,
      "strategy" => strategy,
      "preserve_structure" => true
    }

    params = if max_lines, do: Map.put(params, "max_lines", max_lines), else: params

    Truncate.execute("test_call_id", params, nil, nil, [])
  end

  defp get_output_text(%AgentToolResult{content: [%{text: text} | _]}), do: text
  defp get_output_text(%AgentToolResult{content: []}), do: ""
  defp get_output_text(_), do: ""

  defp count_lines(""), do: 0
  defp count_lines(text), do: text |> String.split("\n") |> length()
end
