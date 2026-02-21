defmodule LemonRouter.ToolPreviewTest do
  @moduledoc """
  Tests for LemonRouter.ToolPreview text extraction and normalization.
  """
  use ExUnit.Case, async: true

  alias LemonRouter.ToolPreview

  # ============================================================================
  # nil and binary inputs
  # ============================================================================

  describe "to_text/1 with nil" do
    test "returns nil" do
      assert ToolPreview.to_text(nil) == nil
    end
  end

  describe "to_text/1 with binary" do
    test "returns plain text unchanged" do
      assert ToolPreview.to_text("hello world") == "hello world"
    end

    test "returns empty string unchanged" do
      assert ToolPreview.to_text("") == ""
    end

    test "returns multiline text unchanged" do
      text = "line 1\nline 2\nline 3"
      assert ToolPreview.to_text(text) == text
    end

    test "extracts text from inspected TextContent struct" do
      inspected = ~s(%Ai.Types.TextContent{text: "hello from tool", type: :text})
      result = ToolPreview.to_text(inspected)
      assert result == "hello from tool"
    end

    test "extracts text from inspected AgentToolResult struct" do
      inspected =
        ~s(%AgentCore.Types.AgentToolResult{content: [%Ai.Types.TextContent{text: "result text"}]})

      result = ToolPreview.to_text(inspected)
      assert result == "result text"
    end

    test "handles inspected struct with escaped quotes in text" do
      inspected = ~s(%Ai.Types.TextContent{text: "say \\"hello\\""})
      result = ToolPreview.to_text(inspected)
      assert result == ~s(say "hello")
    end

    test "handles inspected struct with newlines" do
      inspected = ~s(%Ai.Types.TextContent{text: "line1\\nline2"})
      result = ToolPreview.to_text(inspected)
      assert result == "line1\nline2"
    end

    test "returns non-struct string as-is" do
      text = "Just a regular message with %{}"
      assert ToolPreview.to_text(text) == text
    end
  end

  # ============================================================================
  # TextContent struct
  # ============================================================================

  describe "to_text/1 with TextContent struct" do
    test "extracts text from TextContent" do
      content = %Ai.Types.TextContent{text: "extracted text"}
      assert ToolPreview.to_text(content) == "extracted text"
    end

    test "handles empty text in TextContent" do
      content = %Ai.Types.TextContent{text: ""}
      assert ToolPreview.to_text(content) == ""
    end
  end

  # ============================================================================
  # List inputs
  # ============================================================================

  describe "to_text/1 with list" do
    test "joins text from list of TextContent" do
      content = [
        %Ai.Types.TextContent{text: "first"},
        %Ai.Types.TextContent{text: "second"}
      ]

      result = ToolPreview.to_text(content)
      assert result == "first\nsecond"
    end

    test "filters out nil and empty strings from list" do
      content = [nil, "hello", "", "world", nil]
      result = ToolPreview.to_text(content)
      assert result == "hello\nworld"
    end

    test "handles empty list" do
      assert ToolPreview.to_text([]) == ""
    end
  end

  # ============================================================================
  # Map inputs
  # ============================================================================

  describe "to_text/1 with map" do
    test "extracts :text key from map" do
      assert ToolPreview.to_text(%{text: "from atom key"}) == "from atom key"
    end

    test "extracts \"text\" key from string-keyed map" do
      assert ToolPreview.to_text(%{"text" => "from string key"}) == "from string key"
    end

    test "extracts :content key from map" do
      assert ToolPreview.to_text(%{content: "nested content"}) == "nested content"
    end

    test "extracts \"content\" key from string-keyed map" do
      assert ToolPreview.to_text(%{"content" => "nested content"}) == "nested content"
    end

    test "inspects map without known keys" do
      result = ToolPreview.to_text(%{foo: "bar"})
      assert is_binary(result)
      assert String.contains?(result, "foo")
    end
  end

  # ============================================================================
  # Other types
  # ============================================================================

  describe "to_text/1 with other types" do
    test "inspects integer" do
      assert ToolPreview.to_text(42) == "42"
    end

    test "inspects atom" do
      result = ToolPreview.to_text(:some_atom)
      assert result == ":some_atom"
    end

    test "inspects tuple" do
      result = ToolPreview.to_text({:ok, "value"})
      assert is_binary(result)
      assert String.contains?(result, "ok")
    end
  end
end
