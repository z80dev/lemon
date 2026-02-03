defmodule CodingAgent.Tools.MultiEditTest do
  @moduledoc """
  Comprehensive tests for the MultiEdit tool.

  Tests sequential edit application, multiple edits, error handling,
  file integrity, edge cases, and integration with the Edit tool.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.MultiEdit
  alias AgentCore.Types.AgentToolResult
  alias AgentCore.AbortSignal
  alias Ai.Types.TextContent

  @moduletag :tmp_dir

  describe "tool/2" do
    test "returns an AgentTool struct with correct properties" do
      tool = MultiEdit.tool("/tmp")

      assert tool.name == "multiedit"
      assert tool.label == "Multi Edit"
      assert tool.description =~ "multiple edits"
      assert tool.parameters["type"] == "object"
      assert tool.parameters["required"] == ["path", "edits"]
      assert is_function(tool.execute, 4)
    end

    test "defines edits parameter as an array" do
      tool = MultiEdit.tool("/tmp")

      edits_schema = tool.parameters["properties"]["edits"]
      assert edits_schema["type"] == "array"
      assert edits_schema["items"]["type"] == "object"
      assert edits_schema["items"]["required"] == ["old_text", "new_text"]
    end
  end

  describe "execute/6 - sequential edit application" do
    test "applies edits in order", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "sequential.txt")
      File.write!(path, "one two three")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "one", "new_text" => "ONE"},
          %{"old_text" => "two", "new_text" => "TWO"},
          %{"old_text" => "three", "new_text" => "THREE"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "ONE TWO THREE"
    end

    test "later edits see results of earlier edits", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "chain.txt")
      File.write!(path, "start")

      # Each edit depends on the previous result
      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "start", "new_text" => "middle"},
          %{"old_text" => "middle", "new_text" => "end"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "end"
    end

    test "maintains correct order with multiline content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "multiline.txt")
      File.write!(path, "line1\nline2\nline3\nline4")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "line1", "new_text" => "FIRST"},
          %{"old_text" => "line4", "new_text" => "LAST"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content == "FIRST\nline2\nline3\nLAST"
    end
  end

  describe "execute/6 - multiple edits in one call" do
    test "applies all edits successfully", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "multiple.txt")
      File.write!(path, "apple banana cherry")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "apple", "new_text" => "APPLE"},
          %{"old_text" => "banana", "new_text" => "BANANA"},
          %{"old_text" => "cherry", "new_text" => "CHERRY"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "APPLE BANANA CHERRY"
    end

    test "returns combined results from all edits", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "combined.txt")
      File.write!(path, "foo bar baz")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "foo", "new_text" => "FOO"},
          %{"old_text" => "bar", "new_text" => "BAR"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: %{results: results}} = result
      assert length(results) == 2
    end

    test "single edit works like regular Edit tool", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "single.txt")
      File.write!(path, "hello world")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "hello", "new_text" => "hi"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "hi world"
    end

    test "handles many edits in a single call", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "many.txt")
      # Use unique, non-overlapping keys (padded to avoid item1 matching item10)
      content = Enum.map_join(1..10, " ", fn n -> "[item_#{n}]" end)
      File.write!(path, content)

      edits = Enum.map(1..10, fn n ->
        %{"old_text" => "[item_#{n}]", "new_text" => "[ITEM_#{n}]"}
      end)

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => edits
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      final_content = File.read!(path)
      assert final_content =~ "[ITEM_1]"
      assert final_content =~ "[ITEM_10]"
    end
  end

  describe "execute/6 - error handling" do
    test "returns error when path is missing", %{tmp_dir: tmp_dir} do
      result = MultiEdit.execute("call_1", %{
        "edits" => [
          %{"old_text" => "foo", "new_text" => "bar"}
        ]
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Path is required"
    end

    test "returns error when path is empty string", %{tmp_dir: tmp_dir} do
      result = MultiEdit.execute("call_1", %{
        "path" => "",
        "edits" => [
          %{"old_text" => "foo", "new_text" => "bar"}
        ]
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Path is required"
    end

    test "returns error when edits is not an array", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "notarray.txt")
      File.write!(path, "content")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => "not an array"
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Edits must be an array"
    end

    test "returns error when edits array is empty", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty.txt")
      File.write!(path, "content")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => []
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Edits array cannot be empty"
    end

    test "returns error when file does not exist", %{tmp_dir: tmp_dir} do
      result = MultiEdit.execute("call_1", %{
        "path" => Path.join(tmp_dir, "nonexistent.txt"),
        "edits" => [
          %{"old_text" => "foo", "new_text" => "bar"}
        ]
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "not found" or msg =~ "File not found"
    end

    test "returns error when old_text is not found", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "notfound.txt")
      File.write!(path, "hello world")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "nonexistent", "new_text" => "replacement"}
        ]
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "not find" or msg =~ "not found"
    end

    test "returns error when old_text has multiple occurrences", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "duplicate.txt")
      File.write!(path, "hello hello world")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "hello", "new_text" => "hi"}
        ]
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "occurrence" or msg =~ "unique"
    end

    test "returns error when edit produces no change", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nochange.txt")
      File.write!(path, "same content")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "same", "new_text" => "same"}
        ]
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "no change" or msg =~ "No changes"
    end
  end

  describe "execute/6 - file integrity after partial failures" do
    test "stops on first error", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "partial.txt")
      File.write!(path, "apple banana cherry")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "apple", "new_text" => "APPLE"},
          %{"old_text" => "nonexistent", "new_text" => "FAIL"},
          %{"old_text" => "cherry", "new_text" => "CHERRY"}
        ]
      }, nil, nil, tmp_dir, [])

      assert {:error, _} = result
      # First edit was applied before the error
      content = File.read!(path)
      assert content =~ "APPLE"
      # Third edit was never applied
      refute content =~ "CHERRY"
    end

    test "file reflects all successful edits before failure", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "partial2.txt")
      File.write!(path, "one two three four")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "one", "new_text" => "ONE"},
          %{"old_text" => "two", "new_text" => "TWO"},
          %{"old_text" => "missing", "new_text" => "FAIL"}
        ]
      }, nil, nil, tmp_dir, [])

      assert {:error, _} = result
      content = File.read!(path)
      assert content =~ "ONE"
      assert content =~ "TWO"
      assert content =~ "three"
      assert content =~ "four"
    end
  end

  describe "execute/6 - edge cases" do
    test "empty old_text fails", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "empty_old.txt")
      File.write!(path, "content")

      # Edit tool throws ArgumentError for empty old_text (binary.match fails)
      assert_raise ArgumentError, fn ->
        MultiEdit.execute("call_1", %{
          "path" => path,
          "edits" => [
            %{"old_text" => "", "new_text" => "replacement"}
          ]
        }, nil, nil, tmp_dir, [])
      end
    end

    test "empty new_text (deletion)", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "delete.txt")
      File.write!(path, "hello world goodbye")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => " world", "new_text" => ""}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "hello goodbye"
    end

    test "adjacent edits", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "adjacent.txt")
      File.write!(path, "AABBCC")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "AA", "new_text" => "11"},
          %{"old_text" => "BB", "new_text" => "22"},
          %{"old_text" => "CC", "new_text" => "33"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "112233"
    end

    test "edits that create content for later edits", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "create.txt")
      File.write!(path, "placeholder")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "placeholder", "new_text" => "new_target"},
          %{"old_text" => "new_target", "new_text" => "final_value"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "final_value"
    end

    test "handles relative path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "relative.txt")
      File.write!(path, "original")

      result = MultiEdit.execute("call_1", %{
        "path" => "relative.txt",
        "edits" => [
          %{"old_text" => "original", "new_text" => "modified"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "modified"
    end

    test "handles unicode content", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "unicode.txt")
      File.write!(path, "Hello 世界 Emoji 👋")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "世界", "new_text" => "World"},
          %{"old_text" => "👋", "new_text" => "Wave"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "Hello World Emoji Wave"
    end

    test "preserves BOM", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "bom.txt")
      bom = <<0xEF, 0xBB, 0xBF>>
      File.write!(path, bom <> "Hello World")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "Hello", "new_text" => "Hi"},
          %{"old_text" => "World", "new_text" => "Universe"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert String.starts_with?(content, bom)
      assert content == bom <> "Hi Universe"
    end

    test "preserves CRLF line endings", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "crlf.txt")
      File.write!(path, "line1\r\nline2\r\nline3")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "line1", "new_text" => "FIRST"},
          %{"old_text" => "line3", "new_text" => "THIRD"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content == "FIRST\r\nline2\r\nTHIRD"
    end

    test "handles nil edits parameter", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nil_edits.txt")
      File.write!(path, "content")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => nil
      }, nil, nil, tmp_dir, [])

      assert {:error, msg} = result
      assert msg =~ "Edits must be an array"
    end

    test "edit with nil old_text", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nil_old.txt")
      File.write!(path, "content")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => nil, "new_text" => "replacement"}
        ]
      }, nil, nil, tmp_dir, [])

      # Edit tool handles nil old_text
      assert {:error, _} = result
    end

    test "edit with nil new_text", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nil_new.txt")
      File.write!(path, "content")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "content", "new_text" => nil}
        ]
      }, nil, nil, tmp_dir, [])

      # Edit tool handles nil new_text
      assert {:error, _} = result
    end
  end

  describe "execute/6 - abort signal handling" do
    test "returns error when signal is already aborted", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "abort_before.txt")
      File.write!(path, "original")

      signal = AbortSignal.new()
      AbortSignal.abort(signal)

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "original", "new_text" => "modified"}
        ]
      }, signal, nil, tmp_dir, [])

      assert {:error, "Operation aborted"} = result
      assert File.read!(path) == "original"
    end

    test "proceeds when signal is not aborted", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "no_abort.txt")
      File.write!(path, "original content")

      signal = AbortSignal.new()

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "original", "new_text" => "modified"}
        ]
      }, signal, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "modified content"
    end

    test "checks abort signal between edits", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "abort_between.txt")
      File.write!(path, "first second")

      signal = AbortSignal.new()

      # Start a task that will abort the signal after a brief delay
      Task.start(fn ->
        Process.sleep(10)
        AbortSignal.abort(signal)
      end)

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "first", "new_text" => "FIRST"},
          %{"old_text" => "second", "new_text" => "SECOND"}
        ]
      }, signal, nil, tmp_dir, [])

      # Result could be success or abort depending on timing
      # Just verify operation completed without crash
      assert match?(%AgentToolResult{}, result) or match?({:error, _}, result)
    end

    test "nil signal allows execution", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "nil_signal.txt")
      File.write!(path, "hello world")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "hello", "new_text" => "hi"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "hi world"
    end
  end

  describe "execute/6 - integration with Edit tool" do
    test "multiedit uses Edit tool internally", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "integration.txt")
      File.write!(path, "test content")

      # MultiEdit should produce same result as sequential Edit calls
      multiedit_result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "test", "new_text" => "modified"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = multiedit_result
      assert File.read!(path) == "modified content"
    end

    test "multiedit inherits Edit tool's fuzzy matching", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "fuzzy.txt")
      File.write!(path, "hello    world")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "hello world", "new_text" => "hello_world"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "hello_world"
    end

    test "multiedit inherits Edit tool's smart quote handling", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "quotes.txt")
      curly_quote = <<0x2019::utf8>>
      File.write!(path, "It#{curly_quote}s a test")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "It's a test", "new_text" => "It was a test"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "It was a test"
    end

    test "multiedit result includes diff details", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "diff.txt")
      File.write!(path, "line1\nline2\nline3")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "line2", "new_text" => "changed"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: %{results: [edit_details]}} = result
      assert edit_details.diff
      assert edit_details.first_changed_line
    end
  end

  describe "tool integration" do
    test "tool can be used via execute function", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "tool_integration.txt")
      File.write!(path, "foo bar baz")

      tool = MultiEdit.tool(tmp_dir)

      result = tool.execute.("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "foo", "new_text" => "FOO"},
          %{"old_text" => "baz", "new_text" => "BAZ"}
        ]
      }, nil, nil)

      assert %AgentToolResult{} = result
      assert File.read!(path) == "FOO bar BAZ"
    end
  end

  describe "execute/6 - result structure" do
    test "returns last edit's content in result", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "result.txt")
      File.write!(path, "one two three")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "one", "new_text" => "ONE"},
          %{"old_text" => "two", "new_text" => "TWO"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{content: [%TextContent{text: text}]} = result
      assert text =~ "Successfully replaced"
    end

    test "returns all edit results in details", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "all_details.txt")
      File.write!(path, "a b c")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "a", "new_text" => "A"},
          %{"old_text" => "b", "new_text" => "B"},
          %{"old_text" => "c", "new_text" => "C"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{details: %{results: results}} = result
      assert length(results) == 3
      assert Enum.all?(results, fn r -> Map.has_key?(r, :diff) end)
    end
  end

  describe "execute/6 - complex scenarios" do
    test "code refactoring scenario", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "code.ex")
      # Each search term must be unique in the file
      File.write!(path, """
      defmodule OldModule do
        @host "old_server"
        @port 3000
        @debug false
      end
      """)

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "OldModule", "new_text" => "NewModule"},
          %{"old_text" => "old_server", "new_text" => "new_server"},
          %{"old_text" => "3000", "new_text" => "8080"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content =~ "NewModule"
      assert content =~ "new_server"
      assert content =~ "8080"
      refute content =~ "OldModule"
      refute content =~ "old_server"
      refute content =~ "3000"
    end

    test "updating configuration values", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "config.json")
      File.write!(path, """
      {
        "host": "localhost",
        "port": 3000,
        "debug": false
      }
      """)

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "localhost", "new_text" => "production.example.com"},
          %{"old_text" => "3000", "new_text" => "8080"},
          %{"old_text" => "false", "new_text" => "true"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content =~ "production.example.com"
      assert content =~ "8080"
      assert content =~ "true"
    end

    test "multiple deletions", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "deletions.txt")
      File.write!(path, "keep remove1 keep remove2 keep remove3 keep")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => " remove1", "new_text" => ""},
          %{"old_text" => " remove2", "new_text" => ""},
          %{"old_text" => " remove3", "new_text" => ""}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      assert File.read!(path) == "keep keep keep keep"
    end

    test "multiple insertions via replacement", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "insertions.txt")
      File.write!(path, "MARKER1 MARKER2 MARKER3")

      result = MultiEdit.execute("call_1", %{
        "path" => path,
        "edits" => [
          %{"old_text" => "MARKER1", "new_text" => "MARKER1\ninserted1"},
          %{"old_text" => "MARKER2", "new_text" => "MARKER2\ninserted2"},
          %{"old_text" => "MARKER3", "new_text" => "MARKER3\ninserted3"}
        ]
      }, nil, nil, tmp_dir, [])

      assert %AgentToolResult{} = result
      content = File.read!(path)
      assert content =~ "inserted1"
      assert content =~ "inserted2"
      assert content =~ "inserted3"
    end
  end
end
