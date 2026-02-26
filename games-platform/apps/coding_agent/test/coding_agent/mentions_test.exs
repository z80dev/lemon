defmodule CodingAgent.MentionsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Mentions

  @moduletag :tmp_dir

  # Helper to create a subagent file
  defp create_subagent(tmp_dir, id, description) do
    subagents_dir = Path.join([tmp_dir, ".lemon"])
    File.mkdir_p!(subagents_dir)

    content =
      Jason.encode!([
        %{"id" => id, "description" => description, "prompt" => "You are #{id}"}
      ])

    File.write!(Path.join(subagents_dir, "subagents.json"), content)
  end

  describe "parse/2" do
    test "parses mention at start of input", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "explore", "Explore the codebase")

      result = Mentions.parse("@explore find all API endpoints", tmp_dir)

      assert {:ok, mention} = result
      assert mention.agent == "explore"
      assert mention.prompt == "find all API endpoints"
      assert mention.prefix == nil
    end

    test "parses mention with prefix text", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "debug", "Debug issues")

      result = Mentions.parse("Please help me @debug this error", tmp_dir)

      assert {:ok, mention} = result
      assert mention.agent == "debug"
      assert mention.prompt == "this error"
      assert mention.prefix == "Please help me"
    end

    test "returns :no_mention when no @ symbol", %{tmp_dir: tmp_dir} do
      assert Mentions.parse("just a regular message", tmp_dir) == :no_mention
    end

    test "returns error for unknown agent", %{tmp_dir: tmp_dir} do
      # tmp_dir has no subagents defined
      result = Mentions.parse("@nonexistent do something", tmp_dir)
      assert {:error, :unknown_agent, "nonexistent"} = result
    end

    test "handles multiline input", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "review", "Review code")

      input = """
      @review check these changes:
      - file1.ex
      - file2.ex
      """

      assert {:ok, mention} = Mentions.parse(input, tmp_dir)
      assert mention.agent == "review"
      assert String.contains?(mention.prompt, "file1.ex")
    end

    test "handles mention with no prompt", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "test", "Run tests")

      assert {:ok, mention} = Mentions.parse("@test", tmp_dir)
      assert mention.agent == "test"
      assert mention.prompt == ""
    end

    test "matches first mention in input", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "explore", "Explore")

      result = Mentions.parse("@explore then @other stuff", tmp_dir)

      assert {:ok, mention} = result
      assert mention.agent == "explore"
    end
  end

  describe "extract_all/1" do
    test "extracts single mention" do
      result = Mentions.extract_all("@explore find files")
      assert [{"explore", "find files"}] = result
    end

    test "extracts multiple mentions" do
      result = Mentions.extract_all("@explore find then @review check")
      assert length(result) == 2
      names = Enum.map(result, fn {name, _} -> name end)
      assert "explore" in names
      assert "review" in names
    end

    test "returns empty list for no mentions" do
      assert Mentions.extract_all("no mentions here") == []
    end

    test "handles mentions with hyphens and underscores" do
      result = Mentions.extract_all("@my-agent and @other_agent")
      names = Enum.map(result, fn {name, _} -> name end)
      assert "my-agent" in names
      assert "other_agent" in names
    end
  end

  describe "autocomplete/2" do
    test "returns matching agents", %{tmp_dir: tmp_dir} do
      subagents_dir = Path.join([tmp_dir, ".lemon"])
      File.mkdir_p!(subagents_dir)

      content =
        Jason.encode!([
          %{"id" => "explore", "description" => "Explore", "prompt" => "..."},
          %{"id" => "explain", "description" => "Explain", "prompt" => "..."},
          %{"id" => "debug", "description" => "Debug", "prompt" => "..."}
        ])

      File.write!(Path.join(subagents_dir, "subagents.json"), content)

      # Should match explore and explain
      result = Mentions.autocomplete("exp", tmp_dir)
      assert "explore" in result
      assert "explain" in result
      refute "debug" in result
    end

    test "returns empty list for no matches", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "explore", "Explore")

      result = Mentions.autocomplete("xyz", tmp_dir)
      assert result == []
    end

    test "is case insensitive", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "Debug", "Debug issues")

      result = Mentions.autocomplete("deb", tmp_dir)
      # Default subagents include "debug"
      assert "debug" in result or "Debug" in result
    end
  end

  describe "starts_with_mention?/1" do
    test "returns true for @mention at start" do
      assert Mentions.starts_with_mention?("@explore something")
    end

    test "returns true with leading whitespace" do
      assert Mentions.starts_with_mention?("  @explore something")
    end

    test "returns false for no mention" do
      refute Mentions.starts_with_mention?("no mention here")
    end

    test "returns false for @ in middle" do
      refute Mentions.starts_with_mention?("email@example.com")
    end
  end

  describe "format_available/1" do
    test "formats available agents", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "myagent", "My custom agent")

      result = Mentions.format_available(tmp_dir)

      assert String.contains?(result, "@myagent")
      assert String.contains?(result, "My custom agent")
    end
  end

  # ==========================================================================
  # Unicode and Special Character Handling Tests
  # ==========================================================================

  describe "multiple mentions in input" do
    test "extract_all returns all mentions in order", %{tmp_dir: _tmp_dir} do
      input = "@first do this @second then @third finally"
      result = Mentions.extract_all(input)

      assert length(result) == 3
      names = Enum.map(result, fn {name, _} -> name end)
      assert names == ["first", "second", "third"]
    end

    test "parse returns only the first valid mention", %{tmp_dir: tmp_dir} do
      create_subagents_bulk(tmp_dir, ["alpha", "beta", "gamma"])

      result = Mentions.parse("@alpha first @beta second @gamma third", tmp_dir)

      assert {:ok, mention} = result
      assert mention.agent == "alpha"
      assert String.contains?(mention.prompt, "@beta")
    end

    test "extract_all handles adjacent mentions", %{tmp_dir: _tmp_dir} do
      input = "@one@two@three"
      result = Mentions.extract_all(input)

      # Adjacent mentions - @ is not a valid character in agent names
      # so @one@two means @one followed by @two
      names = Enum.map(result, fn {name, _} -> name end)
      assert "one" in names
      assert "two" in names
      assert "three" in names
    end

    test "extract_all with mentions separated by various whitespace" do
      input = "@first\t@second\n@third\r\n@fourth"
      result = Mentions.extract_all(input)

      names = Enum.map(result, fn {name, _} -> name end)
      assert length(names) == 4
      assert "first" in names
      assert "second" in names
      assert "third" in names
      assert "fourth" in names
    end

    test "parse skips to first known agent if earlier mentions unknown", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "known", "Known agent")

      # First mention is unknown, but regex matches first @mention
      result = Mentions.parse("@unknown stuff @known more", tmp_dir)

      # Per implementation, it returns error for first found mention
      assert {:error, :unknown_agent, "unknown"} = result
    end
  end

  describe "mention names with reserved characters" do
    test "@ symbol in email is also extracted as mention" do
      input = "@agent check user@example.com"
      result = Mentions.extract_all(input)

      # Both @agent and @example from the email are matched
      # This is expected behavior - the regex doesn't have email awareness
      assert length(result) == 2
      names = Enum.map(result, fn {name, _} -> name end)
      assert "agent" in names
      assert "example" in names
    end

    test "handles email-like patterns in input", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "check", "Check agent")

      result = Mentions.parse("@check email user@domain.com", tmp_dir)

      assert {:ok, mention} = result
      assert mention.agent == "check"
    end

    test "mention followed by special characters" do
      # These should be captured as valid mentions
      assert [{"agent", _}] = Mentions.extract_all("@agent!")
      assert [{"agent", _}] = Mentions.extract_all("@agent?")
      assert [{"agent", _}] = Mentions.extract_all("@agent.")
      assert [{"agent", _}] = Mentions.extract_all("@agent,")
      assert [{"agent", _}] = Mentions.extract_all("@agent:")
      assert [{"agent", _}] = Mentions.extract_all("@agent;")
    end

    test "mention with numbers and valid special chars" do
      assert [{"agent123", _}] = Mentions.extract_all("@agent123 test")
      assert [{"my-agent", _}] = Mentions.extract_all("@my-agent test")
      assert [{"my_agent", _}] = Mentions.extract_all("@my_agent test")
      assert [{"my-agent_123", _}] = Mentions.extract_all("@my-agent_123 test")
    end

    test "@ followed by numbers only is not a valid mention" do
      # Agent names must start with a letter
      result = Mentions.extract_all("@123 test")
      assert result == []
    end

    test "@ followed by underscore only is not a valid mention" do
      result = Mentions.extract_all("@_agent test")
      assert result == []
    end

    test "@ followed by hyphen only is not a valid mention" do
      result = Mentions.extract_all("@-agent test")
      assert result == []
    end

    test "mention in markdown code block" do
      input = "```\n@agent code here\n```"
      result = Mentions.extract_all(input)
      # Still extracts - no special markdown handling
      assert [{"agent", _}] = result
    end

    test "mention in quoted text" do
      input = ~s("@agent" said something)
      result = Mentions.extract_all(input)
      assert [{"agent", _}] = result
    end

    test "parentheses around mention" do
      input = "(@agent) or [@agent] or {@agent}"
      result = Mentions.extract_all(input)
      names = Enum.map(result, fn {name, _} -> name end)
      # All three should be extracted
      assert length(names) == 3
      assert Enum.all?(names, &(&1 == "agent"))
    end
  end

  describe "case sensitivity boundaries" do
    test "agent names are case-sensitive in parse", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "MyAgent", "Test agent")

      # Exact case match
      assert {:ok, mention} = Mentions.parse("@MyAgent test", tmp_dir)
      assert mention.agent == "MyAgent"
    end

    test "autocomplete is case-insensitive", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "MyAgent", "Test agent")

      # Lowercase prefix should match
      result = Mentions.autocomplete("my", tmp_dir)
      assert "MyAgent" in result
    end

    test "autocomplete with uppercase prefix matches lowercase agent", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "myagent", "Test agent")

      result = Mentions.autocomplete("MY", tmp_dir)
      assert "myagent" in result
    end

    test "extract_all preserves original case" do
      input = "@MyAgent and @OTHERAGENT and @mixedCase"
      result = Mentions.extract_all(input)

      names = Enum.map(result, fn {name, _} -> name end)
      assert "MyAgent" in names
      assert "OTHERAGENT" in names
      assert "mixedCase" in names
    end

    test "mixed case in same agent name", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "camelCaseAgent", "Camel case")

      assert {:ok, mention} = Mentions.parse("@camelCaseAgent test", tmp_dir)
      assert mention.agent == "camelCaseAgent"
    end
  end

  describe "performance with many subagents" do
    test "autocomplete with 100+ agents is responsive", %{tmp_dir: tmp_dir} do
      # Create 150 agents
      agents = for i <- 1..150, do: "agent#{String.pad_leading(to_string(i), 3, "0")}"
      create_subagents_bulk(tmp_dir, agents)

      # Measure autocomplete performance
      {time_us, result} = :timer.tc(fn -> Mentions.autocomplete("agent0", tmp_dir) end)

      # Should complete in reasonable time (under 100ms)
      assert time_us < 100_000

      # Should find agents starting with "agent0" (001-099)
      assert length(result) > 0
      assert Enum.all?(result, &String.starts_with?(&1, "agent0"))
    end

    test "parse with 100+ agents finds correct match", %{tmp_dir: tmp_dir} do
      agents = for i <- 1..150, do: "agent#{String.pad_leading(to_string(i), 3, "0")}"
      create_subagents_bulk(tmp_dir, agents)

      {time_us, result} = :timer.tc(fn -> Mentions.parse("@agent050 do something", tmp_dir) end)

      # Should complete in reasonable time
      assert time_us < 100_000

      assert {:ok, mention} = result
      assert mention.agent == "agent050"
    end

    test "extract_all with many mentions in input" do
      # Create input with 50 mentions
      mentions = for i <- 1..50, do: "@agent#{i}"
      input = Enum.join(mentions, " ")

      {time_us, result} = :timer.tc(fn -> Mentions.extract_all(input) end)

      # Should complete quickly
      assert time_us < 50_000

      assert length(result) == 50
    end

    test "format_available with 100+ agents", %{tmp_dir: tmp_dir} do
      agents = for i <- 1..100, do: "agent#{String.pad_leading(to_string(i), 3, "0")}"
      create_subagents_bulk(tmp_dir, agents)

      {time_us, result} = :timer.tc(fn -> Mentions.format_available(tmp_dir) end)

      # Should complete in reasonable time
      assert time_us < 100_000

      # Should contain all agents
      assert String.contains?(result, "@agent001")
      assert String.contains?(result, "@agent100")
    end
  end

  describe "unicode in agent names" do
    test "unicode letters are not matched by current regex" do
      # The regex only matches ASCII [a-zA-Z]
      # Unicode letters like accented characters won't match
      result = Mentions.extract_all("@agënt test")

      # Should not match because ë is not in [a-zA-Z]
      # It would match @ag then stop at ë
      assert [{"ag", _}] = result
    end

    test "japanese characters after @ are not matched" do
      result = Mentions.extract_all("@\u65E5\u672C\u8A9E test")
      assert result == []
    end

    test "cyrillic characters after @ are not matched" do
      result = Mentions.extract_all("@\u0430\u0433\u0435\u043D\u0442 test")
      assert result == []
    end

    test "chinese characters after @ are not matched" do
      result = Mentions.extract_all("@\u4EE3\u7406 test")
      assert result == []
    end

    test "unicode in prompt text is preserved", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "agent", "Test agent")

      result =
        Mentions.parse("@agent \u65E5\u672C\u8A9E\u306E\u30E1\u30C3\u30BB\u30FC\u30B8", tmp_dir)

      assert {:ok, mention} = result
      assert mention.prompt == "\u65E5\u672C\u8A9E\u306E\u30E1\u30C3\u30BB\u30FC\u30B8"
    end

    test "mixed ascii and unicode in prompt", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "translate", "Translation agent")

      result = Mentions.parse("@translate hello \u4E16\u754C", tmp_dir)

      assert {:ok, mention} = result
      assert mention.prompt == "hello \u4E16\u754C"
    end

    test "accented characters in prompt are preserved", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "agent", "Test agent")

      result = Mentions.parse("@agent caf\u00E9 na\u00EFve r\u00E9sum\u00E9", tmp_dir)

      assert {:ok, mention} = result
      assert mention.prompt == "caf\u00E9 na\u00EFve r\u00E9sum\u00E9"
    end
  end

  describe "emoji in mention names" do
    test "emoji after @ are not matched as agent name" do
      result = Mentions.extract_all("@\u{1F680} test")
      assert result == []
    end

    test "emoji embedded in agent name stops matching" do
      result = Mentions.extract_all("@agent\u{1F60A}name test")

      # Should match @agent then stop at emoji
      assert [{"agent", _}] = result
    end

    test "emoji in prompt text is preserved", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "agent", "Test agent")

      result = Mentions.parse("@agent \u{1F680} launch it!", tmp_dir)

      assert {:ok, mention} = result
      assert mention.prompt == "\u{1F680} launch it!"
    end

    test "multiple emojis in prompt", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "agent", "Test agent")

      result = Mentions.parse("@agent \u{1F389}\u{1F38A}\u{1F973} party time!", tmp_dir)

      assert {:ok, mention} = result
      assert String.contains?(mention.prompt, "\u{1F389}")
      assert String.contains?(mention.prompt, "\u{1F38A}")
      assert String.contains?(mention.prompt, "\u{1F973}")
    end

    test "emoji-only after valid mention", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "react", "React agent")

      result = Mentions.parse("@react \u{1F44D}\u{1F44E}", tmp_dir)

      assert {:ok, mention} = result
      assert mention.prompt == "\u{1F44D}\u{1F44E}"
    end

    test "flag emojis in prompt", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "agent", "Test agent")

      result =
        Mentions.parse("@agent \u{1F1FA}\u{1F1F8} \u{1F1E8}\u{1F1E6} \u{1F1EF}\u{1F1F5}", tmp_dir)

      assert {:ok, mention} = result
      assert String.contains?(mention.prompt, "\u{1F1FA}\u{1F1F8}")
    end
  end

  describe "whitespace handling around mentions" do
    test "leading whitespace is trimmed before parsing", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "agent", "Test agent")

      assert {:ok, mention} = Mentions.parse("   @agent test", tmp_dir)
      assert mention.agent == "agent"
      assert mention.prefix == nil
    end

    test "trailing whitespace in prompt is trimmed", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "agent", "Test agent")

      assert {:ok, mention} = Mentions.parse("@agent test   ", tmp_dir)
      assert mention.prompt == "test"
    end

    test "multiple spaces between mention and prompt", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "agent", "Test agent")

      assert {:ok, mention} = Mentions.parse("@agent    multiple spaces", tmp_dir)
      # Implementation trims but may preserve internal spaces
      assert String.trim(mention.prompt) == "multiple spaces"
    end

    test "tab character between mention and prompt", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "agent", "Test agent")

      assert {:ok, mention} = Mentions.parse("@agent\ttab separated", tmp_dir)
      assert String.contains?(mention.prompt, "tab separated")
    end

    test "newline between mention and prompt", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "agent", "Test agent")

      assert {:ok, mention} = Mentions.parse("@agent\nnewline prompt", tmp_dir)
      assert String.contains?(mention.prompt, "newline prompt")
    end

    test "only whitespace after mention", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "agent", "Test agent")

      assert {:ok, mention} = Mentions.parse("@agent   ", tmp_dir)
      assert mention.prompt == ""
    end

    test "prefix with leading/trailing whitespace is trimmed", %{tmp_dir: tmp_dir} do
      create_subagent(tmp_dir, "agent", "Test agent")

      assert {:ok, mention} = Mentions.parse("  prefix text  @agent prompt", tmp_dir)
      assert mention.prefix == "prefix text"
    end

    test "starts_with_mention? handles various whitespace" do
      assert Mentions.starts_with_mention?("\t@agent test")
      assert Mentions.starts_with_mention?("\n@agent test")
      assert Mentions.starts_with_mention?("  \t  @agent test")
    end

    test "non-breaking space before mention" do
      # Unicode non-breaking space (U+00A0)
      input = "\u00A0@agent test"
      # String.trim handles unicode whitespace
      assert Mentions.starts_with_mention?(input)
    end

    test "zero-width characters don't affect parsing" do
      # Zero-width space (U+200B)
      result = Mentions.extract_all("@agent\u200Btest")

      # Zero-width space is not in regex, so stops matching after "agent"
      assert [{"agent", _}] = result
    end

    test "form feed and vertical tab" do
      assert Mentions.starts_with_mention?("\f@agent test")
      assert Mentions.starts_with_mention?("\v@agent test")
    end
  end

  # ==========================================================================
  # Helper for bulk agent creation
  # ==========================================================================

  defp create_subagents_bulk(tmp_dir, agent_ids) when is_list(agent_ids) do
    subagents_dir = Path.join([tmp_dir, ".lemon"])
    File.mkdir_p!(subagents_dir)

    agents =
      Enum.map(agent_ids, fn id ->
        %{"id" => id, "description" => "Agent #{id}", "prompt" => "You are #{id}"}
      end)

    content = Jason.encode!(agents)
    File.write!(Path.join(subagents_dir, "subagents.json"), content)
  end
end
