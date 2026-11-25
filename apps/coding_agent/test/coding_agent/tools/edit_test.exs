defmodule CodingAgent.Tools.EditTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Edit
  alias LemonAgent.Types.AgentToolResult
  alias LemonAgent.AbortSignal
  alias LemonAi.Types.TextContent

  @moduletag :tmp_dir

  @bom <<0xEF, 0xBB, 0xBF>>

  # Each case is {original, old_text, new_text, expected file content}.
  defp assert_edits(tmp_dir, cases) do
    for {{original, old_text, new_text, expected}, index} <- Enum.with_index(cases) do
      path = Path.join(tmp_dir, "case_#{index}.txt")
      File.write!(path, original)
      label = inspect({original, old_text, new_text})

      assert %AgentToolResult{} = edit(path, tmp_dir, old_text: old_text, new_text: new_text),
             label

      assert File.read!(path) == expected, label
    end
  end

  describe "execute/6 - replacement" do
    test "replaces exact text and reports success", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "test.txt")
      File.write!(path, "Hello, World!")

      assert %AgentToolResult{content: [%TextContent{text: text}]} =
               edit(path, tmp_dir, old_text: "World", new_text: "Elixir")

      assert text =~ "Successfully replaced text"
      assert File.read!(path) == "Hello, Elixir!"
    end

    test "replaces text at any position, including special characters", %{tmp_dir: tmp_dir} do
      assert_edits(tmp_dir, [
        {"line 1\nline 2\nline 3\n", "line 2", "replaced line",
         "line 1\nreplaced line\nline 3\n"},
        {"needle rest of file", "needle", "replaced", "replaced rest of file"},
        {"rest of file needle", "needle", "replaced", "rest of file replaced"},
        {"x", "x", "y", "y"},
        {"entire content", "entire content", "new entire content", "new entire content"},
        {"prefix_content_suffix", "prefix_", "", "content_suffix"},
        {"start middle end", "start middle end", "line1\nline2\nline3", "line1\nline2\nline3"},
        {"normal path/file", "path/file", "path\\file", "normal path\\file"},
        {"match this", "match", "$1.*+?{}[]()", "$1.*+?{}[]() this"},
        {"line1_X_line2", "_X_", "\t", "line1\tline2"}
      ])
    end

    test "replaces multibyte and multi-codepoint text", %{tmp_dir: tmp_dir} do
      family = "👨‍👩‍👧‍👦"

      assert_edits(tmp_dir, [
        {"Hello 👋 World", "👋", "🌍", "Hello 🌍 World"},
        {"Start #{family} End", family, "family", "Start family End"},
        {"Start مرحبا End", "مرحبا", "السلام", "Start السلام End"},
        {"hello world", "hello", "𝕳𝖎", "𝕳𝖎 world"},
        {"Hello 世界", "世界", "世界你好", "Hello 世界你好"}
      ])
    end

    test "handles relative paths", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "relative.txt")
      File.write!(path, "original content")

      assert %AgentToolResult{} =
               edit("relative.txt", tmp_dir, old_text: "original", new_text: "modified")

      assert File.read!(path) == "modified content"
    end

    test "tool can be used via execute function", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "integration.txt")
      File.write!(path, "test content")

      result =
        Edit.tool(tmp_dir).execute.(
          "call_1",
          %{"path" => path, "old_text" => "test", "new_text" => "new"},
          nil,
          nil
        )

      assert %AgentToolResult{} = result
      assert File.read!(path) == "new content"
    end

    test "reports introduced diagnostics when requested", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "diagnostics.exs")
      File.write!(path, "value = 1\n")

      result =
        Edit.execute(
          "call_1",
          %{
            "path" => path,
            "old_text" => "value = 1",
            "new_text" => "defmodule Bad do",
            "diagnostics" => true
          },
          nil,
          nil,
          tmp_dir,
          semantic: false
        )

      assert %AgentToolResult{content: [%TextContent{text: text}], details: details} = result
      assert text =~ "Diagnostics introduced 1 issue"
      assert details.diagnostics.status == :diagnostics
      assert length(details.diagnostics.introduced_diagnostics) == 1
    end

    test "includes the diff and first changed line in details", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "diff.txt")
      File.write!(path, "line1\nline2\nline3\nline4\nline5")

      assert %AgentToolResult{details: details} =
               edit(path, tmp_dir, old_text: "line2", new_text: "replaced")

      assert details.diff =~ "replaced"
      assert details.first_changed_line == 2
    end
  end

  describe "execute/6 - BOM and line endings" do
    test "preserves the BOM and the file's line endings", %{tmp_dir: tmp_dir} do
      assert_edits(tmp_dir, [
        {@bom <> "Hello, World!", "World", "BOM", @bom <> "Hello, BOM!"},
        {@bom <> "café 🌍", "café", "coffee", @bom <> "coffee 🌍"},
        {@bom <> "line1\r\nline2\r\nline3", "line2", "replaced",
         @bom <> "line1\r\nreplaced\r\nline3"},
        {"line1\r\nline2\r\nline3", "line2", "replaced", "line1\r\nreplaced\r\nline3"},
        {"line1\nline2\nline3", "line2", "replaced", "line1\nreplaced\nline3"},
        {"line1\r\nline2\r\nline3", "line1\nline2", "replaced", "replaced\r\nline3"},
        {"line1\r\nline2\r\nline3", "line2", "line2a\nline2b",
         "line1\r\nline2a\r\nline2b\r\nline3"},
        {"a\r\n    b  c\r\nd\r\n", "b c", "x", "a\r\n    x\r\nd\r\n"}
      ])
    end
  end

  describe "execute/6 - fuzzy matching" do
    test "normalizes whitespace, smart quotes and unicode dashes", %{tmp_dir: tmp_dir} do
      assert_edits(tmp_dir, [
        {"hello world   \nnext line", "hello world\nnext", "hello universe\nnext",
         "hello universe\nnext line"},
        {"It\u2019s a test", "It's a test", "It was a test", "It was a test"},
        {"She said \u201Chello\u201D", "She said \"hello\"", "She said \"hi\"",
         "She said \"hi\""},
        {"hello\u2014world", "hello-world", "hello_world", "hello_world"},
        {"hello    world", "hello world", "hello_world", "hello_world"}
      ])
    end

    test "replaces the right span after multibyte text", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "cafe.ex")

      File.write!(path, """
      defmodule Café do
        # © 2026 — naïve résumé
        def greet(name) do
          "héllo " <> name
        end

        def other, do: :ok
      end
      """)

      result =
        edit(path, tmp_dir,
          old_text: "def greet(name)  do\n  \"héllo \" <> name\nend",
          new_text: "def greet(name) do\n    \"bonjour \" <> name\n  end"
        )

      assert %AgentToolResult{} = result

      assert File.read!(path) == """
             defmodule Café do
               # © 2026 — naïve résumé
               def greet(name) do
                 "bonjour " <> name
               end

               def other, do: :ok
             end
             """
    end

    test "matches near the end of a long indented file", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "long.ex")
      lines = for i <- 1..800, do: "    value_#{i} = compute(#{i})"
      File.write!(path, Enum.join(lines, "\n") <> "\n")

      result =
        edit(path, tmp_dir,
          old_text: "value_799 =  compute(799)\nvalue_800 = compute(800)",
          new_text: "value_799 = 0\n    value_800 = 0"
        )

      assert %AgentToolResult{} = result
      new_lines = path |> File.read!() |> String.split("\n")
      assert Enum.at(new_lines, 797) == "    value_798 = compute(798)"
      assert Enum.at(new_lines, 798) == "    value_799 = 0"
      assert Enum.at(new_lines, 799) == "    value_800 = 0"
      assert List.last(new_lines) == ""
    end

    test "an ambiguous whitespace-insensitive match is an error naming the lines", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "ambiguous.txt")
      original = "  call  a\nother\n\tcall   a\n"
      File.write!(path, original)

      assert {:error, message} = edit(path, tmp_dir, old_text: "call a", new_text: "call b")
      assert message =~ "2 occurrences"
      assert message =~ "lines 1, 3"
      assert File.read!(path) == original
    end
  end

  describe "execute/6 - errors" do
    test "rejects edits that cannot apply and leaves the file untouched", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "errors.txt")
      original = "hello world hello universe"
      File.write!(path, original)

      for {target, old_text, new_text, expected} <- [
            {Path.join(tmp_dir, "nonexistent.txt"), "hello", "hi", "File not found"},
            {"nonexistent.txt", "hello", "hi", "File not found"},
            {path, "xyz", "abc", "Could not find the exact text"},
            {path, "hello", "hi", "2 occurrences"},
            {path, "hello", "hi", "must be unique"},
            {path, "world", "world", "No changes made"},
            {path, "", "x", "must not be empty"}
          ] do
        assert {:error, message} = edit(target, tmp_dir, old_text: old_text, new_text: new_text)
        assert message =~ expected
      end

      assert File.read!(path) == original
    end

    test "an aborted signal blocks the edit; a live one allows it", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "abort.txt")
      File.write!(path, "original content")
      aborted = AbortSignal.new()
      AbortSignal.abort(aborted)

      assert {:error, "Operation aborted"} =
               edit(path, tmp_dir, [old_text: "original", new_text: "modified"], [], aborted)

      assert File.read!(path) == "original content"

      assert %AgentToolResult{} =
               edit(
                 path,
                 tmp_dir,
                 [old_text: "original", new_text: "modified"],
                 [],
                 AbortSignal.new()
               )

      assert File.read!(path) == "modified content"
    end
  end

  describe "execute/6 - concurrency and staleness" do
    test "concurrent edits of one file all apply", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "concurrent.txt")
      File.write!(path, Enum.map_join(1..20, "", &"line #{&1}\n"))

      1..20
      |> Enum.map(fn i ->
        Task.async(fn ->
          edit(path, tmp_dir, old_text: "line #{i}\n", new_text: "edited #{i}\n")
        end)
      end)
      |> Task.await_many(10_000)
      |> Enum.each(&assert(%AgentToolResult{} = &1))

      assert File.read!(path) == Enum.map_join(1..20, "", &"edited #{&1}\n")
    end

    test "an edit is rejected when the file changed on disk since it was read", %{
      tmp_dir: tmp_dir
    } do
      path = Path.join(tmp_dir, "stale.txt")
      File.write!(path, "alpha\nbeta\n")
      opts = [session_id: "stale-#{System.unique_integer([:positive])}"]

      assert %AgentToolResult{} =
               CodingAgent.Tools.Read.execute("r1", %{"path" => path}, nil, nil, tmp_dir, opts)

      File.write!(path, "alpha\nbeta\ngamma\n")

      assert {:error, message} =
               edit(path, tmp_dir, [old_text: "alpha", new_text: "ALPHA"], opts)

      assert message =~
               "Current snapshot [#{path}##{CodingAgent.Tools.AnchoredEdit.snapshot("alpha\nbeta\ngamma\n")}]"

      assert message =~ "3: gamma"
      assert File.read!(path) == "alpha\nbeta\ngamma\n"

      assert %AgentToolResult{} =
               edit(path, tmp_dir, [old_text: "alpha", new_text: "ALPHA"], opts)

      # The session's own edit refreshes its view: a follow-up edit needs no re-read.
      assert %AgentToolResult{} = edit(path, tmp_dir, [old_text: "beta", new_text: "BETA"], opts)
      assert File.read!(path) == "ALPHA\nBETA\ngamma\n"
    end
  end

  defp edit(path, cwd, params, opts \\ [], signal \\ nil) do
    Edit.execute(
      "call_edit",
      %{
        "path" => path,
        "old_text" => Keyword.fetch!(params, :old_text),
        "new_text" => Keyword.fetch!(params, :new_text)
      },
      signal,
      nil,
      cwd,
      opts
    )
  end
end
