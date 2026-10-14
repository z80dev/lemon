defmodule CodingAgent.Tools.Lsp.TextTest do
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.Lsp.Text

  describe "UTF-16 mapping" do
    test "counts astral code points as surrogate pairs" do
      assert Text.utf16_length("abc") == 3
      assert Text.utf16_length("é") == 1
      assert Text.utf16_length("😀") == 2
      assert Text.utf16_length("a😀b") == 4
    end

    test "maps UTF-16 offsets to byte offsets and clamps past the line end" do
      line = "é😀x"
      assert Text.utf16_to_byte(line, 0) == 0
      assert Text.utf16_to_byte(line, 1) == 2
      assert Text.utf16_to_byte(line, 3) == 6
      assert Text.utf16_to_byte(line, 4) == 7
      assert Text.utf16_to_byte(line, 99) == byte_size(line)
      # Inside a surrogate pair resolves to the pair's start.
      assert Text.utf16_to_byte(line, 2) == 2
    end

    test "reports code-point display columns" do
      line = "/* 😀 */ foo"
      assert Text.display_column(line, Text.utf16_length("/* 😀 */ ")) == 9
      assert Text.codepoints_to_utf16(line, 9) == 10
    end
  end

  describe "resolve_character/4" do
    @content "alpha beta\r\n  x = 😀 + beta_2 + beta\nlast"

    test "locates a symbol at a word boundary and converts to UTF-16" do
      assert {:ok, 0} = Text.resolve_character(@content, 1, "alpha", nil)
      # `beta` must not match inside `beta_2`; the emoji counts as two units.
      assert {:ok, 20} = Text.resolve_character(@content, 2, "beta", nil)
      assert {:ok, 11} = Text.resolve_character(@content, 2, "beta_2", nil)
    end

    test "selects the Nth occurrence and reports out-of-range occurrences" do
      content = "f(x) + f(y) + f(z)"
      assert {:ok, 7} = Text.resolve_character(content, 1, "f#2", nil)
      assert {:error, message} = Text.resolve_character(content, 1, "f#4", nil)
      assert message =~ "occurrence 4 is out of bounds"
    end

    test "falls back to case-insensitive matches, then column, then indentation" do
      assert {:ok, 0} = Text.resolve_character(@content, 1, "ALPHA", nil)
      assert {:error, message} = Text.resolve_character(@content, 1, "gamma", nil)
      assert message =~ "not found on line 1"
      assert {:ok, 9} = Text.resolve_character(@content, 2, nil, 9)
      assert {:ok, 2} = Text.resolve_character(@content, 2, nil, nil)
      assert {:error, message} = Text.resolve_character(@content, 9, nil, nil)
      assert message =~ "past the end"
    end
  end

  describe "apply_edits/2" do
    defp edit(sl, sc, el, ec, text) do
      %{
        "range" => %{
          "start" => %{"line" => sl, "character" => sc},
          "end" => %{"line" => el, "character" => ec}
        },
        "newText" => text
      }
    end

    test "applies unordered edits using UTF-16 columns and keeps CRLF" do
      content = "let 😀x = 1;\r\nx + x\r\n"

      assert {:ok, "let 😀y = 1;\r\ny + y\r\n"} =
               Text.apply_edits(content, [
                 edit(1, 4, 1, 5, "y"),
                 edit(0, 6, 0, 7, "y"),
                 edit(1, 0, 1, 1, "y")
               ])
    end

    test "keeps array order for inserts at one position and collapses duplicates" do
      assert {:ok, "abXYc"} =
               Text.apply_edits("abc", [edit(0, 2, 0, 2, "X"), edit(0, 2, 0, 2, "Y")])

      assert {:ok, "aZc"} =
               Text.apply_edits("abc", [edit(0, 1, 0, 2, "Z"), edit(0, 1, 0, 2, "Z")])
    end

    test "spans lines and clamps positions past the end" do
      assert {:ok, "one\nTAIL"} =
               Text.apply_edits("one\ntwo\nthree", [edit(1, 0, 9, 0, "TAIL")])

      assert {:ok, "ab!"} = Text.apply_edits("ab", [edit(0, 99, 0, 99, "!")])
    end

    test "rejects overlapping, malformed and snippet edits" do
      assert {:error, message} =
               Text.apply_edits("abcdef", [edit(0, 0, 0, 3, "x"), edit(0, 2, 0, 4, "y")])

      assert message =~ "overlapping"

      assert {:error, _} = Text.apply_edits("abc", [%{"newText" => "x"}])
      assert {:error, _} = Text.apply_edits("abc", [edit(0, 2, 0, 1, "x")])

      assert {:error, message} =
               Text.apply_edits("abc", [Map.put(edit(0, 0, 0, 0, "$1"), "insertTextFormat", 2)])

      assert message =~ "snippet"
    end
  end

  describe "paths" do
    test "round-trips file URIs with escaped characters" do
      uri = Text.path_to_uri("/tmp/a dir/x#1.c")
      assert uri == "file:///tmp/a%20dir/x%231.c"
      assert {:ok, "/tmp/a dir/x#1.c"} = Text.uri_to_path(uri)
      assert {:ok, "/x.c"} = Text.uri_to_path("file://localhost/x.c")
      assert :error = Text.uri_to_path("untitled:1")
    end

    test "displays paths relative to the cwd or its real path" do
      tmp = Path.join(System.tmp_dir!(), "lsp_text_#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(tmp, "real/sub"))
      File.ln_s!(Path.join(tmp, "real"), Path.join(tmp, "link"))
      on_exit(fn -> File.rm_rf!(tmp) end)

      cwd = Path.join(tmp, "link")
      real = Text.realpath(Path.join(cwd, "sub"))

      assert real == Path.join(Text.realpath(tmp), "real/sub")
      assert Text.display_path(Path.join(cwd, "sub/a.c"), cwd) == "sub/a.c"
      assert Text.display_path(Path.join(real, "a.c"), cwd) == "sub/a.c"
      assert Text.display_path("/elsewhere/a.c", cwd) == "/elsewhere/a.c"
    end
  end
end
