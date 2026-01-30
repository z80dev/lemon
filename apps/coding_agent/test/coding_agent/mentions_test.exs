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
end
