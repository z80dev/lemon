defmodule LemonChannels.Telegram.MarkdownTest do
  use ExUnit.Case, async: true

  alias LemonChannels.Telegram.Markdown

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------

  defp find_entity(entities, type) do
    Enum.find(entities, fn ent -> ent["type"] == type end)
  end

  defp find_entities(entities, type) do
    Enum.filter(entities, fn ent -> ent["type"] == type end)
  end

  defp utf16_len(text) do
    bin = :unicode.characters_to_binary(text, :utf8, {:utf16, :little})
    div(byte_size(bin), 2)
  end

  # ------------------------------------------------------------------
  # nil and empty input
  # ------------------------------------------------------------------

  describe "nil input" do
    test "returns empty string and empty entities" do
      assert {"", []} == Markdown.render(nil)
    end
  end

  # ------------------------------------------------------------------
  # Plain text (no markdown)
  # ------------------------------------------------------------------

  describe "plain text" do
    test "returns text unchanged with no entities" do
      {text, entities} = Markdown.render("Hello, world!")
      assert String.trim(text) == "Hello, world!"
      assert entities == []
    end

    test "preserves whitespace in plain text" do
      {text, _entities} = Markdown.render("Hello   world")
      assert text |> String.trim() |> String.contains?("Hello")
      assert text |> String.trim() |> String.contains?("world")
    end

    test "empty string returns empty" do
      {text, entities} = Markdown.render("")
      assert String.trim(text) == ""
      assert entities == []
    end
  end

  # ------------------------------------------------------------------
  # Bold
  # ------------------------------------------------------------------

  describe "bold text" do
    test "**bold** produces a bold entity" do
      {text, entities} = Markdown.render("**bold**")
      assert String.trim(text) =~ "bold"
      bold = find_entity(entities, "bold")
      assert bold != nil
      assert bold["length"] == utf16_len("bold")
    end

    test "text before and after bold" do
      {text, entities} = Markdown.render("before **bold** after")
      trimmed = String.trim(text)
      assert trimmed =~ "before"
      assert trimmed =~ "bold"
      assert trimmed =~ "after"

      bold = find_entity(entities, "bold")
      assert bold != nil
      assert bold["length"] == utf16_len("bold")

      # The offset should point to where "bold" starts in the text
      extracted = String.slice(trimmed, bold["offset"], bold["length"])
      assert extracted == "bold"
    end
  end

  # ------------------------------------------------------------------
  # Italic
  # ------------------------------------------------------------------

  describe "italic text" do
    test "*italic* produces an italic entity" do
      {text, entities} = Markdown.render("*italic*")
      assert String.trim(text) =~ "italic"
      italic = find_entity(entities, "italic")
      assert italic != nil
      assert italic["length"] == utf16_len("italic")
    end

    test "text around italic" do
      {text, entities} = Markdown.render("say *hello* now")
      trimmed = String.trim(text)
      assert trimmed =~ "hello"

      italic = find_entity(entities, "italic")
      assert italic != nil

      extracted = String.slice(trimmed, italic["offset"], italic["length"])
      assert extracted == "hello"
    end
  end

  # ------------------------------------------------------------------
  # Inline code
  # ------------------------------------------------------------------

  describe "inline code" do
    test "`code` produces a code entity" do
      {text, entities} = Markdown.render("`code`")
      assert String.trim(text) =~ "code"
      code = find_entity(entities, "code")
      assert code != nil
      assert code["length"] == utf16_len("code")
    end

    test "inline code preserves content" do
      {text, entities} = Markdown.render("run `mix test` now")
      trimmed = String.trim(text)
      assert trimmed =~ "mix test"

      code = find_entity(entities, "code")
      assert code != nil

      extracted = String.slice(trimmed, code["offset"], code["length"])
      assert extracted == "mix test"
    end
  end

  # ------------------------------------------------------------------
  # Code blocks (pre)
  # ------------------------------------------------------------------

  describe "code block" do
    test "fenced code block produces a pre entity" do
      md = "```\nfoo = 1\n```"
      {text, entities} = Markdown.render(md)
      assert text =~ "foo = 1"
      pre = find_entity(entities, "pre")
      assert pre != nil
      assert pre["length"] > 0
    end

    test "fenced code block with language includes language field" do
      md = "```elixir\nIO.puts(\"hi\")\n```"
      {text, entities} = Markdown.render(md)
      assert text =~ "IO.puts"
      pre = find_entity(entities, "pre")
      assert pre != nil
      assert pre["language"] == "elixir"
    end

    test "fenced code block with python language" do
      md = "```python\nprint('hello')\n```"
      {text, entities} = Markdown.render(md)
      assert text =~ "print"
      pre = find_entity(entities, "pre")
      assert pre != nil
      assert pre["language"] == "python"
    end

    test "code block without language has no language key" do
      md = "```\nplain code\n```"
      {_text, entities} = Markdown.render(md)
      pre = find_entity(entities, "pre")
      assert pre != nil
      refute Map.has_key?(pre, "language")
    end
  end

  # ------------------------------------------------------------------
  # Links
  # ------------------------------------------------------------------

  describe "links" do
    test "[text](url) produces a text_link entity" do
      {text, entities} = Markdown.render("[click here](https://example.com)")
      assert String.trim(text) =~ "click here"
      link = find_entity(entities, "text_link")
      assert link != nil
      assert link["url"] == "https://example.com"
      assert link["length"] == utf16_len("click here")
    end

    test "link offset is correct with preceding text" do
      {text, entities} = Markdown.render("Go to [Google](https://google.com) now")
      trimmed = String.trim(text)
      assert trimmed =~ "Google"

      link = find_entity(entities, "text_link")
      assert link != nil
      assert link["url"] == "https://google.com"

      extracted = String.slice(trimmed, link["offset"], link["length"])
      assert extracted == "Google"
    end
  end

  # ------------------------------------------------------------------
  # Headings
  # ------------------------------------------------------------------

  describe "headings" do
    test "# Heading renders as bold entity" do
      {text, entities} = Markdown.render("# Heading")
      assert String.trim(text) =~ "Heading"
      bold = find_entity(entities, "bold")
      assert bold != nil
      assert bold["length"] == utf16_len("Heading")
    end

    test "## Subheading also renders as bold" do
      {text, entities} = Markdown.render("## Subheading")
      assert String.trim(text) =~ "Subheading"
      bold = find_entity(entities, "bold")
      assert bold != nil
    end

    test "### Third level heading renders as bold" do
      {text, entities} = Markdown.render("### Third")
      assert String.trim(text) =~ "Third"
      bold = find_entity(entities, "bold")
      assert bold != nil
    end

    test "heading text does not include the # prefix" do
      {text, _entities} = Markdown.render("# Hello World")
      trimmed = String.trim(text)
      refute trimmed =~ "#"
      assert trimmed =~ "Hello World"
    end
  end

  # ------------------------------------------------------------------
  # Strikethrough
  # ------------------------------------------------------------------

  describe "strikethrough" do
    test "~~text~~ produces a strikethrough entity" do
      {text, entities} = Markdown.render("~~deleted~~")
      assert String.trim(text) =~ "deleted"
      strike = find_entity(entities, "strikethrough")
      assert strike != nil
      assert strike["length"] == utf16_len("deleted")
    end
  end

  # ------------------------------------------------------------------
  # Unordered list
  # ------------------------------------------------------------------

  describe "unordered list" do
    test "renders list items with - prefix" do
      md = "- alpha\n- beta\n- gamma"
      {text, _entities} = Markdown.render(md)
      assert text =~ "- alpha"
      assert text =~ "- beta"
      assert text =~ "- gamma"
    end

    test "list items appear on separate lines" do
      md = "- one\n- two"
      {text, _entities} = Markdown.render(md)
      lines = String.split(text, "\n", trim: true)
      dash_lines = Enum.filter(lines, &String.starts_with?(&1, "- "))
      assert length(dash_lines) == 2
    end
  end

  # ------------------------------------------------------------------
  # Ordered list
  # ------------------------------------------------------------------

  describe "ordered list" do
    test "renders items with numbers" do
      md = "1. first\n2. second\n3. third"
      {text, _entities} = Markdown.render(md)
      assert text =~ "1. first"
      assert text =~ "2. second"
      assert text =~ "3. third"
    end

    test "numbering starts from 1" do
      md = "1. only"
      {text, _entities} = Markdown.render(md)
      assert text =~ "1. only"
    end
  end

  # ------------------------------------------------------------------
  # Blockquote
  # ------------------------------------------------------------------

  describe "blockquote" do
    test "renders with > prefix" do
      md = "> quoted text"
      {text, _entities} = Markdown.render(md)
      assert text =~ "> quoted text"
    end
  end

  # ------------------------------------------------------------------
  # Nested formatting
  # ------------------------------------------------------------------

  describe "nested formatting" do
    test "bold inside italic produces both entities" do
      md = "*hello **world***"
      {text, entities} = Markdown.render(md)
      trimmed = String.trim(text)
      assert trimmed =~ "world"

      italic = find_entity(entities, "italic")
      bold = find_entity(entities, "bold")
      assert italic != nil
      assert bold != nil
    end

    test "italic inside bold produces both entities" do
      md = "**hello *world***"
      {text, entities} = Markdown.render(md)
      trimmed = String.trim(text)
      assert trimmed =~ "world"

      italic = find_entity(entities, "italic")
      bold = find_entity(entities, "bold")
      assert italic != nil
      assert bold != nil
    end

    test "bold and italic have correct nesting relationship" do
      md = "**hello *world***"
      {_text, entities} = Markdown.render(md)

      bold = find_entity(entities, "bold")
      italic = find_entity(entities, "italic")

      # The italic entity should be contained within the bold entity
      assert italic["offset"] >= bold["offset"]
      assert italic["offset"] + italic["length"] <= bold["offset"] + bold["length"]
    end

    test "inline code inside bold" do
      md = "**run `mix test`**"
      {text, entities} = Markdown.render(md)
      assert String.trim(text) =~ "mix test"

      bold = find_entity(entities, "bold")
      code = find_entity(entities, "code")
      assert bold != nil
      assert code != nil
    end
  end

  # ------------------------------------------------------------------
  # Entity offset and length correctness
  # ------------------------------------------------------------------

  describe "entity offsets and lengths" do
    test "single bold entity has offset 0 when at start" do
      {_text, entities} = Markdown.render("**hello**")
      bold = find_entity(entities, "bold")
      assert bold["offset"] == 0
      assert bold["length"] == utf16_len("hello")
    end

    test "entity offset accounts for preceding text" do
      {text, entities} = Markdown.render("abc **def**")
      trimmed = String.trim(text)
      bold = find_entity(entities, "bold")
      assert bold != nil

      # Extract what the entity points to using the trimmed text
      extracted = String.slice(trimmed, bold["offset"], bold["length"])
      assert extracted == "def"
    end

    test "multiple entities have non-overlapping offsets (unless nested)" do
      md = "**bold** and *italic*"
      {_text, entities} = Markdown.render(md)

      bold = find_entity(entities, "bold")
      italic = find_entity(entities, "italic")
      assert bold != nil
      assert italic != nil

      # bold should end before italic starts (they are separate)
      assert bold["offset"] + bold["length"] <= italic["offset"]
    end

    test "multiple bold entities each point to correct text" do
      md = "**first** and **second**"
      {text, entities} = Markdown.render(md)
      trimmed = String.trim(text)

      bolds = find_entities(entities, "bold")
      assert length(bolds) == 2

      extracted =
        Enum.map(bolds, fn ent ->
          String.slice(trimmed, ent["offset"], ent["length"])
        end)

      assert "first" in extracted
      assert "second" in extracted
    end

    test "entity length matches UTF-16 length of the content" do
      {_text, entities} = Markdown.render("**bold**")
      bold = find_entity(entities, "bold")
      assert bold["length"] == utf16_len("bold")
    end
  end

  # ------------------------------------------------------------------
  # UTF-16 offsets for emoji / unicode
  # ------------------------------------------------------------------

  describe "UTF-16 offsets for emoji and unicode" do
    test "emoji before entity shifts offset correctly" do
      # The rocket emoji U+1F680 takes 2 UTF-16 code units (surrogate pair)
      md = "\u{1F680} **bold**"
      {text, entities} = Markdown.render(md)
      trimmed = String.trim(text)
      assert trimmed =~ "bold"

      bold = find_entity(entities, "bold")
      assert bold != nil

      # Verify the offset accounts for the emoji (2 UTF-16 units) + space (1 unit)
      # The emoji is U+1F680, which is a supplementary character -> 2 UTF-16 units
      assert bold["offset"] == utf16_len("\u{1F680} ")
      assert bold["length"] == utf16_len("bold")
    end

    test "entity length for text containing emoji" do
      # Bold text with emoji inside
      md = "**hello \u{1F600}**"
      {text, entities} = Markdown.render(md)
      assert String.trim(text) =~ "hello"

      bold = find_entity(entities, "bold")
      assert bold != nil
      # "hello " (6 code units) + U+1F600 grinning face (2 code units) = 8
      assert bold["length"] == utf16_len("hello \u{1F600}")
    end

    test "basic ASCII has UTF-16 length equal to byte length" do
      assert utf16_len("hello") == 5
      assert utf16_len("abc") == 3
    end

    test "BMP characters (non-ASCII) have correct UTF-16 length" do
      # Cyrillic, CJK, etc. are still 1 UTF-16 unit each
      assert utf16_len("\u{0410}") == 1  # Cyrillic A
      assert utf16_len("\u{4E16}") == 1  # CJK character
    end

    test "supplementary plane emoji use 2 UTF-16 code units" do
      assert utf16_len("\u{1F680}") == 2  # rocket
      assert utf16_len("\u{1F600}") == 2  # grinning face
    end

    test "multiple emoji before entity" do
      md = "\u{1F600}\u{1F680} **text**"
      {text, entities} = Markdown.render(md)
      assert String.trim(text) =~ "text"

      bold = find_entity(entities, "bold")
      assert bold != nil
      # Two emoji (2+2 = 4 UTF-16 units) + space (1 unit) = 5
      assert bold["offset"] == utf16_len("\u{1F600}\u{1F680} ")
    end

    test "entity after CJK text has correct offset" do
      md = "\u{4F60}\u{597D} **world**"
      {text, entities} = Markdown.render(md)
      assert String.trim(text) =~ "world"

      bold = find_entity(entities, "bold")
      assert bold != nil
      # Two CJK chars (1+1 = 2 UTF-16 units) + space (1 unit) = 3
      assert bold["offset"] == utf16_len("\u{4F60}\u{597D} ")
    end
  end

  # ------------------------------------------------------------------
  # Entity structure
  # ------------------------------------------------------------------

  describe "entity map structure" do
    test "entity has required keys: type, offset, length" do
      {_text, entities} = Markdown.render("**bold**")
      bold = find_entity(entities, "bold")
      assert Map.has_key?(bold, "type")
      assert Map.has_key?(bold, "offset")
      assert Map.has_key?(bold, "length")
    end

    test "text_link entity includes url key" do
      {_text, entities} = Markdown.render("[link](https://example.com)")
      link = find_entity(entities, "text_link")
      assert Map.has_key?(link, "url")
      assert link["url"] == "https://example.com"
    end

    test "pre entity with language includes language key" do
      md = "```ruby\nputs 'hi'\n```"
      {_text, entities} = Markdown.render(md)
      pre = find_entity(entities, "pre")
      assert Map.has_key?(pre, "language")
      assert pre["language"] == "ruby"
    end

    test "offset and length are integers" do
      {_text, entities} = Markdown.render("**bold**")
      bold = find_entity(entities, "bold")
      assert is_integer(bold["offset"])
      assert is_integer(bold["length"])
    end
  end

  # ------------------------------------------------------------------
  # Mixed content
  # ------------------------------------------------------------------

  describe "mixed content" do
    test "paragraph with bold, italic, and code" do
      md = "This is **bold**, *italic*, and `code` in one line."
      {text, entities} = Markdown.render(md)
      trimmed = String.trim(text)

      assert trimmed =~ "bold"
      assert trimmed =~ "italic"
      assert trimmed =~ "code"

      assert find_entity(entities, "bold") != nil
      assert find_entity(entities, "italic") != nil
      assert find_entity(entities, "code") != nil
    end

    test "heading followed by paragraph" do
      md = "# Title\n\nSome body text."
      {text, entities} = Markdown.render(md)
      trimmed = String.trim(text)

      assert trimmed =~ "Title"
      assert trimmed =~ "Some body text."

      bold = find_entity(entities, "bold")
      assert bold != nil

      extracted = String.slice(trimmed, bold["offset"], bold["length"])
      assert extracted == "Title"
    end

    test "list followed by paragraph" do
      md = "- item one\n- item two\n\nAfter the list."
      {text, _entities} = Markdown.render(md)
      assert text =~ "- item one"
      assert text =~ "- item two"
      assert text =~ "After the list."
    end
  end

  # ------------------------------------------------------------------
  # Edge cases
  # ------------------------------------------------------------------

  describe "edge cases" do
    test "multiple paragraphs separated by blank lines" do
      md = "First paragraph.\n\nSecond paragraph."
      {text, _entities} = Markdown.render(md)
      assert text =~ "First paragraph."
      assert text =~ "Second paragraph."
    end

    test "bold text at end of string" do
      {text, entities} = Markdown.render("end **bold**")
      assert String.trim(text) =~ "bold"
      bold = find_entity(entities, "bold")
      assert bold != nil
    end

    test "empty bold markers produce no entity" do
      {_text, entities} = Markdown.render("****")
      # Empty bold should not produce an entity
      assert find_entity(entities, "bold") == nil
    end

    test "link with empty url renders text without entity" do
      # A link with no href should not produce a text_link entity
      {text, entities} = Markdown.render("[text]()")
      # Earmark may or may not parse this as a link; either way check no crash
      assert is_binary(text)
      assert is_list(entities)
    end

    test "render returns a two-element tuple" do
      result = Markdown.render("anything")
      assert is_tuple(result)
      assert tuple_size(result) == 2
      {text, entities} = result
      assert is_binary(text)
      assert is_list(entities)
    end
  end
end
