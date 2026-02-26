defmodule CodingAgent.InternalUrlsTest do
  use ExUnit.Case, async: true

  alias CodingAgent.InternalUrls

  @moduletag :tmp_dir

  # ============================================================================
  # internal_url?/1
  # ============================================================================

  describe "internal_url?/1" do
    test "returns true for notes:// URLs" do
      assert InternalUrls.internal_url?("notes://plan.md")
    end

    test "returns true for notes:// with nested path" do
      assert InternalUrls.internal_url?("notes://subdir/artifact.md")
    end

    test "returns true for notes:// with empty path" do
      assert InternalUrls.internal_url?("notes://")
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
  # parse/1
  # ============================================================================

  describe "parse/1" do
    test "parses notes:// URL with simple filename" do
      assert {:ok, %{scheme: "notes", path: "plan.md"}} =
               InternalUrls.parse("notes://plan.md")
    end

    test "parses notes:// URL with nested path" do
      assert {:ok, %{scheme: "notes", path: "subdir/artifact.md"}} =
               InternalUrls.parse("notes://subdir/artifact.md")
    end

    test "normalizes leading slashes in path" do
      assert {:ok, %{scheme: "notes", path: "plan.md"}} =
               InternalUrls.parse("notes:///plan.md")
    end

    test "normalizes trailing slashes in path" do
      assert {:ok, %{scheme: "notes", path: "subdir/artifact.md"}} =
               InternalUrls.parse("notes://subdir/artifact.md/")
    end

    test "returns error for notes:// with empty path" do
      assert {:error, :empty_path} = InternalUrls.parse("notes://")
    end

    test "returns error for notes:// with only slashes" do
      assert {:error, :empty_path} = InternalUrls.parse("notes:///")
    end

    test "returns error for http:// URL" do
      assert {:error, :unknown_protocol} = InternalUrls.parse("http://example.com")
    end

    test "returns error for plain string" do
      assert {:error, :unknown_protocol} = InternalUrls.parse("no-scheme-here")
    end

    test "returns error for empty string" do
      assert {:error, :unknown_protocol} = InternalUrls.parse("")
    end

    test "returns error for nil" do
      assert {:error, :unknown_protocol} = InternalUrls.parse(nil)
    end
  end

  # ============================================================================
  # resolve/2
  # ============================================================================

  describe "resolve/2" do
    test "resolves notes:// URL to filesystem path", %{tmp_dir: tmp_dir} do
      opts = [session_id: "sess-1", cwd: tmp_dir]

      assert {:ok, path} = InternalUrls.resolve("notes://plan.md", opts)
      assert String.ends_with?(path, "plan.md")
      assert String.contains?(path, "notes/sess-1")
    end

    test "resolves notes:// URL with nested path", %{tmp_dir: tmp_dir} do
      opts = [session_id: "sess-1", cwd: tmp_dir]

      assert {:ok, path} = InternalUrls.resolve("notes://subdir/artifact.md", opts)
      assert String.ends_with?(path, "subdir/artifact.md")
    end

    test "returns error for unknown protocol" do
      assert {:error, :unknown_protocol} =
               InternalUrls.resolve("http://example.com", session_id: "s", cwd: "/tmp")
    end

    test "returns error for path traversal with ..", %{tmp_dir: tmp_dir} do
      opts = [session_id: "sess-1", cwd: tmp_dir]

      assert {:error, :path_traversal} =
               InternalUrls.resolve("notes://../../etc/passwd", opts)
    end

    test "returns error for notes:// with empty path", %{tmp_dir: tmp_dir} do
      opts = [session_id: "sess-1", cwd: tmp_dir]

      assert {:error, :empty_path} = InternalUrls.resolve("notes://", opts)
    end

    test "returns error for path with null byte", %{tmp_dir: tmp_dir} do
      opts = [session_id: "sess-1", cwd: tmp_dir]

      assert {:error, :invalid_path} =
               InternalUrls.resolve("notes://file\0name.md", opts)
    end

    test "strips leading slashes and resolves relative path", %{tmp_dir: tmp_dir} do
      opts = [session_id: "sess-1", cwd: tmp_dir]

      # Leading slashes are trimmed by parse, so this resolves as "etc/passwd"
      assert {:ok, path} = InternalUrls.resolve("notes:///etc/passwd", opts)
      assert String.ends_with?(path, "etc/passwd")
      assert String.contains?(path, "notes/sess-1")
    end

    test "returns primary path when file does not exist and no fallbacks", %{tmp_dir: tmp_dir} do
      opts = [session_id: "sess-1", cwd: tmp_dir]

      assert {:ok, path} = InternalUrls.resolve("notes://missing.md", opts)
      assert String.contains?(path, "sess-1")
    end

    test "handles special characters in artifact name", %{tmp_dir: tmp_dir} do
      opts = [session_id: "sess-1", cwd: tmp_dir]

      assert {:ok, path} = InternalUrls.resolve("notes://my file (1).md", opts)
      assert String.ends_with?(path, "my file (1).md")
    end
  end
end
