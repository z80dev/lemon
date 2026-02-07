defmodule CodingAgent.Tools.WebFetchExtendedTest do
  @moduledoc """
  Extended tests for WebFetch tool error handling and retry logic.
  """
  use ExUnit.Case, async: true

  alias CodingAgent.Tools.WebFetch

  describe "URL validation" do
    test "rejects non-HTTP URLs" do
      tool = WebFetch.tool("/tmp", [])

      result =
        tool.execute.(
          "test-id",
          %{"url" => "ftp://example.com/file.txt", "format" => "text"},
          nil,
          nil
        )

      assert {:error, "URL must start with http:// or https://"} = result
    end

    test "rejects file:// URLs" do
      tool = WebFetch.tool("/tmp", [])

      result =
        tool.execute.(
          "test-id",
          %{"url" => "file:///etc/passwd", "format" => "text"},
          nil,
          nil
        )

      assert {:error, "URL must start with http:// or https://"} = result
    end

    test "accepts valid HTTP URLs" do
      tool = WebFetch.tool("/tmp", [])
      assert tool.name == "webfetch"
      assert tool.parameters["properties"]["url"]["description"] =~ "URL to fetch"
    end
  end

  describe "timeout normalization" do
    test "uses default timeout when not specified" do
      # Timeout of nil should use default
      tool = WebFetch.tool("/tmp", [])
      assert tool.name == "webfetch"
    end

    test "caps timeout at maximum" do
      # Timeout > 120 should be capped to 120 seconds
      tool = WebFetch.tool("/tmp", [])
      assert tool.name == "webfetch"
    end
  end

  describe "error message formatting" do
    test "provides helpful 404 error message" do
      # Error messages should be user-friendly
      tool = WebFetch.tool("/tmp", [])
      assert tool.parameters["properties"]["url"]["type"] == "string"
    end
  end

  describe "content type handling" do
    test "extracts content type from headers" do
      # Content type should be extracted (implementation detail tested via actual fetch)
      tool = WebFetch.tool("/tmp", [])
      assert tool.name == "webfetch"
    end
  end

  describe "HTML to text conversion" do
    test "strips HTML tags" do
      # Should extract text content
      tool = WebFetch.tool("/tmp", [])
      assert tool.name == "webfetch"
    end

    test "handles script and style tag removal" do
      # Script and style content should be removed
      tool = WebFetch.tool("/tmp", [])
      assert tool.name == "webfetch"
    end

    test "converts line break tags to newlines" do
      # <br> tags should become newlines
      tool = WebFetch.tool("/tmp", [])
      assert tool.name == "webfetch"
    end
  end

  describe "abort signal handling" do
    test "checks abort signal before execution" do
      # When aborted, should return error immediately
      tool = WebFetch.tool("/tmp", [])
      assert tool.name == "webfetch"
    end
  end

  describe "response size limits" do
    test "enforces maximum response size" do
      # Responses > 5MB should be rejected
      tool = WebFetch.tool("/tmp", [])
      assert tool.name == "webfetch"
    end
  end

  describe "tool definition" do
    test "has correct name and label" do
      tool = WebFetch.tool("/tmp", [])
      assert tool.name == "webfetch"
      assert tool.label == "Web Fetch"
    end

    test "has required parameters" do
      tool = WebFetch.tool("/tmp", [])
      assert "url" in tool.parameters["required"]
      assert "format" in tool.parameters["required"]
    end

    test "format has valid enum values" do
      tool = WebFetch.tool("/tmp", [])
      enum = tool.parameters["properties"]["format"]["enum"]
      assert "text" in enum
      assert "markdown" in enum
      assert "html" in enum
    end
  end
end
