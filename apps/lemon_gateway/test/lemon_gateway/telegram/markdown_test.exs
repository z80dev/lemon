defmodule LemonGateway.Telegram.MarkdownTest do
  @moduledoc """
  Tests for LemonGateway.Telegram.Markdown renderer.
  Covers plain text, formatting entities, code blocks, links, lists, and edge cases.
  """
  use ExUnit.Case, async: true

  alias LemonGateway.Telegram.Markdown

  # ============================================================================
  # Plain text
  # ============================================================================

  describe "render/1 - plain text" do
    test "renders nil as empty" do
      assert {"", []} = Markdown.render(nil)
    end

    test "renders plain text without entities" do
      {text, entities} = Markdown.render("Hello world")
      assert text =~ "Hello world"
      assert entities == []
    end

    test "renders multiline plain text" do
      {text, _entities} = Markdown.render("Line 1\n\nLine 2")
      assert text =~ "Line 1"
      assert text =~ "Line 2"
    end
  end

  # ============================================================================
  # Bold / Italic / Strikethrough
  # ============================================================================

  describe "render/1 - inline formatting" do
    test "renders bold text with bold entity" do
      {text, entities} = Markdown.render("**bold text**")
      assert text =~ "bold text"
      assert Enum.any?(entities, &(&1["type"] == "bold"))
    end

    test "renders italic text with italic entity" do
      {text, entities} = Markdown.render("*italic text*")
      assert text =~ "italic text"
      assert Enum.any?(entities, &(&1["type"] == "italic"))
    end

    test "renders strikethrough text" do
      {text, entities} = Markdown.render("~~struck~~")
      assert text =~ "struck"
      assert Enum.any?(entities, &(&1["type"] == "strikethrough"))
    end

    test "renders inline code with code entity" do
      {text, entities} = Markdown.render("`some code`")
      assert text =~ "some code"
      assert Enum.any?(entities, &(&1["type"] == "code"))
    end
  end

  # ============================================================================
  # Code blocks
  # ============================================================================

  describe "render/1 - code blocks" do
    test "renders fenced code block with pre entity" do
      md = "```\nfoo = bar\n```"
      {text, entities} = Markdown.render(md)
      assert text =~ "foo = bar"
      assert Enum.any?(entities, &(&1["type"] == "pre"))
    end

    test "renders fenced code block with language" do
      md = "```elixir\ndef hello, do: :world\n```"
      {text, entities} = Markdown.render(md)
      assert text =~ "def hello"
      pre = Enum.find(entities, &(&1["type"] == "pre"))
      assert pre != nil
      assert pre["language"] == "elixir"
    end
  end

  # ============================================================================
  # Links
  # ============================================================================

  describe "render/1 - links" do
    test "renders markdown link with text_link entity" do
      {text, entities} = Markdown.render("[click here](https://example.com)")
      assert text =~ "click here"

      link_entity = Enum.find(entities, &(&1["type"] == "text_link"))
      assert link_entity != nil
      assert link_entity["url"] == "https://example.com"
    end
  end

  # ============================================================================
  # Headings
  # ============================================================================

  describe "render/1 - headings" do
    test "renders h1 as bold text" do
      {text, entities} = Markdown.render("# My Heading")
      assert text =~ "My Heading"
      assert Enum.any?(entities, &(&1["type"] == "bold"))
    end

    test "renders h2 as bold text" do
      {text, entities} = Markdown.render("## Sub Heading")
      assert text =~ "Sub Heading"
      assert Enum.any?(entities, &(&1["type"] == "bold"))
    end
  end

  # ============================================================================
  # Lists
  # ============================================================================

  describe "render/1 - lists" do
    test "renders unordered list with dash prefix" do
      md = "- item one\n- item two\n- item three"
      {text, _entities} = Markdown.render(md)
      assert text =~ "- item one"
      assert text =~ "- item two"
      assert text =~ "- item three"
    end

    test "renders ordered list with numbers" do
      md = "1. first\n2. second\n3. third"
      {text, _entities} = Markdown.render(md)
      assert text =~ "1. first"
      assert text =~ "2. second"
      assert text =~ "3. third"
    end
  end

  # ============================================================================
  # Blockquotes
  # ============================================================================

  describe "render/1 - blockquotes" do
    test "renders blockquote with > prefix" do
      {text, _entities} = Markdown.render("> quoted text")
      assert text =~ "> quoted text"
    end
  end

  # ============================================================================
  # Entity offsets
  # ============================================================================

  describe "render/1 - entity offset correctness" do
    test "entity offsets and lengths are non-negative integers" do
      md = "**bold** and `code` and *italic*"
      {_text, entities} = Markdown.render(md)

      for ent <- entities do
        assert is_integer(ent["offset"]) and ent["offset"] >= 0
        assert is_integer(ent["length"]) and ent["length"] > 0
      end
    end

    test "entities do not overlap in unexpected ways" do
      md = "Hello **bold** world `code`"
      {text, entities} = Markdown.render(md)

      # All entity regions should be within the text bounds
      text_len = byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :little})) |> div(2)

      for ent <- entities do
        assert ent["offset"] + ent["length"] <= text_len,
               "Entity #{inspect(ent)} extends beyond text of utf16 length #{text_len}"
      end
    end
  end

  # ============================================================================
  # Complex markdown
  # ============================================================================

  describe "render/1 - complex markdown" do
    test "renders mixed formatting" do
      md = """
      # Hello World

      This is **bold** and *italic* text with `inline code`.

      ```elixir
      def greet(name), do: "Hello, \#{name}!"
      ```

      - Item one
      - Item **two**
      """

      {text, entities} = Markdown.render(md)

      assert text =~ "Hello World"
      assert text =~ "bold"
      assert text =~ "italic"
      assert text =~ "inline code"
      assert text =~ "def greet"
      assert text =~ "Item one"

      types = Enum.map(entities, & &1["type"])
      assert "bold" in types
      assert "italic" in types
      assert "code" in types
      assert "pre" in types
    end
  end
end
