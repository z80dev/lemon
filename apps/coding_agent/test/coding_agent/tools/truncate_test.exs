defmodule CodingAgent.Tools.TruncateTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Truncate
  alias AgentCore.Types.AgentToolResult
  alias Ai.Types.TextContent

  describe "tool/1" do
    test "returns an AgentTool struct with correct properties" do
      tool = Truncate.tool()

      assert tool.name == "truncate"
      assert tool.label == "Truncate Text"
      assert tool.description =~ "Truncate long text"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["text"]
      assert is_function(tool.execute, 4)
    end

    test "has strategy enum in parameters" do
      tool = Truncate.tool()
      strategy_param = tool.parameters["properties"]["strategy"]

      assert strategy_param["type"] == "string"
      assert strategy_param["enum"] == ["head", "tail", "middle", "smart"]
    end
  end

  describe "execute/5 - empty text" do
    test "handles empty text" do
      result = Truncate.execute("call_1", %{"text" => ""}, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: ""}], details: details} = result
      assert details.truncated == false
      assert details.original_chars == 0
      assert details.truncated_chars == 0
    end
  end

  describe "execute/5 - no truncation needed" do
    test "returns text unchanged when under limit" do
      text = "Hello, World!"
      result = Truncate.execute("call_1", %{"text" => text, "max_chars" => 100}, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: ^text}], details: details} = result
      assert details.truncated == false
      assert details.original_chars == 13
      assert details.truncated_chars == 13
    end

    test "returns text unchanged when exactly at limit" do
      text = "12345"
      result = Truncate.execute("call_1", %{"text" => text, "max_chars" => 5}, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: ^text}], details: details} = result
      assert details.truncated == false
    end
  end

  describe "execute/5 - head strategy" do
    test "keeps beginning and truncates end" do
      text = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10"
      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_chars" => 60,
        "strategy" => "head"
      }, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: truncated}], details: details} = result
      assert details.truncated == true
      assert String.starts_with?(truncated, "Line 1")
      assert truncated =~ "truncated"
      refute truncated =~ "Line 10"
    end

    test "handles single line text" do
      text = String.duplicate("a", 100)
      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_chars" => 60,
        "strategy" => "head"
      }, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: truncated}], details: details} = result
      assert details.truncated == true
      assert String.length(truncated) <= 60
    end
  end

  describe "execute/5 - tail strategy" do
    test "keeps end and truncates beginning" do
      text = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5\nLine 6\nLine 7\nLine 8\nLine 9\nLine 10"
      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_chars" => 60,
        "strategy" => "tail"
      }, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: truncated}], details: details} = result
      assert details.truncated == true
      assert truncated =~ "truncated"
      assert truncated =~ "Line 10"
      refute String.starts_with?(truncated, "Line 1")
    end
  end

  describe "execute/5 - middle strategy" do
    test "keeps beginning and end, truncates middle" do
      text = "START\n" <> String.duplicate("middle line\n", 20) <> "END"
      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_chars" => 50,
        "strategy" => "middle"
      }, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: truncated}], details: details} = result
      assert details.truncated == true
      assert truncated =~ "truncated"
      assert truncated =~ "START"
      assert truncated =~ "END"
    end
  end

  describe "execute/5 - smart strategy" do
    test "preserves function definitions in Elixir code" do
      text = """
      defmodule MyModule do
        @moduledoc "A test module"

        def function_one do
          # lots of implementation
          #{String.duplicate("  some_code()\n", 50)}
        end

        def function_two do
          :ok
        end
      end
      """

      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_chars" => 200,
        "strategy" => "smart"
      }, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: truncated}], details: details} = result
      assert details.truncated == true
      # Smart strategy should try to preserve structure
      assert truncated =~ "defmodule MyModule"
    end

    test "preserves imports and function signatures" do
      text = """
      import Something
      alias Another.Thing

      def first_function(arg) do
        #{String.duplicate("  # implementation\n", 100)}
      end

      def second_function(arg) do
        :ok
      end
      """

      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_chars" => 150,
        "strategy" => "smart",
        "preserve_structure" => true
      }, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: truncated}], details: details} = result
      assert details.truncated == true
      # Should preserve structural elements
      assert truncated =~ "import Something" or truncated =~ "def "
    end

    test "falls back to middle truncation when preserve_structure is false" do
      text = "START\n" <> String.duplicate("x", 200) <> "\nEND"

      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_chars" => 50,
        "strategy" => "smart",
        "preserve_structure" => false
      }, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: truncated}], details: details} = result
      assert details.truncated == true
      assert truncated =~ "truncated"
    end
  end

  describe "execute/5 - max_lines parameter" do
    test "truncates by line count with head strategy" do
      text = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"

      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_lines" => 2,
        "strategy" => "head"
      }, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: truncated}], details: details} = result
      assert details.truncated == true
      assert truncated =~ "Line 1"
      assert truncated =~ "Line 2"
      refute truncated =~ "Line 5"
    end

    test "truncates by line count with tail strategy" do
      text = "Line 1\nLine 2\nLine 3\nLine 4\nLine 5"

      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_lines" => 2,
        "strategy" => "tail"
      }, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: truncated}], details: details} = result
      assert details.truncated == true
      assert truncated =~ "Line 4" or truncated =~ "Line 5"
    end

    test "applies both max_lines and max_chars" do
      text = String.duplicate("A very long line with lots of text\n", 10)

      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_lines" => 3,
        "max_chars" => 50,
        "strategy" => "head"
      }, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: truncated}], details: details} = result
      assert details.truncated == true
      assert String.length(truncated) <= 50
    end
  end

  describe "execute/5 - metadata" do
    test "includes comprehensive metadata" do
      text = String.duplicate("Hello\n", 100)

      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_chars" => 100,
        "strategy" => "middle"
      }, nil, nil, [])

      assert %AgentToolResult{details: details} = result
      assert is_integer(details.original_chars)
      assert is_integer(details.original_lines)
      assert is_integer(details.truncated_chars)
      assert is_integer(details.truncated_lines)
      assert is_boolean(details.truncated)
      assert details.strategy == "middle"
      assert is_binary(details.summary)
    end

    test "summary describes truncation" do
      text = String.duplicate("x", 200)

      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_chars" => 50,
        "strategy" => "head"
      }, nil, nil, [])

      assert %AgentToolResult{details: details} = result
      assert details.summary =~ "Truncated from"
      assert details.summary =~ "head strategy"
    end

    test "summary indicates no truncation when not needed" do
      result = Truncate.execute("call_1", %{
        "text" => "short",
        "max_chars" => 100
      }, nil, nil, [])

      assert %AgentToolResult{details: details} = result
      assert details.summary =~ "No truncation needed"
    end
  end

  describe "execute/5 - error handling" do
    test "returns error for invalid strategy" do
      result = Truncate.execute("call_1", %{
        "text" => "hello",
        "strategy" => "invalid"
      }, nil, nil, [])

      assert {:error, msg} = result
      assert msg =~ "Invalid strategy"
      assert msg =~ "invalid"
    end
  end

  describe "execute/5 - truncation markers" do
    test "includes character count in marker" do
      text = String.duplicate("x", 200)

      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_chars" => 50,
        "strategy" => "head"
      }, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: truncated}]} = result
      assert truncated =~ "chars truncated"
    end

    test "includes line count in marker when truncating by lines" do
      text = String.duplicate("line\n", 100)

      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_lines" => 5,
        "max_chars" => 100_000,  # High limit so only lines matter
        "strategy" => "head"
      }, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: truncated}]} = result
      assert truncated =~ "lines truncated"
    end
  end

  describe "tool integration" do
    test "tool can be used via execute function" do
      tool = Truncate.tool()
      text = String.duplicate("test ", 100)

      result = tool.execute.("call_1", %{
        "text" => text,
        "max_chars" => 50
      }, nil, nil)

      assert %AgentToolResult{details: details} = result
      assert details.truncated == true
    end
  end

  describe "execute/5 - default values" do
    test "uses default max_chars of 50000" do
      # Text under 50000 chars should not be truncated
      text = String.duplicate("a", 1000)

      result = Truncate.execute("call_1", %{"text" => text}, nil, nil, [])

      assert %AgentToolResult{details: details} = result
      assert details.truncated == false
    end

    test "uses smart strategy by default" do
      text = String.duplicate("a", 100)

      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_chars" => 50
      }, nil, nil, [])

      assert %AgentToolResult{details: details} = result
      assert details.strategy == "smart"
    end
  end

  describe "execute/5 - unicode handling" do
    test "correctly handles unicode characters" do
      # Each emoji is multiple bytes but one grapheme
      text = String.duplicate("\u{1F600}", 100)  # 100 smiling face emojis

      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_chars" => 50,
        "strategy" => "head"
      }, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: _truncated}], details: details} = result
      assert details.truncated == true
      # String.length counts graphemes, not bytes
      assert details.original_chars == 100
    end

    test "handles mixed ascii and unicode" do
      # Create longer mixed text to ensure truncation even after marker
      text = String.duplicate("Hello \u{1F600} World \u{1F600} ", 10) <> "END"

      result = Truncate.execute("call_1", %{
        "text" => text,
        "max_chars" => 60,
        "strategy" => "head"
      }, nil, nil, [])

      assert %AgentToolResult{content: [%TextContent{text: _truncated}], details: details} = result
      assert details.truncated == true
    end
  end
end
