defmodule CodingAgent.InternalUrlsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.InternalUrls

  @moduletag :tmp_dir

  # ============================================================================
  # internal_url?/1
  # ============================================================================

  describe "internal_url?/1" do
    test "returns true for session and skill URLs" do
      for url <- ["local://scratch.md", "skill://demo", "artifact://abc", "proc://1"],
          do: assert(InternalUrls.internal_url?(url))
    end

    test "returns false for the retired notes:// scheme" do
      refute InternalUrls.internal_url?("notes://plan.md")
    end

    test "returns false for http:// URLs" do
      refute InternalUrls.internal_url?("http://example.com")
    end

    test "returns false for https:// URLs" do
      refute InternalUrls.internal_url?("https://example.com")
    end

    test "returns false for file:// URLs" do
      refute InternalUrls.internal_url?("file:///tmp/test.txt")
    end

    test "returns false for empty string" do
      refute InternalUrls.internal_url?("")
    end

    test "returns false for plain string without scheme" do
      refute InternalUrls.internal_url?("just-a-string")
    end

    test "returns false for nil" do
      refute InternalUrls.internal_url?(nil)
    end
  end

  # ============================================================================
  # resolve/2
  # ============================================================================

  describe "resolve/2" do
    test "returns error for unknown protocol" do
      assert {:error, :unknown_protocol} =
               InternalUrls.resolve("http://example.com", session_id: "s", cwd: "/tmp")

      assert {:error, :unknown_protocol} =
               InternalUrls.resolve("notes://plan.md", session_id: "s", cwd: "/tmp")
    end
  end
end
